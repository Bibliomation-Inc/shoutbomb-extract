package Logging;

use strict;
use warnings;
use POSIX qw/strftime/;
use Exporter 'import';

our @EXPORT_OK = qw(logmsg init_logging logheader);

my $log_file = 'shoutbomb_export.log';
my $debug;

# ----------------------------------------------------------
# init_logging - Initialize logging with log file and debug flag
# ----------------------------------------------------------
sub init_logging {
    my ($file, $dbg) = @_;
    $log_file = $file;
    $debug = $dbg;
}

# ----------------------------------------------------------
# logmsg - Log a message with timestamp and log level
# ----------------------------------------------------------
sub logmsg {
    my ($level, $msg) = @_;
    return if $level eq 'DEBUG' && !$debug;  # Skip debug messages if debug is not enabled
    my $ts = _get_timestamp();
    my $log_entry = "[$ts] [$level] $msg\n";
    _write_log($log_entry);
}

# ----------------------------------------------------------
# logheader - Log a header with a fixed width and timestamp
# ----------------------------------------------------------
sub logheader {
    my ($header) = @_;
    my $width = 80;
    my $border = '*' x $width;

    my @lines = split /\n/, $header;
    my @formatted_lines;

    foreach my $line (@lines) {
        while (length($line) > $width - 2) {
            my $part = substr($line, 0, rindex($line, ' ', $width - 2));
            $line = substr($line, length($part) + 1);
            my $padding = ' ' x (($width - length($part) - 2) / 2);
            my $formatted_line = "*$padding$part$padding*";
            $formatted_line .= ' ' if length($formatted_line) < $width;
            push @formatted_lines, $formatted_line;
        }
        my $padding = ' ' x (($width - length($line) - 2) / 2);
        my $formatted_line = "*$padding$line$padding*";
        $formatted_line .= ' ' if length($formatted_line) < $width;
        push @formatted_lines, $formatted_line;
    }

    my $ts = _get_timestamp();
    my $timestamp = "[$ts]";
    my $timestamp_padding = ' ' x (($width - length($timestamp)) / 2);
    my $formatted_timestamp = "$timestamp_padding$timestamp$timestamp_padding";
    $formatted_timestamp .= ' ' if length($formatted_timestamp) < $width;

    my $log_entry = "$border\n" . join("\n", @formatted_lines) . "\n$formatted_timestamp\n$border\n";
    _write_log($log_entry);
}

# ----------------------------------------------------------
# _get_timestamp - Get the current timestamp
# ----------------------------------------------------------
sub _get_timestamp {
    return strftime('%Y-%m-%d %H:%M:%S', localtime);
}

# ----------------------------------------------------------
# _write_log - Write a log entry to the log file and console
# ----------------------------------------------------------
sub _write_log {
    my ($log_entry) = @_;
    open my $LOG, '>>', $log_file or die "Cannot open $log_file: $!";
    print $LOG $log_entry;
    close $LOG;
    print $log_entry;  # Also print to console
}

1;
