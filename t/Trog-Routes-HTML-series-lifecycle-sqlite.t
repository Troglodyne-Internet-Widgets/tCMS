#!/usr/bin/env perl

# The whole lifecycle suite again, against the SQLite data model.
#
# A data model is only finished when the application cannot tell which one it is
# talking to, and every assertion in that file is about what the app does rather
# than about how anything is stored -- so all of them have to hold for any model.
# Run as a separate process because the model is chosen once, from config, at
# the point Trog::Data builds it.

use strict;
use warnings;

use Test::More;
use File::Temp ();
use FindBin;

my $suite = "$FindBin::Bin/Trog-Routes-HTML-series-lifecycle.t";
ok( -f $suite, 'the lifecycle suite is there to run' ) or BAIL_OUT("Can't find $suite");

# Captured rather than inherited: the child speaks TAP too, and two test streams
# down one pipe is not a test result, it is a parse error.
my ( $fh, $log ) = File::Temp::tempfile( 'lifecycle-sqlite-XXXXXX', TMPDIR => 1, UNLINK => 1 );
close $fh;

my $rc = do {
    local $ENV{TCMS_TEST_DATA_MODEL} = 'SQLite';
    system(qq{$^X "-I$FindBin::Bin/../lib" "$suite" > "$log" 2>&1});
};

is( $rc, 0, 'the whole lifecycle passes on the SQLite data model' ) or do {
    open( my $out, '<', $log ) or return;
    diag($_) while ( $_ = <$out> );
    close $out;
};

done_testing();
