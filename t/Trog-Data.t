use strict;
use warnings;

use Test::More;
use Test::Fatal qw{exception};
use FindBin;
use lib "$FindBin::Bin/../lib";

require_ok('Trog::Data') or BAIL_OUT("Can't load SUT");

# Trog::Data is a factory: new($config) -> Trog::Data::$model->new($config).
# We stub the target module in %INC so require() doesn't hit the filesystem,
# then verify the factory instantiates and returns the right object.

subtest 'new — dispatches to configured data module' => sub {
    # Pre-register a fake Trog::Data::DUMMY so require won't load from disk.
    {
        package Trog::Data::DUMMY;
        sub new { bless { _config => $_[1] }, $_[0] }
    }
    $INC{'Trog/Data/DUMMY.pm'} = 1;

    my $cfg = bless { _data_model => 'DUMMY' }, 'FakeConfig';
    {
        no warnings qw{redefine once};
        local *FakeConfig::param = sub { 'DUMMY' };
        my $obj = Trog::Data->new($cfg);
        isa_ok( $obj, 'Trog::Data::DUMMY', 'factory returns correct class' );
    }
};

subtest 'new — memoizes the instance' => sub {
    # new() uses `state $datamodule`, so repeated calls return the same object.
    # We test this in a fresh subprocess to avoid state pollution from prior subtest.
    my $out = qx{PERL5LIB=lib:$ENV{PERL5LIB} perl -Ilib -e '
        use Trog::Data;
        {
            package Trog::Data::DUMMY;
            sub new { bless {}, \$_[0] }
        }
        \$INC{"Trog/Data/DUMMY.pm"} = 1;

        package FakeCfg;
        sub new   { bless {}, \$_[0] }
        sub param { "DUMMY" }

        package main;
        my \$cfg = FakeCfg->new;
        my \$a   = Trog::Data->new(\$cfg);
        my \$b   = Trog::Data->new(\$cfg);
        print \$a == \$b ? "same" : "different";
    ' 2>&1};
    chomp $out;
    is( $out, 'same', 'new() returns memoized instance on repeated calls' );
};

done_testing;
