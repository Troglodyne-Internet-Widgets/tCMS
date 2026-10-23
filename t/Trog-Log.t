#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::NoWarnings;
use File::Temp qw{tempdir};

use FindBin::libs;

require_ok('Trog::Log') or BAIL_OUT("Can't find SUT");

my $dir = tempdir( CLEANUP => 1 );

subtest 'is_debug says which level log_init was given' => sub {
    Trog::Log::log_init( "$dir/tcms.log", 'debug' );
    ok( Trog::Log::is_debug(), 'debug is debug' );

    Trog::Log::log_init( "$dir/tcms.log", 'info' );
    ok( !Trog::Log::is_debug(), 'and info is not' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
