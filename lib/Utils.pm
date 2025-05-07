package Utils;

use strict;
use warnings;
use Exporter 'import';
use Encode;
use File::Spec;
use Logging qw(logmsg);
use Archive::Tar;
use DateTime;
use Getopt::Long;

our @EXPORT_OK = qw(read_config read_cmd_args check_config check_cmd_args 
                   create_tar_gz dedupe_array write_data_to_file
                   cleanup_temp_directory cleanup_archive_files);

# ----------------------------------------------------------
# read_config - Read configuration file
# ----------------------------------------------------------
sub read_config {
    my ($file) = @_;
    open my $fh, '<', $file or die "Cannot open config $file: $!";
    my %c;
    while (<$fh>) {
        chomp;
        s/\r//;
        next if /^\s*#/;     # skip comments
        next unless /\S/;    # skip blank lines
        my ($k, $v) = split(/=/, $_, 2);

        # Trim leading/trailing whitespace
        $k =~ s/^\s+|\s+$//g if defined $k;
        $v =~ s/^\s+|\s+$//g if defined $v;

        $c{$k} = $v if defined $k and defined $v;
    }
    close $fh;
    return \%c;
}

# ----------------------------------------------------------
# check_config - Check configuration values
# ----------------------------------------------------------
sub check_config {
    my ($conf) = @_;

    my @reqs = (
        "logfile", "tempdir", "librarynames", "ftplogin",
        "ftppass", "ftphost", "remote_directory",
        "archive"
    );

    my @missing = ();
    
    for my $i ( 0 .. $#reqs ) {
        push( @missing, $reqs[$i] ) if ( !defined $conf->{ $reqs[$i] } || $conf->{ $reqs[$i] } eq '' );
    }

    if ( $#missing > -1 ) {
        my $msg = "Please specify the required configuration options:\n" . join("\n", @missing) . "\n";
        logmsg("ERROR", $msg);
        die $msg;
    }

    if ( !-e $conf->{"tempdir"} ) {
        my $msg = "Temp folder: " . $conf->{"tempdir"} . " does not exist.\n";
        logmsg("ERROR", $msg);
        die $msg;
    }

    if ( !-e $conf->{"archive"} ) {
        my $msg = "Archive folder: " . $conf->{"archive"} . " does not exist.\n";
        logmsg("ERROR", $msg);
        die $msg;
    }
}

# ----------------------------------------------------------
# read_cmd_args - Read and validate command line arguments
# ----------------------------------------------------------
sub read_cmd_args {
    my ($config_file, $evergreen_config_file, $debug, $dry_run) = @_;
    $evergreen_config_file ||= '/openils/conf/opensrf.xml';  # Default value

    GetOptions(
        "config=s"           => \$config_file,
        "evergreen-config=s" => \$evergreen_config_file,
        "debug"              => \$debug,
        "dry-run"            => \$dry_run,
    );

    return ($config_file, $evergreen_config_file, $debug, $dry_run);
}

# ----------------------------------------------------------
# check_cmd_args - Check command line arguments
# ----------------------------------------------------------
sub check_cmd_args {
    my ($config_file) = @_;

    if ( !-e $config_file ) {
        my $msg = "$config_file does not exist. Please provide a path to your configuration file: --config\n";
        logmsg("ERROR", $msg);
        die $msg;
    }
}

# ----------------------------------------------------------
# cleanup_temp_directory - Clean up the temporary directory
# ----------------------------------------------------------
sub cleanup_temp_directory {
    my ($temp_dir, $extract_type) = @_;
    
    # Create a type-specific subdirectory pattern if extract_type is provided
    my $file_pattern = $extract_type ? qr/${extract_type}.*\.tsv$/ : qr/\.tsv$/;
    
    opendir(my $dh, $temp_dir) or do {
        logmsg("ERROR", "Cannot open temp directory $temp_dir: $!");
        return;
    };
    
    my @files = grep { -f "$temp_dir/$_" && $_ =~ $file_pattern } readdir($dh);
    closedir($dh);
    
    foreach my $file (@files) {
        unlink("$temp_dir/$file") or logmsg("WARNING", "Could not delete $temp_dir/$file: $!");
        logmsg("INFO", "Deleted temp file: $file");
    }
    
    logmsg("INFO", "Cleaned up temporary directory for $extract_type files");
}

