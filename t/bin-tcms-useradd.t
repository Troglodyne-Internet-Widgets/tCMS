#!/usr/bin/env perl

# bin/tcms-useradd reads a password from its input when --password has no
# value.  What matters is what it does with that input when it is piped, which
# is how a script sets a password, so this runs it the way a script would.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin;
use FindBin::libs;

use Test::More;
use IPC::Run3();

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-useradd-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/$_") for qw{config schema data/files logs totp www/themes};
    File::Copy::copy( "$REPO/schema/$_", "$ROOT/schema/$_" ) or die $! for qw{auth.schema flatfile.schema log.schema sqlite.schema};
    File::Copy::copy( "$REPO/config/default.cfg", "$ROOT/config/default.cfg" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Auth') or BAIL_OUT("Can't find what checks the password");

# The user, with this on its input, and what it printed last.
sub useradd ( $user, $input ) {
    my $out = q{};
    IPC::Run3::run3( [ $^X, "-I$REPO/lib", "$REPO/bin/tcms-useradd", '--user', $user, '--password', '--display_name', "Spec $user", '--contact_email', "$user\@test.test" ], \$input, \$out, \$out );
    my @lines = split /\n/, $out;
    return ( $? >> 8, $lines[-1] // q{} );
}

subtest 'a password piped in' => sub {
    my ( $code, $said ) = useradd( 'one', "pw-one\n" );
    is( $code, 0, 'one line is a password' ) or diag($said);
    ok( Trog::Auth::check_password( 'one', 'pw-one' ), 'and it is the one that was set' );

    ( $code, $said ) = useradd( 'two', "pw-two\npw-two\n" );
    is( $code, 0, 'a second line that matches confirms it' ) or diag($said);
    ok( Trog::Auth::check_password( 'two', 'pw-two' ), 'and it is set' );

    ( $code, $said ) = useradd( 'three', "pw-three\npw-other\n" );
    is( $code, 2,                          'a second line that does not match is refused' );
    is( $said, 'Passwords did not match.', 'and says so' );
    ok( !Trog::Auth::check_password( 'three', 'pw-three' ), 'and sets nothing' );

    ( $code, $said ) = useradd( 'four', q{} );
    is( $code, 2,                       'no input at all is refused' );
    is( $said, 'No password provided.', 'and says so' );
};

done_testing();
