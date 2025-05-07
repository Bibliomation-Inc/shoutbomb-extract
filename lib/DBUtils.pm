package DBUtils;

use strict;
use warnings;
use DBI;
use Exporter 'import';
use Logging qw(logmsg);
use Utils qw(dedupe_array);
use XML::Simple;

our @EXPORT_OK = qw(get_dbh extract_data get_db_config create_history_table get_org_units get_last_run_time set_last_run_time drop_schema);

# ----------------------------------------------------------
# get_dbh - Return a connected DBI handle
# ----------------------------------------------------------
sub get_dbh {
    my ($db_config) = @_;
    my $dsn = "dbi:Pg:dbname=$db_config->{db};host=$db_config->{host};port=$db_config->{port}";
    my $dbh = DBI->connect($dsn, $db_config->{user}, $db_config->{pass},
        { RaiseError => 1, AutoCommit => 1, pg_enable_utf8 => 1 }
    ) or do {
        my $error_msg = "DBI connect error: $DBI::errstr";
        logmsg("ERROR", $error_msg);
        die "$error_msg\n";
    };
    logmsg("INFO", "Successfully connected to the database: $db_config->{db} at $db_config->{host}:$db_config->{port}");
    my $masked_db_config = { %$db_config, pass => '****' };
    logmsg("DEBUG", "DB Config:\n\t" . join("\n\t", map { "$_ => $masked_db_config->{$_}" } keys %$masked_db_config));
    return $dbh;
}

# ----------------------------------------------------------
# get_db_config - Get database configuration from Evergreen config file
# ----------------------------------------------------------
sub get_db_config {
    my ($evergreen_config_file) = @_;
    my $xml = XML::Simple->new;
    my $data = $xml->XMLin($evergreen_config_file);
    my $db_settings = $data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database};
    return {
        db   => $db_settings->{db},
        host => $db_settings->{host},
        port => $db_settings->{port},
        user => $db_settings->{user},
        pass => $db_settings->{pw},
    };
}

# ----------------------------------------------------------
# create_history_table - Create the shoutbomb.history table if it doesn't exist
# ----------------------------------------------------------
sub create_history_table {
    my ($dbh) = @_;
    my $sql = q{
        CREATE SCHEMA IF NOT EXISTS shoutbomb;
        CREATE TABLE IF NOT EXISTS shoutbomb.history (
            id serial PRIMARY KEY,
            extract_type TEXT NOT NULL,
            org_units TEXT NOT NULL,
            last_run TIMESTAMP WITH TIME ZONE DEFAULT '1000-01-01'::TIMESTAMPTZ
        )
    };
    $dbh->do($sql);
    logmsg("INFO", "Ensured shoutbomb.history table exists");
}

# ----------------------------------------------------------
# drop_schema - Drop the shoutbomb schema
# ----------------------------------------------------------
sub drop_schema {
    my ($dbh) = @_;
    my $sql = q{
        DROP SCHEMA IF EXISTS shoutbomb CASCADE
    };
    $dbh->do($sql);
    logmsg("INFO", "Dropped shoutbomb schema");
}

# ----------------------------------------------------------
# get_org_units - Get organization units based on library shortnames
# ----------------------------------------------------------
sub get_org_units {
    my ($dbh, $librarynames, $include_descendants) = @_;
    my @ret = ();

    # spaces don't belong here
    $librarynames =~ s/\s//g;

    my @sp = split( /,/, $librarynames );

    @sp = map { "'" . lc($_) . "'" } @sp;
    my $libs = join(',', @sp);

    my $query = "
    select id
    from
    actor.org_unit
    where lower(shortname) in ($libs)
    order by 1";
    logmsg("DEBUG", "Executing query: $query");
    my $sth = $dbh->prepare($query);
    $sth->execute();
    while (my @row = $sth->fetchrow_array) {
        push( @ret, $row[0] );
        if ($include_descendants) {
            my @des = @{ get_org_descendants($dbh, $row[0]) };
            push( @ret, @des );
        }
    }

    if (!@ret) {
        my $error_msg = "No organization units found for library shortnames: $librarynames";
        logmsg("ERROR", $error_msg);
        die "$error_msg\n";
    }

    return dedupe_array(\@ret);
}

