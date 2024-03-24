use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Deep;
use Test::Fatal qw{exception};
use FindBin;

use lib "$FindBin::Bin/../lib";

require_ok('Trog::SQLite') or BAIL_OUT("Can't find SUT");

subtest 'dbh' => sub {
    my $readmock = Test::MockModule->new('File::Slurper');
    $readmock->redefine('read_text', sub { "SELECT me FROM candidates" });
    my $dbimock = Test::MockModule->new("DBI");
    $dbimock->redefine('connect', sub { bless({},'TrogDBD') });
    my $works = 0;
    no warnings qw{redefine once};
    local *TrogDBD::do = sub { $works };

    like(exception { Trog::SQLite::dbh('bogus','bogus') }, qr/ensure/i, "Failure to enforce schema throws");
    $works = 1;

    # Otherwise it works
    isa_ok(Trog::SQLite::dbh('bogus','bogus'),'TrogDBD');
};

subtest bulk_insert => sub {
    like(exception { Trog::SQLite::bulk_insert({},'bogus', [qw{a b c}], 'PROCASTINATE') }, qr/unsupported/i, "insert OR keyword consistency enforced");
    like(exception { Trog::SQLite::bulk_insert({},'bogus', []) }, qr/nonempty/, "keys must be provided");
    like(exception { Trog::SQLite::bulk_insert({},'bogus',[qw{a b c}],'IGNORE',qw{jello}) }, qr/multiple of/i, "sufficient values must be provided");

    my $smt;
    my $dbh = bless({},'TrogDBH');
    no warnings qw{redefine once};
    local *TrogDBH::prepare = sub { $smt .= $_[1]; return bless({},'TrogSMT') };
    local *TrogSMT::execute = sub {};

    is(exception { Trog::SQLite::bulk_insert($dbh,'bogus', [qw{moo cows}], 'IGNORE', qw{a b c d}) }, undef, "can do bulk insert");
    is($smt, "INSERT OR IGNORE INTO bogus (moo,cows) VALUES (?,?),(?,?)", "Expected query prepared");

    # Million insert
    $smt='';
    my $keys = [("a") x 10];
    my @values = ("b") x (10**6);
    Trog::SQLite::bulk_insert($dbh,'bogus', $keys, 'IGNORE', @values);
    my $expected = "INSERT OR IGNORE INTO bogus (a,a,a,a,a,a,a,a,a,a) VALUES (?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?),(?,?,?,?,?,?,?,?,?,?)INSERT OR IGNORE INTO bogus (a,a,a,a,a,a,a,a,a,a) VALUES (?,?,?,?,?,?,?,?,?,?)";
    is($smt,$expected, "As expected, only two statements are necessary to be prepared, no matter how many rows to insert.");
};

done_testing;
