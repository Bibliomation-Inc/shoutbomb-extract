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
use Text::CSV;

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

    # Set default port if not specified
    $conf->{ftpport} = 990 if (!defined $conf->{ftpport} || $conf->{ftpport} eq '');

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
    my $file_pattern = $extract_type ? qr/${extract_type}.*\.txt$/ : qr/\.txt$/;
    
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
    my $file_pattern = qr/^${prefix}_${extract_type}/;
    my @files = grep { -f "$archive_dir/$_" && $_ =~ $file_pattern } readdir($dh);
    closedir($dh);
    
    logmsg("DEBUG", "Found " . scalar(@files) . " $extract_type files to process for cleanup");
    
    if ($extract_type eq 'hold') {
        # For hold notices - keep only the 3 most recent files regardless of date
        my @sorted_files = sort @files;
        
        # If we have more than 3 files, delete the oldest ones
        if (@sorted_files > 3) {
            my @files_to_remove = @sorted_files[0..($#sorted_files-3)];
            foreach my $old_file (@files_to_remove) {
                unlink("$archive_dir/$old_file") or logmsg("WARNING", "Could not delete $archive_dir/$old_file: $!");
                logmsg("INFO", "Deleted older hold archive file: $old_file");
            }
            logmsg("INFO", "Kept 3 most recent hold notice files, deleted " . scalar(@files_to_remove) . " older files");
        }
    } 
    else {
        # For other notice types (courtesy, notice_prefs) - keep only the most recent file
        my @sorted_files = sort @files;
        
        # If we have more than 1 file, delete all but the most recent
        if (@sorted_files > 1) {
            my @files_to_remove = @sorted_files[0..($#sorted_files-1)];
            foreach my $old_file (@files_to_remove) {
                unlink("$archive_dir/$old_file") or logmsg("WARNING", "Could not delete $archive_dir/$old_file: $!");
                logmsg("INFO", "Deleted older $extract_type archive file: $old_file");
            }
            logmsg("INFO", "Kept most recent $extract_type notice file, deleted " . scalar(@files_to_remove) . " older files");
        }
    }
}

# ----------------------------------------------------------
# write_data_to_file - Write data to a file
# ----------------------------------------------------------
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

    # Define the output file path - changed from .csv to .txt for pipe-delimited files
    my $out_file = File::Spec->catfile($tempdir, "$type.txt");

    # Create a new CSV object with pipe delimiter
    my $csv = Text::CSV->new({
        binary           => 1,
        always_quote     => 0,    # Don't quote all fields by default
        eol              => "\n", # Use Unix-style line endings
        quote_space      => 0,    # Don't automatically quote spaces
        auto_diag        => 1,    # Report errors
        quote_char       => '"',  # Use double quotes when needed
        escape_char      => '"',  # Escape quotes with quotes
        sep_char         => '|',  # Use pipe as delimiter
    });

    # Open the output file for writing
    my $error = "Cannot open $out_file: $!";
    open my $OUT, '>', $out_file or do {
        logmsg("ERROR", $error);
        die $error;
    };

    # Write the column headers to the output file
    $csv->print($OUT, $columns);

    # Write each row of data to the output file
    foreach my $r (@$data) {
        # Sanitize each field and prepare for output
        my @sanitized_row;
        
        for (my $i = 0; $i < scalar(@$r); $i++) {
            my $val = $r->[$i] // '';
            
            # Remove line breaks
            $val =~ s/[\r\n]+/ /g;
            
            # Handle date fields - strip time component if present
            if ($val =~ /^\d{4}-\d{2}-\d{2}[T\s]/) {
                $val =~ s/^(\d{4}-\d{2}-\d{2})[T\s].*$/$1/;
            }
            
            # Escape pipe characters in the data to prevent delimiter confusion
            $val =~ s/\|/\\|/g;
            
            push @sanitized_row, $val;
        }
        
        $csv->print($OUT, \@sanitized_row);
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