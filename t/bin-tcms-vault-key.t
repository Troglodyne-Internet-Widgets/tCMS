#!/usr/bin/env perl

# bin/tcms-vault-key writes the one secret that cannot be regenerated, so this
# runs it the way a person would and asks Trog::Vault whether it can use the
# result.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin;
use FindBin::libs;

use Test::More;
use File::Slurper ();
use IPC::Run3();

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-vault-key-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    $ENV{HOME} = $ROOT;
    delete $ENV{CREDENTIALS_DIRECTORY};
    delete $ENV{TPSGI_VAULT_KEY};
    File::Path::make_path("$ROOT/config");

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

# After the sandbox, because it takes the key out of the environment as it loads.
use Trog::Vault ();

my $key_file = $Trog::Vault::key_file;

# Its exit code, and everything it printed.
sub vault_key () {
    my $out = q{};
    IPC::Run3::run3( [ $^X, "-I$REPO/lib", "$REPO/bin/tcms-vault-key", '--file' ], \undef, \$out, \$out );
    return ( $? >> 8, $out );
}

subtest 'a key where there was none' => sub {

    # The umask that removes nothing, so the mode is the one the script asked for.
    my $umask = umask(0);
    my ( $code, $said ) = vault_key();
    umask($umask);

    is( $code,                                                  0,                       'it writes one' ) or diag($said);
    is( sprintf( '%04o', ( stat $key_file )[2] & oct('7777') ), '0600',                  'that only its owner can read' );
    is( length( Trog::Vault::key() // q{} ),                    $Trog::Vault::key_bytes, 'and that the vault can use' );
};

subtest 'a key that is already there' => sub {
    my $before = File::Slurper::read_binary($key_file);
    my ( $code, $said ) = vault_key();
    is( $code, 2, 'it is refused' );
    like( $said, qr/already[ ]a[ ]key/, 'and says so' );
    is( File::Slurper::read_binary($key_file), $before, 'and is left alone' );
};

subtest 'a dangling symlink where the key goes' => sub {
    unlink($key_file)                       or die "could not clear the key: $!";
    symlink( "$ROOT/elsewhere", $key_file ) or die "could not plant the symlink: $!";

    my ( $code, $said ) = vault_key();
    is( $code, 2, 'it is refused' ) or diag($said);
    ok( !-e "$ROOT/elsewhere", 'and nothing is written where it points' );
};

done_testing();
