package Trog::SQLite;

use strict;
use warnings;

use DBI;
use DBD::SQLite;
use File::Slurper qw{read_text};

my $dbh = {};
# Ensure the db schema is OK, and give us a handle
sub dbh {
    my ($schema,$dbname) = @_;
    return $dbh->{$schema} if $dbh->{$schema};
    my $qq = read_text($schema);
    my $db = DBI->connect("dbi:SQLite:dbname=$dbname","","");
    $db->{sqlite_allow_multiple_statements} = 1;
    $db->do($qq) or die "Could not ensure auth database consistency";
    $db->{sqlite_allow_multiple_statements} = 0;
    $dbh->{$schema} = $db;
    return $db;
}

1;
