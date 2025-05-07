#!/usr/bin/perl

# =============================================================================
# Shoutbomb Notice Preferences Extract Script
# Author: Ian Skelskey
# Copyright (C) 2025 Bibliomation Inc.
#
# This script extracts patron SMS notification preferences from Evergreen ILS 
# and sends the data to Shoutbomb for SMS service initialization.
#
# This program is free software; you can redistribute it and/or modify it 
# under the terms of the GNU General Public License as published by the 
# Free Software Foundation; either version 2 of the License, or (at your 
# option) any later version.
# =============================================================================

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use File::Basename;
use File::Spec;
use File::Path qw(remove_tree);
use File::Copy qw(copy);
use Time::HiRes qw(gettimeofday tv_interval);
use Try::Tiny;

use Logging qw(logmsg init_logging logheader);
use Utils qw(read_config read_cmd_args check_config check_cmd_args 
            write_data_to_file cleanup_temp_directory cleanup_archive_files);
use DBUtils qw(get_dbh get_db_config create_history_table get_org_units 
              get_last_run_time set_last_run_time extract_data);
use SFTP qw(do_sftp_upload);
use Email qw(send_email);

# Capture the start time
my $start_time = [gettimeofday];

###########################
# 1) Parse Config & CLI
###########################

# Read command line arguments
my ($config_file, $evergreen_config_file, $debug, $dry_run) = 
    read_cmd_args('config/shoutbomb_config.conf', '/openils/conf/opensrf.xml', 0, 0);

# Read and check configuration file
check_cmd_args($config_file);
my $conf = read_config($config_file);

# Initialize logging
init_logging($conf->{logfile}, $debug);

# Log header with script information
logheader("Shoutbomb Notice Preferences Extract\nExtracting Patron SMS Notification Settings");

# Check configuration
check_config($conf);
logmsg("SUCCESS", "Configuration file and CLI values are valid");

if ($dry_run) {
    logmsg("INFO", "Running in dry-run mode - no emails will be sent and no files will be uploaded");
}

