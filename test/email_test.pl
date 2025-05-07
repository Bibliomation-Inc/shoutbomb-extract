#!/usr/bin/perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Email qw(send_email);
use Logging qw(init_logging logmsg);
use Utils qw(read_config);

# Read configuration file
my $config_file = "$FindBin::Bin/../config/shoutbomb_config.conf";
my $conf = read_config($config_file);

# Initialize logging
init_logging($conf->{logfile}, 1);

# Get email details from configuration
my $from = $conf->{fromemail};
my @recipients = split /,/, $conf->{alwaysemail};
my $subject = 'Test Email from Shoutbomb SMS Extract';

my $html_body = <<"END_HTML";
<html>
<head>
    <title>Shoutbomb SMS Extract Report</title>
</head>
<body>
    <p>Shoutbomb SMS Extract test email.</p>
    <p><strong>Details:</strong></p>
    <ul>
        <li>Start Time: Tue Feb 25 13:54:09 2025</li>
        <li>End Time: Tue Feb 25 13:54:09 2025</li>
        <li>Elapsed Time: 00:00:00</li>
        <li>SFTP Error: None</li>
    </ul>
    <p><strong>Sample Record Counts:</strong></p>
    <ul>
        <li>Patron Preferences: 241</li>
        <li>Courtesy Notices: 375</li>
        <li>Overdue Notices: 484</li>
        <li>Hold Notices: 263</li>
    </ul>
    <p>Thank you,<br>Shoutbomb SMS Extract Script</p>
</body>
</html>
END_HTML

# Send the email
my $email_success = send_email($from, \@recipients, $subject, $html_body);

if ($email_success) {
    logmsg("INFO", "Test email sent to: ".join(',', @recipients)
        ." from: $from"
        ." with subject: $subject"
        ." and body: $html_body");
} else {
    logmsg("ERROR", "Failed to send test email. Check the configuration file. Continuing...");
}