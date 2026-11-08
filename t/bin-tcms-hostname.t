#!/usr/bin/env perl

# bin/tcms-hostname writes the hosts of an instance into its own
# configuration, which is how the provisioner sets them, so this runs it the
# way the provisioner does.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin;
use FindBin::libs;

use Test::More;
use IPC::Run3();
use Config::Simple();

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-hostname-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/config");
    File::Copy::copy( "$REPO/config/default.cfg", "$ROOT/config/default.cfg" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

# What it exits with and prints, given @args.
sub hostname (@args) {
    my $out = q{};
    IPC::Run3::run3( [ $^X, "-I$REPO/lib", "$REPO/bin/tcms-hostname", @args ], \undef, \$out, \$out );
    my $code = $? >> 8;
    chomp $out;
    return ( $code, $out );
}

# What a configuration says, as tCMS reads it: Config::Simple gives an empty
# value as an empty list.
sub setting ( $name, $file = 'config/main.cfg' ) {
    my $value = Config::Simple->new($file)->param($name);
    return ref $value ? join( ',', @$value ) : $value // q{};
}

subtest 'the hostname and the secure host' => sub {
    my ( $code, $said ) = hostname(qw{--secure secure.test.test test.test});
    is( $code,                          0,                  'both are set at once' ) or diag($said);
    is( $said,                          'test.test',        'and it prints the hostname' );
    is( setting('general.hostname'),    'test.test',        'which the configuration of the instance now holds' );
    is( setting('general.secure_host'), 'secure.test.test', 'with the secure host beside it' );

    is( setting( 'general.secure_host', 'config/default.cfg' ), q{}, 'and the tracked default.cfg is left alone' );

    ( $code, $said ) = hostname(qw{--secure other.test.test});
    is( $code,                          0,                 'the secure host can be set alone' ) or diag($said);
    is( setting('general.secure_host'), 'other.test.test', 'and it is' );
    is( setting('general.hostname'),    'test.test',       'and the hostname stays as it was' );

    ( $code, $said ) = hostname( '--secure', q{} );
    is( $code,                          0,   'an empty secure host is allowed' ) or diag($said);
    is( setting('general.secure_host'), q{}, 'and unsets it' );
};

done_testing();
