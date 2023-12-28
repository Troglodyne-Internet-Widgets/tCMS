#!/usr/bin/env perl

use strict;
use warnings;

use FindBin::libs;
use Trog::SQLite;
use POSIX ":sys_wait_h";
use Time::HiRes qw{usleep};

# Every recorded request is fully finished, so we can treat them as such.
my $cons_dbh = Trog::SQLite::dbh( 'schema/log.schema', "logs/consolidated.db" );

opendir(my $dh, "logs/db");
my @pids;
foreach my $db (readdir($dh)) {
    next unless $db =~ m/\.db$/;
    die "AAAGH" unless -f "logs/db/$db";
    my $dbh = Trog::SQLite::dbh( 'schema/log.schema', "logs/db/$db" );
    my $pid = fork();
    if (!$pid) {
        do_row_migration($dbh);
        exit 0;
    }
    push(@pids, $pid);
}
while (@pids) {
    my $pid = shift(@pids);
    my $status = waitpid($pid, WNOHANG);
    push(@pids, $pid) if $status == 0;
    usleep(100);
}

sub do_row_migration {
    my ($dbh) = @_;
    my $query = "select * from all_requests";
    my $sth = $dbh->prepare($query);
    $sth->execute();
    while (my @rows = @{ $sth->fetchall_arrayref({}, 100000) || [] }) {
        my @bind = sort keys(%{$rows[0]});
        my @rows_bulk = map { my $subj = $_; map { $subj->{$_} } @bind } @rows;
        Trog::SQLite::bulk_insert($cons_dbh, 'all_requests', \@bind, 'IGNORE', @rows_bulk);

        # Now that we've migrated the rows from the per-fork DBs, murder these rows
        my $binder = join(',', (map { '?' } @rows));
        $dbh->do("DELETE FROM requests WHERE uuid IN ($binder)", undef, map { $_->{uuid} } @rows);
    }
}
