#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Long;
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FTPES qw(do_ftpes_upload);
use Logging qw(init_logging logmsg);
use Utils qw(read_config);

# Read command line arguments
my $file_path;
my $port = 990;  # Default FTPES port
GetOptions(
    "file=s" => \$file_path,
    "port=i" => \$port
);

# Check if file path is provided
if (!$file_path) {
    die "Usage: $0 --file <path_to_file> [--port <port_number>]\n";
}

# Read configuration file
my $config_file = "$FindBin::Bin/../config/shoutbomb_config.conf";
my $conf = read_config($config_file);

# Initialize logging
init_logging($conf->{logfile}, 1);

# Resolve the file path to an absolute path
my $abs_file_path = File::Spec->rel2abs($file_path);

# Check if the file exists
if (!-e $abs_file_path) {
    logmsg("ERROR", "File does not exist: $abs_file_path");
    die "File does not exist: $abs_file_path\n";
}

# Get FTPES details from configuration
my $host = $conf->{ftphost};
my $user = $conf->{ftplogin};
my $pass = $conf->{ftppass};
my $remote_dir = $conf->{remote_directory};

logmsg("INFO", "Attempting FTPES connection to $host:$port");

# Perform FTPES upload
my $ftpes_error = do_ftpes_upload($host, $user, $pass, $remote_dir, $abs_file_path, $port);

if ($ftpes_error) {
    logmsg("ERROR", "FTPES ERROR: $ftpes_error");
    die "FTPES ERROR: $ftpes_error\n";
} else {
    logmsg("INFO", "FTPES success: Uploaded $abs_file_path to $remote_dir on $host");
    print "FTPES success: Uploaded $abs_file_path to $remote_dir on $host\n";
}
