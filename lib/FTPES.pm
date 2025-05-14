package FTPES;

use strict;
use warnings;
use Net::FTPSSL;
use File::Basename;
use Exporter 'import';
use Logging qw(logmsg);

our @EXPORT_OK = qw(do_ftpes_upload);

# ----------------------------------------------------------
# do_ftpes_upload
# ----------------------------------------------------------
sub do_ftpes_upload {
    my ($host, $user, $pass, $remote_dir, $local_files, $port) = @_;
    
    # Default to port 990 if not specified
    $port ||= 990;
    
    # Connect with explicit security
    my $ftps = Net::FTPSSL->new($host, 
        Encryption => 1,        # Use encryption
        Port       => $port,    # FTPES standard port
        Debug      => 0,        # Set to 1 for verbose output
        Croak      => 0,        # Don't die on error
    );
    
    if (!$ftps) {
        return "FTPES connection failed: $Net::FTPSSL::ERRSTR";
    }
    
    # Login
    if (!$ftps->login($user, $pass)) {
        my $error = "FTPES login failed: " . $ftps->last_message();
        $ftps->quit();
        return $error;
    }
    
    # Switch to binary mode for reliable transfers
    if (!$ftps->binary()) {
        my $error = "Failed to set binary mode: " . $ftps->last_message();
        $ftps->quit();
        return $error;
    }
    
    # Change to remote directory if specified
    if ($remote_dir && $remote_dir ne '/') {
        if (!$ftps->cwd($remote_dir)) {
            my $error = "Failed to change to directory $remote_dir: " . $ftps->last_message();
            $ftps->quit();
            return $error;
        }
    }
    
    # Process files
    my @files = ref($local_files) eq 'ARRAY' ? @$local_files : ($local_files);
    foreach my $local_file (@files) {
        my $remote_file = basename($local_file);
        
        if (!$ftps->put($local_file, $remote_file)) {
            my $error = "FTPES upload of $local_file failed: " . $ftps->last_message();
            $ftps->quit();
            return $error;
        }
        
        logmsg("INFO", "FTPES uploaded $local_file to $remote_dir/$remote_file");
    }
    
    # Disconnect
    $ftps->quit();
    return '';  # success => empty error message
}

1;
