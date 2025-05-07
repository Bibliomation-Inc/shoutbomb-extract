#!/usr/bin/perl

# =============================================================================
# Shoutbomb Hold Notices Extract Script
# Author: Ian Skelskey
# Copyright (C) 2025 Bibliomation Inc.
#
# This script extracts hold notices data from Evergreen ILS and sends it to 
# Shoutbomb for SMS notifications. Designed to run hourly to keep patrons
# informed promptly when their requested items are available.
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
use POSIX qw(strftime);

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

# Get current time for logging
my $current_hour = strftime('%H:00', localtime);
logheader("Shoutbomb Hold Notices Extract - $current_hour\nExtracting Hold Ready for Pickup Notices");

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
    # 5) Extract Hold Notices
    ###########################
    logmsg("INFO", "Extracting hold ready notices...");
    my ($hold_columns, $hold_data) = extract_data(
        $dbh, 
        "$FindBin::Bin/sql/hold_notice.sql",
        { org_units => $org_units }
    );
    logmsg("INFO", "Extracted " . scalar(@$hold_data) . " hold notices");
    
    ###########################
    # 6) Write Data to File
    ###########################
    # Format current date-time for filename to include hour for hourly runs
    my $timestamp = strftime('%Y-%m-%d_%H%M', localtime);
    my $prefix = $conf->{filenameprefix} || 'shoutbomb';
    
    # Write hold notices to file
    my $hold_file = write_data_to_file(
        "${prefix}_hold_${timestamp}", 
        $hold_data, 
        $hold_columns, 
        $conf->{tempdir}
    );
    
    ###########################
    # 7) Archive File
    ###########################
    my $archive_dir = $conf->{archive};
    
    # Archive hold notices
    my $hold_archive = File::Spec->catfile($archive_dir, basename($hold_file));
    if (copy($hold_file, $hold_archive)) {
        logmsg("INFO", "Archived hold notices to $hold_archive");
    } else {
        logmsg("WARNING", "Failed to archive hold notices: $!");
    }
    
    ###########################
    # 8) SFTP Upload
    ###########################
    my $sftp_error = '';
    if (!$dry_run) {
        logmsg("INFO", "Uploading file to SFTP server: $conf->{ftphost}");
        
        # Upload hold notices
        $sftp_error = do_sftp_upload(
            $conf->{ftphost},
            $conf->{ftplogin},
            $conf->{ftppass},
            $conf->{remote_directory},
            $hold_file
        );
        
        if ($sftp_error) {
            logmsg("ERROR", "SFTP upload of hold notices failed: $sftp_error");
        } else {
            logmsg("INFO", "SFTP upload of hold notices successful");
        }
    } else {
        logmsg("INFO", "SFTP upload skipped (dry-run mode)");
    }
    
    ###########################
    # 9) Email Notification
    ###########################
    # Determine whether to send an email based on configuration
    my $strategy = $conf->{hold_email_strategy} || 'errors_only';
    my $send_email = 0;
    
    # Always send on errors regardless of strategy
    if ($sftp_error) {
        $send_email = 1;
    }
    # Otherwise check the configured strategy
    elsif ($strategy eq 'always') {
        $send_email = 1;
    }
    elsif ($strategy eq 'threshold' && scalar(@$hold_data) >= ($conf->{hold_email_threshold} || 10)) {
        $send_email = 1;
    }
    elsif ($strategy eq 'daily_summary') {
        my $summary_hour = $conf->{hold_email_summary_hour} || 20;
        my $current_hour = (localtime)[2]; # Hour of day (0-23)
        $send_email = ($current_hour == $summary_hour);
    }
    
    if (!$dry_run && $send_email) {
        # Calculate the elapsed time
        my $elapsed_time = tv_interval($start_time);
        my $hours = int($elapsed_time / 3600);
        my $minutes = int(($elapsed_time % 3600) / 60);
        my $seconds = $elapsed_time % 60;
        my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);
        
        my $subject = $sftp_error 
            ? "ERROR: Shoutbomb Hold Notices Extract Failed" 
            : "Shoutbomb Hold Notices Extract Completed - $current_hour";
        
        my $body = "<h2>Shoutbomb Hold Notices Extract</h2>\n";
        
        if ($sftp_error) {
            $body .= "<p style='color:red'>ERROR: SFTP upload failed: $sftp_error</p>\n";
        } else {
            $body .= "<p style='color:green'>The extract completed successfully.</p>\n";
        }
        
        $body .= "<p><strong>Details:</strong></p>\n";
        $body .= "<ul>\n";
        $body .= "<li>Extract Time: $current_hour</li>\n";
        $body .= "<li>Start Time: " . scalar(localtime($start_time->[0])) . "</li>\n";
        $body .= "<li>End Time: " . scalar(localtime) . "</li>\n";
        $body .= "<li>Elapsed Time: $formatted_time</li>\n";
        $body .= "<li>Hold Notices: " . scalar(@$hold_data) . "</li>\n";
        $body .= "</ul>\n";
        
        my @recipients = $sftp_error 
            ? split(/\s*,\s*/, $conf->{erroremaillist}) 
            : split(/\s*,\s*/, $conf->{successemaillist});
        
        send_email($conf->{fromemail}, \@recipients, $subject, $body);
        logmsg("INFO", "Email notification sent to " . join(", ", @recipients));
    } elsif ($dry_run) {
        logmsg("INFO", "Email notification would be sent (dry-run mode)");
    }
    
    ###########################
    # 10) Update History & Cleanup
    ###########################
    # Update last run time - only if not in dry-run mode
    if (!$dry_run) {
        set_last_run_time($dbh, $org_units, 'hold_notice');
    } else {
        logmsg("INFO", "Skipping history update (dry-run mode)");
    }
    
    # Clean up files
    if ($conf->{cleanup}) {
        # Clean up temporary files specific to hold notices
        cleanup_temp_directory($conf->{tempdir}, 'hold');
        
        if (!$dry_run) {
            # Clean up archive files, keeping only the most recent few hourly files
            cleanup_archive_files($conf->{archive}, $prefix, 'hold');
        }
        
        logmsg("INFO", "File cleanup completed");
    }
    
    # Calculate the elapsed time for the final log
    my $elapsed_time = tv_interval($start_time);
    my $hours = int($elapsed_time / 3600);
    my $minutes = int(($elapsed_time % 3600) / 60);
    my $seconds = $elapsed_time % 60;
    my $formatted_time = sprintf("%02d:%02d:%02d", $hours, $minutes, $seconds);
    
    logheader("Finished Shoutbomb Hold Notices Extract\nElapsed time: $formatted_time");
} catch {
    my $error = $_;
    logmsg("ERROR", "Extract failed: $error");
    
    # Send error email - unless we're in dry-run mode
    if (!$dry_run) {
        my @recipients = split(/\s*,\s*/, $conf->{erroremaillist});
        my $subject = "ERROR: Shoutbomb Hold Notices Extract Failed - $current_hour";
        my $body = "<h2>Shoutbomb Hold Notices Extract Error</h2>\n";
        $body .= "<p style='color:red'>ERROR: $error</p>\n";
        
        send_email($conf->{fromemail}, \@recipients, $subject, $body);
        logmsg("INFO", "Error notification email sent");
    } else {
        logmsg("INFO", "Error notification email would be sent (dry-run mode)");
    }
    
    exit(1);
};

exit(0);