# ----------------------------------------------------------
# get_org_descendants - Get organization unit descendants
# ----------------------------------------------------------
sub get_org_descendants {
    my ($dbh, $thisOrg) = @_;
    my $query = "select id from actor.org_unit_descendants($thisOrg)";
    my @ret = ();
    logmsg("DEBUG", "Executing query: $query");

    my $sth = $dbh->prepare($query);
    $sth->execute();
    while (my $row = $sth->fetchrow_array) {
        push(@ret, $row);
    }

    return \@ret;
}

# ----------------------------------------------------------
# get_last_run_time - Get the last run time from the database for a specific extract type
# ----------------------------------------------------------
sub get_last_run_time {
    my ($dbh, $org_units, $extract_type) = @_;
    my $key = join(',', @$org_units);
    my $sql = "SELECT last_run FROM shoutbomb.history WHERE org_units = ? AND extract_type = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($key, $extract_type);
    if (my ($ts) = $sth->fetchrow_array) {
        $sth->finish;
        return $ts || '1900-01-01'; # Return '1900-01-01' if no timestamp found
    } else {
        $sth->finish;
        logmsg("INFO", "No existing entry for $extract_type. Using old date -> 1900-01-01");
        return '1900-01-01';
    }
}

# ----------------------------------------------------------
# set_last_run_time - Set the last run time in the database for a specific extract type
# ----------------------------------------------------------
sub set_last_run_time {
    my ($dbh, $org_units, $extract_type) = @_;
    my $key = join(',', @$org_units);
    my $sql_upd = q{
      UPDATE shoutbomb.history SET last_run=now() 
      WHERE org_units=? AND extract_type=?
    };
    my $sth_upd = $dbh->prepare($sql_upd);
    my $rows = $sth_upd->execute($key, $extract_type);
    if ($rows == 0) {
        # Might need an INSERT if row does not exist
        my $sql_ins = q{
          INSERT INTO shoutbomb.history(org_units, extract_type, last_run) 
          VALUES(?, ?, now())
        };
        $dbh->do($sql_ins, undef, $key, $extract_type);
    }
    logmsg("INFO", "Updated last_run time for $extract_type, org units: $key");
}

# ----------------------------------------------------------
# extract_data - Execute SQL query and return the results
# ----------------------------------------------------------
sub extract_data {
    my ($dbh, $sql_file, $params) = @_;
    
    # Read SQL from file
    open my $fh, '<', $sql_file or do {
        my $error_msg = "Could not open SQL file $sql_file: $!";
        logmsg("ERROR", $error_msg);
        die $error_msg;
    };
    my $sql = do { local $/; <$fh> };
    close $fh;
    
    # Filter out comments from SQL
    $sql =~ s/--.*$//mg; # Remove single line comments
    $sql =~ s!/\*.*?\*/!!sg; # Remove multi-line comments
    
    # Check for org_unit placeholder and replace if needed
    if ($sql =~ /\$\$ORG_UNIT_FILTER\$\$/ && $params && ref($params) eq 'HASH' && $params->{org_units}) {
        my $org_unit_ids = join(',', @{$params->{org_units}});
        $sql =~ s/\$\$ORG_UNIT_FILTER\$\$/$org_unit_ids/g;
        logmsg("DEBUG", "Applied organization unit filter: $org_unit_ids");
    }
    
    # Execute query
    my $sth = $dbh->prepare($sql);
    if ($params && ref($params) eq 'ARRAY') {
        $sth->execute(@$params);
    } else {
        $sth->execute();
    }
    
    my @results;
    my @columns = @{$sth->{NAME}};
    
    while (my $row = $sth->fetchrow_arrayref) {
        push @results, [@$row];
    }
    
    $sth->finish;
    return (\@columns, \@results);
}

1;