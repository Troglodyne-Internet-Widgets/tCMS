#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};
use Cwd();
use File::Path();
use File::Temp();
use Path::Tiny();

use FindBin::libs;

# Every path in tCMS is relative to the instance root, so this stands in one.
my $root   = File::Temp::tempdir( 'tcms-bundle-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
my $oldcwd = Cwd::getcwd();
chdir($root) or die "could not chdir to the sandbox: $!";

END {
    chdir($oldcwd)                 if $oldcwd;
    File::Path::remove_tree($root) if $root && -d $root;
}

require_ok('Trog::Bundle') or BAIL_OUT("Can't find SUT");

my $stock = Path::Tiny->new('www/scripts');
my $theme = Path::Tiny->new('www/themes/spec/scripts');
$_->mkpath foreach ( $stock, $theme );

$stock->child('one.js')->spew_raw("function one () {\n    return 1;\n}\n");
$stock->child('two.js')->spew_raw("// two\nvar two = 2;\n");
$stock->child('vendor.min.js')->spew_raw("var   vendor = 'kept as it is'; // a trailing comment");
$stock->child('themed.js')->spew_raw("var themed = 'stock';\n");
$theme->child('themed.js')->spew_raw("var themed = 'theme';\n");

my $themedir = '';
my $mock     = Test::MockModule->new('Trog::Themes');
$mock->redefine( 'get_dir', sub { $themedir } );

my @warned;
local $SIG{__WARN__} = sub { push @warned, $_[0] };

subtest 'the scripts, in the order named' => sub {
    my $bundle = Trog::Bundle::scripts(qw{two.js vendor.min.js one.js two.js});

    is( $bundle->{body}, "var two=2;\n;\nvar   vendor = 'kept as it is'; // a trailing comment\n;\nfunction one(){return 1;}", 'minified, except the one that already is, and a name given twice is used once' );
    like( $bundle->{version}, qr/\A[[:xdigit:]]{16}\z/, 'the version is a digest' );
    is( $bundle->{href}, "/bundle/$bundle->{version}/two+vendor.min+one.js", 'and the href carries it, and the names' );
};

subtest 'a name that is not a script' => sub {
    @warned = ();
    my $bundle = Trog::Bundle::scripts( qw{one.js nothere.js ../one.js .hidden.js sub/one.js one.css}, 'one.js+two' );
    is( $bundle->{href}, "/bundle/$bundle->{version}/one.js", 'is left out' );
    is( scalar(@warned), 6,                                   'with a warning for each' ) or diag( explain( \@warned ) );
    like( $warned[0], qr/no[ ]script[ ]nothere[.]js/, 'that names it' );

    @warned = ();
    is( Trog::Bundle::scripts(qw{nothere.js}), undef, 'and a list of nothing else is no bundle' );
    is( Trog::Bundle::scripts(),               undef, 'nor is an empty one' );
};

subtest "the theme's copy" => sub {
    is( Trog::Bundle::scripts(qw{themed.js})->{body}, "var themed='stock';", 'is not used without the theme' );

    $themedir = 'www/themes/spec';
    is( Trog::Bundle::scripts(qw{themed.js})->{body}, "var themed='theme';",       'and is used in place of the stock one with it' );
    is( Trog::Bundle::scripts(qw{one.js})->{body},    'function one(){return 1;}', 'while a script the theme lacks is the stock one' );
    $themedir = '';
};

subtest 'a script that changes' => sub {
    my $before = Trog::Bundle::scripts(qw{one.js});
    is( Trog::Bundle::scripts(qw{one.js}), $before, 'the bundle is built once' );

    $stock->child('one.js')->spew_raw("function one () {\n    return 'one';\n}\n");
    utime( time + 10, time + 10, $stock->child('one.js') ) or die "could not touch one.js: $!";

    my $after = Trog::Bundle::scripts(qw{one.js});
    is( $after->{body}, "function one(){return'one';}", 'and built again when a file in it changes' );
    isnt( $after->{href}, $before->{href}, 'at a new href' );
};

subtest 'many lists' => sub {
    $stock->child("s$_.js")->spew_raw("var s$_;") for 1 .. 20;

    @warned = ();
    my %bundle = map { $_ => Trog::Bundle::scripts( 'one.js', "s$_.js" ) } 1 .. 20;
    my %body   = map { $_ => $bundle{$_}{body} } keys %bundle;
    is( scalar(@warned), 0, 'twenty lists' );
    isnt( Trog::Bundle::scripts(qw{one.js s1.js}), $bundle{1}, 'are more than the cache keeps, so it was emptied' );
    is( Trog::Bundle::scripts( 'one.js', "s$_.js" )->{body}, $body{$_}, "list $_ still has its body after the cache is emptied" ) for 1, 20;
};

done_testing();
