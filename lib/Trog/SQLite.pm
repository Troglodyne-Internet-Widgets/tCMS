package Trog::SQLite;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use POSIX qw{floor};

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

=head2 bulk_insert(DBI $dbh, STRING $table, ARRAYREF $keys, MIXED @values)

Upsert the values into specified table with provided keys.
values will be N-tuples based on the number and ordering of the keys.

Essentially works around the 999 named param limit and executes by re-using prepared statements.
This results in a quick insert/update of lots of data, such as when building an index or importing data.

Dies on failure.

Doesn't escape the table name or keys, so don't be a maroon and let users pass data to this

=cut

sub bulk_insert ($dbh, $table, $keys, $ACTION='IGNORE', @values) {
    die "keys must be nonempty ARRAYREF" unless ref $keys eq 'ARRAY' && @$keys;
    die "#Values must be a multiple of #keys" if @values % @$keys;

    my ($smt,$query) = ('','');
    while (@values) {
        #Must have even multiple of #keys, so floor divide and chop remainder
        my $nkeys = scalar(@$keys);
        my $limit = floor( 999 / $nkeys );
        $limit = $limit - ( $limit % $nkeys);
        $smt = '' if scalar(@values) < $limit;
        my @params = splice(@values,0,$limit);
        if (!$smt) {
            my @value_tuples;
            my @huh = map { '?' } @params;
            while (@huh) {
                push(@value_tuples, "(".join(',',(splice(@huh,0,$nkeys))).")");
            }
            $query = "INSERT OR $ACTION INTO $table (".join(',',@$keys).") VALUES ".join(',',@value_tuples);
            $smt = $dbh->prepare($query);
        }
        $smt->execute(@params);
    }
}

1;
