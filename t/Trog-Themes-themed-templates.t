use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Path::Tiny();
use FindBin;

use lib "$FindBin::Bin/../lib";

require_ok('Trog::Themes') or BAIL_OUT("Can't find SUT");

# A stock template tree and a theme which only partially overrides it.
my $root  = Path::Tiny->tempdir();
my $stock = $root->child('www/templates/html/components/forms');
my $theme = $root->child('www/themes/spec/templates/html/components/forms');
$_->mkpath foreach ( $stock, $theme );

$stock->child($_)->spew_utf8("stock $_")  foreach qw{blog.tx series.tx profile.tx blog.json series.json};
$theme->child($_)->spew_utf8("themed $_") foreach qw{blog.tx gallery.tx blog.json};

my $themedir = '';
my $mock     = Test::MockModule->new('Trog::Themes');
$mock->redefine( 'get_dir', sub { $themedir } );

# $template_dir is what the stock tree hangs off; point it at the fixture.
{
    no warnings qw{once};
    $Trog::Themes::template_dir = "$root/www/templates";
}

subtest 'with no theme, nothing changes' => sub {
    $themedir = '';

    is_deeply(
        [ Trog::Themes::template_dirs( 'text/html', 1 ) ],
        ["$root/www/templates/html/components"],
        "only the stock dir is searched"
    );

    my $old = [ sort @{ Trog::Themes::templates_in_dir( 'forms', 'text/html', 1 ) } ];
    my $new = [ sort @{ Trog::Themes::themed_templates_in_dir( 'forms', 'text/html', 1 ) } ];
    is_deeply( $new, $old,                               "the themed helper agrees with the old one" );
    is_deeply( $new, [qw{blog.tx profile.tx series.tx}], "...and lists the stock templates" );
};

subtest 'with a partial theme, the two disagree' => sub {
    $themedir = "$root/www/themes/spec";

    is_deeply(
        [ Trog::Themes::template_dirs( 'text/html', 1 ) ],
        [ "$root/www/themes/spec/templates/html/components", "$root/www/templates/html/components" ],
        "the theme is searched first, then the stock tree"
    );

    # This is the shortcoming: one forms/ dir in a theme hides every stock
    # post type the theme didn't happen to copy.
    is_deeply(
        [ sort @{ Trog::Themes::templates_in_dir( 'forms', 'text/html', 1 ) } ],
        [qw{blog.tx gallery.tx}],
        "templates_in_dir() sees only the theme's"
    );

    is_deeply(
        [ sort @{ Trog::Themes::themed_templates_in_dir( 'forms', 'text/html', 1 ) } ],
        [qw{blog.tx gallery.tx profile.tx series.tx}],
        "themed_templates_in_dir() adds back the ones the theme didn't override"
    );

    my $listed = Trog::Themes::themed_templates_in_dir( 'forms', 'text/html', 1 );
    is( scalar( grep { $_ eq 'blog.tx' } @$listed ), 1,         "an overridden template is listed once, not twice" );
    is( $listed->[0],                                'blog.tx', "and the theme's copies come first" );
};

subtest 'themed_file_in_dir prefers the theme, falls back to stock' => sub {
    $themedir = "$root/www/themes/spec";

    is(
        Trog::Themes::themed_file_in_dir( 'forms', 'blog.json', 'text/html', 1 ),
        "$theme/blog.json", "the theme's copy wins"
    );
    is(
        Trog::Themes::themed_file_in_dir( 'forms', 'series.json', 'text/html', 1 ),
        "$stock/series.json", "one the theme lacks falls back"
    );
    is(
        Trog::Themes::themed_file_in_dir( 'forms', 'nope.json', 'text/html', 1 ),
        undef, "and one nobody has is undef, not a path that doesn't exist"
    );
};

subtest 'an empty or missing dir is not fatal' => sub {
    $themedir = "$root/www/themes/spec";
    is_deeply( Trog::Themes::themed_templates_in_dir( 'nosuchdir', 'text/html', 1 ), [], "just an empty list" );
};

done_testing();
