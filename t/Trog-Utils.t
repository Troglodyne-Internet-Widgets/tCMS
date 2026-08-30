use strict;
use warnings;

use Test::More;
use Test::Fatal qw{exception};
use File::Temp qw{tempdir};
use FindBin;

use lib "$FindBin::Bin/../lib";

# Stub heavy optional deps that are absent in the test environment
# so that Trog::Utils loads without them
BEGIN {
    for my $mod (qw{HTTP::Tiny::UNIX File::LibMagic Mojo::File UUID}) {
        (my $path = "$mod.pm") =~ s{::}{/}g;
        $INC{$path} //= 1;
        no strict 'refs';
        # Ensure the namespace exists so symbol lookups don't explode
        *{"${mod}::"} = *{"${mod}::"};
    }
    # Trog::Log and Trog::Config are also pulled in transitively
    for my $mod (qw{Trog::Log Trog::Config}) {
        (my $path = "$mod.pm") =~ s{::}{/}g;
        $INC{$path} //= 1;
    }
    # Minimal Trog::Log stub so 'use Trog::Log qw{WARN}' succeeds
    package Trog::Log;
    sub WARN {}
    sub import { }
    # Minimal Trog::Config stub
    package Trog::Config;
    sub import { }
}

require_ok('Trog::Utils') or BAIL_OUT("Can't load Trog::Utils");

subtest 'write_file_atomic - basic write' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/test.json";

    Trog::Utils::write_file_atomic( $path, '{"ok":1}' );

    ok( -f $path, 'file exists after atomic write' );
    open( my $fh, '<', $path ) or die "open: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    is( $content, '{"ok":1}', 'content matches' );
};

subtest 'write_file_atomic - overwrites existing file' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/overwrite.json";

    Trog::Utils::write_file_atomic( $path, 'first' );
    Trog::Utils::write_file_atomic( $path, 'second' );

    open( my $fh, '<', $path ) or die "open: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    is( $content, 'second', 'second write wins' );
};

subtest 'write_file_atomic - no temp file left on disk' => sub {
    my $dir  = tempdir( CLEANUP => 1 );
    my $path = "$dir/clean.json";

    Trog::Utils::write_file_atomic( $path, 'data' );

    opendir( my $dh, $dir ) or die "opendir: $!";
    my @files = grep { !/^\./ } readdir $dh;
    closedir $dh;

    is( scalar @files, 1, 'only target file remains — no temp file left over' );
    is( $files[0], 'clean.json', 'and it is the target file' );
};

subtest 'write_file_atomic - dies on bad directory' => sub {
    like(
        exception { Trog::Utils::write_file_atomic( '/no/such/dir/file.json', 'x' ) },
        qr/./,
        'dies when directory does not exist'
    );
};

done_testing;
