#!/usr/bin/env perl

# The whole lifecycle suite again, against the SQLite data model.
#
# A data model is only finished when the application cannot tell which one it is
# talking to, and every assertion in that file is about what the app does rather
# than about how anything is stored -- so all of them have to hold for any model.
# Run as a separate process because the model is chosen once, from config, at
# the point Trog::Data builds it.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use IPC::Run3();
use FindBin;

my $suite = "$FindBin::Bin/Trog-Routes-HTML-series-lifecycle.t";
ok( -f $suite, 'the lifecycle suite is there to run' ) or BAIL_OUT("Can't find $suite");

# Captured rather than inherited: the child speaks TAP too, and two test streams
# down one pipe is not a test result, it is a parse error.
my $output = q{};
my $rc     = do {
    local $ENV{TCMS_TEST_DATA_MODEL} = 'SQLite';
    IPC::Run3::run3( [ $^X, "-I$FindBin::Bin/../lib", $suite ], \undef, \$output, \$output );
    $?;
};

is( $rc, 0, 'the whole lifecycle passes on the SQLite data model' ) or diag($output);

done_testing();