try {
    ###########################
    # 2) Connect to Database
    ###########################
    my $db_config = get_db_config($evergreen_config_file);
    my $dbh = get_dbh($db_config);
    logmsg("SUCCESS", "Connected to database");

    ###########################
    # 3) Set Up History Table
    ###########################
    create_history_table($dbh);
    
    ###########################
    # 4) Get Organization Units
    ###########################
    my $librarynames = $conf->{librarynames};
    logmsg("INFO", "Library names: $librarynames");
    my $include_descendants = exists $conf->{include_org_descendants};
    my $org_units = get_org_units($dbh, $librarynames, $include_descendants);
    my $pgLibs = join(',', @$org_units);
    logmsg("INFO", "Processing organization units: $pgLibs");
    
    ###########################
    # 5) Extract Notice Preferences
    ###########################
    logmsg("INFO", "Extracting patron notification preferences...");
    my ($notice_prefs_columns, $notice_prefs_data) = extract_data(
        $dbh, 
        "$FindBin::Bin/sql/notice_prefs.sql",
        { org_units => $org_units }
    );
    logmsg("INFO", "Extracted " . scalar(@$notice_prefs_data) . " patron notification preferences");
    
    ###########################
    # 6) Write Data to File
    ###########################
    my @time = localtime();
    my $date_str = sprintf("%04d-%02d-%02d", $time[5]+1900, $time[4]+1, $time[3]);
    my $prefix = $conf->{filenameprefix} || 'shoutbomb';
    
    # Write notice preferences to file
    my $prefs_file = write_data_to_file(
        "${prefix}_notice_prefs_${date_str}", 
        $notice_prefs_data, 
        $notice_prefs_columns, 
        $conf->{tempdir}
    );
    
    ###########################
    # 7) Archive File
    ###########################
    my $archive_dir = $conf->{archive};
    my $archive_file = File::Spec->catfile($archive_dir, basename($prefs_file));
    
    if (copy($prefs_file, $archive_file)) {
        logmsg("INFO", "Archived notice preferences to $archive_file");
    } else {
        logmsg("WARNING", "Failed to archive notice preferences: $!");
    }
    
    ###########################
    # 8) SFTP Upload
    ###########################
    my $sftp_error = '';
    if (!$dry_run) {
        logmsg("INFO", "Uploading file to SFTP server: $conf->{ftphost}");
        
        # Upload notice preferences
        $sftp_error = do_sftp_upload(
            $conf->{ftphost},
            $conf->{ftplogin},
            $conf->{ftppass},
            $conf->{remote_directory},
            $prefs_file
        );
        
        if ($sftp_error) {
            logmsg("ERROR", "SFTP upload of notice preferences failed: $sftp_error");
        } else {
            logmsg("INFO", "SFTP upload of notice preferences successful");
        }
    } else {
        logmsg("INFO", "SFTP upload skipped (dry-run mode)");
    }
    
    ###########################
    # 9) Email Notification
    ###########################
    if (!$dry_run || $sftp_error) {
        # Calculate the elapsed time
        my $elapsed_time = tv_interval($start_time);
        my $hours = int($elapsed_time / 3600);
        my $minutes = int(($elapsed_time % 3600) / 60);
        my $seconds = $elapsed_time % 60;
        my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);
        
        my $subject = $sftp_error 
            ? "ERROR: Shoutbomb Notice Preferences Extract Failed" 
            : "SUCCESS: Shoutbomb Notice Preferences Extract Completed";
        
        my $body = "<h2>Shoutbomb Notice Preferences Extract</h2>\n";
        
        if ($dry_run) {
            $subject = "[DRY RUN] " . $subject;
            $body .= "<p style='color:blue'><strong>DRY RUN MODE</strong> - No files were uploaded to SFTP server</p>\n";
        } elsif ($sftp_error) {
            $body .= "<p style='color:red'>ERROR: SFTP upload failed: $sftp_error</p>\n";
        } else {
            $body .= "<p style='color:green'>The extract completed successfully.</p>\n";
        }
        
        $body .= "<p><strong>Details:</strong></p>\n";
        $body .= "<ul>\n";
        $body .= "<li>Start Time: " . scalar(localtime($start_time->[0])) . "</li>\n";
        $body .= "<li>End Time: " . scalar(localtime) . "</li>\n";
        $body .= "<li>Elapsed Time: $formatted_time</li>\n";
        $body .= "<li>Patron Preferences: " . scalar(@$notice_prefs_data) . "</li>\n";
        $body .= "</ul>\n";
        
        my @recipients = $sftp_error 
            ? split(/\s*,\s*/, $conf->{erroremaillist}) 
            : split(/\s*,\s*/, $conf->{successemaillist});
        
        if (!$dry_run) {
            send_email($conf->{fromemail}, \@recipients, $subject, $body);
            logmsg("INFO", "Email notification sent to " . join(", ", @recipients));
        } else {
            logmsg("INFO", "Email would be sent to " . join(", ", @recipients) . " (dry-run mode)");
            logmsg("INFO", "Email subject: $subject");
        }
    }
    
    ###########################
    # 10) Update History & Cleanup
    ###########################
    # Update last run time - only if not in dry-run mode
    if (!$dry_run) {
        set_last_run_time($dbh, $org_units, 'notice_prefs');
    } else {
        logmsg("INFO", "Skipping history update (dry-run mode)");
    }
    
    # Clean up files
    if ($conf->{cleanup}) {
        # Clean up temporary files specific to notice_prefs
        cleanup_temp_directory($conf->{tempdir}, 'notice_prefs');
        
        if (!$dry_run) {
            # Clean up archive files, keeping only the most recent
            cleanup_archive_files($conf->{archive}, $prefix, 'notice_prefs');
        }
        
        logmsg("INFO", "File cleanup completed");
    }
    
    # Calculate the elapsed time for the final log
    my $elapsed_time = tv_interval($start_time);
    my $hours = int($elapsed_time / 3600);
    my $minutes = int(($elapsed_time % 3600) / 60);
    my $seconds = $elapsed_time % 60;
    my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);
    
    logheader("Finished Shoutbomb Notice Preferences Extract\nElapsed time: $formatted_time");
} catch {
    my $error = $_;
    logmsg("ERROR", "Extract failed: $error");
    
    # Send error email - unless we're in dry-run mode
    if (!$dry_run) {
        my @recipients = split(/\s*,\s*/, $conf->{erroremaillist});
        my $subject = "ERROR: Shoutbomb Notice Preferences Extract Failed";
        my $body = "<h2>Shoutbomb Notice Preferences Extract Error</h2>\n";
        $body .= "<p style='color:red'>ERROR: $error</p>\n";
        
        send_email($conf->{fromemail}, \@recipients, $subject, $body);
        logmsg("INFO", "Error notification email sent");
    } else {
        logmsg("INFO", "Error notification email would be sent (dry-run mode)");
    }
    
    exit(1);
};

exit(0);