# ----------------------------------------------------------
# cleanup_archive_files - Clean up old archive files, keeping only most recent for each type
# ----------------------------------------------------------
sub cleanup_archive_files {
    my ($archive_dir, $prefix, $extract_type) = @_;
    
    opendir(my $dh, $archive_dir) or do {
        logmsg("ERROR", "Cannot open archive directory $archive_dir: $!");
        return;
    };
    
    # Filter files that match our prefix and extract type
    my $file_pattern = qr/^${prefix}_${extract_type}.*\.tsv$/;
    my @files = grep { -f "$archive_dir/$_" && $_ =~ $file_pattern } readdir($dh);
    closedir($dh);
    
    # Group files by date
    my %files_by_date;
    foreach my $file (@files) {
        if ($file =~ /_(\d{4}-\d{2}-\d{2})/) {
            my $date = $1;
            push @{$files_by_date{$date}}, $file;
        } elsif ($file =~ /_(\d{4}-\d{2}-\d{2}_\d{4})/) { 
            # For hourly files with timestamps like 2023-05-01_1430
            my $date = $1;
            push @{$files_by_date{$date}}, $file;
        }
    }
    
    # Sort dates and keep only files from the most recent date
    my @sorted_dates = sort keys %files_by_date;
    if (@sorted_dates > 1) {
        my $latest_date = $sorted_dates[-1];
        
        # Delete files from older dates
        foreach my $date (@sorted_dates[0..($#sorted_dates-1)]) {
            foreach my $old_file (@{$files_by_date{$date}}) {
                unlink("$archive_dir/$old_file") or logmsg("WARNING", "Could not delete $archive_dir/$old_file: $!");
                logmsg("INFO", "Deleted old archive file: $old_file");
            }
        }
        
        # For hourly files (like hold notices), keep only the most recent few within the latest date
        if ($extract_type eq 'hold') {
            my @hourly_files = sort @{$files_by_date{$latest_date}};
            # Keep only the 3 most recent hourly files
            my $keep_count = 3;
            if (@hourly_files > $keep_count) {
                my @files_to_remove = @hourly_files[0..($#hourly_files-$keep_count)];
                foreach my $old_file (@files_to_remove) {
                    unlink("$archive_dir/$old_file") or logmsg("WARNING", "Could not delete $archive_dir/$old_file: $!");
                    logmsg("INFO", "Deleted older hourly archive file: $old_file");
                }
            }
        }
    }
    
    logmsg("INFO", "Cleaned up archive directory for $extract_type files");
}

# ----------------------------------------------------------
# write_data_to_file - Write data to a file
# ----------------------------------------------------------
# Modified version of the existing function to include extract type prefix
sub write_data_to_file {
    my ($type, $data, $columns, $tempdir) = @_;

    # Extract the base extract type (notice_prefs, courtesy, overdue, hold)
    my $extract_type = '';
    if ($type =~ /notice_prefs/) {
        $extract_type = 'notice_prefs';
    } elsif ($type =~ /courtesy/) {
        $extract_type = 'courtesy';
    } elsif ($type =~ /overdue/) {
        $extract_type = 'overdue';
    } elsif ($type =~ /hold/) {
        $extract_type = 'hold';
    }

    # Define the output file path
    my $out_file = File::Spec->catfile($tempdir, "$type.tsv");

    # Open the output file for writing
    my $error = "Cannot open $out_file: $!";
    open my $OUT, '>', $out_file or do {
        logmsg("ERROR", $error);
        die $error;
    };

    # Write the column headers to the output file
    print $OUT join("\t", @$columns)."\n";

    # Write each row of data to the output file
    foreach my $r (@$data) {
        # Sanitize each field to replace line breaks with spaces
        my @sanitized_row = map { 
            my $val = $_ // ''; 
            $val =~ s/[\r\n]+/ /g; 
            $val 
        } @$r;
        print $OUT Encode::encode('UTF-8', join("\t", @sanitized_row) . "\n");
    }

    # Close the output file
    close $OUT;

    # Log the completion of the data writing process and file size
    my $file_size = -s $out_file;
    logmsg("INFO", "Wrote $type data to $out_file (File size: $file_size bytes)");

    return $out_file;
}

# ----------------------------------------------------------
# create_tar_gz - Create a tar.gz archive of the given files
# ----------------------------------------------------------
sub create_tar_gz {
    my ($files_ref, $archive_dir, $filenameprefix) = @_;
    my @files = @$files_ref;
    my $dt = DateTime->now( time_zone => "local" );
    my $fdate = $dt->ymd;
    my $tar_file = File::Spec->catfile($archive_dir, "$filenameprefix" . "_$fdate.tar.gz");

    my $tar = Archive::Tar->new;
    $tar->add_files(@files);
    $tar->write($tar_file, COMPRESS_GZIP);

    logmsg("INFO", "Created tar.gz archive $tar_file");
    return $tar_file;
}

# ----------------------------------------------------------
# dedupe_array - Remove duplicates from an array
# ----------------------------------------------------------
sub dedupe_array {
    my ($arrRef) = @_;
    my @arr     = $arrRef ? @{$arrRef} : ();
    my %deduper = ();
    $deduper{$_} = 1 foreach (@arr);
    my @ret = ();
    while ( ( my $key, my $val ) = each(%deduper) ) {
        push( @ret, $key );
    }
    @ret = sort @ret;
    return \@ret;
}

1;