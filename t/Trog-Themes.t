#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Path::Tiny();

use FindBin::libs;

require_ok('Trog::Themes') or BAIL_OUT("Can't find SUT");

# A document root with a stock copy of every file, and a theme which overrides
# some of them.  The helpers answer paths relative to the tCMS root, so the
# test runs from the root of the fixture.
my $root = Path::Tiny->tempdir();
foreach my $file (qw{img/a.png img/b.png scripts/a.js styles/a.css styles/b.css}) {
    $root->child("www/$file")->touchpath;
}
foreach my $file (qw{img/a.png scripts/a.js styles/a.css}) { $root->child("www/themes/spec/$file")->touchpath }

chdir("$root") or BAIL_OUT("Cannot enter the fixture: $!");

my $themedir = '';
my $mock     = Test::MockModule->new('Trog::Themes');
$mock->redefine( 'get_dir', sub { $themedir } );

subtest 'url_path' => sub {
    is( Trog::Themes::url_path('www/img/a.png'),             '/img/a.png',             "a file under www/ is served from the root of the site" );
    is( Trog::Themes::url_path('www/themes/spec/img/a.png'), '/themes/spec/img/a.png', "and so is one in a theme" );

    like( exception { Trog::Themes::url_path('lib/Trog/Themes.pm') }, qr/not[ ]under[ ]www/, "a file outside the document root has no URL" );
    like( exception { Trog::Themes::url_path('wwwx/img/a.png') },     qr/not[ ]under[ ]www/, "nor does one in a directory whose name only starts with www" );
    like( exception { Trog::Themes::url_path('/www/img/a.png') },     qr/not[ ]under[ ]www/, "nor a URL path, which is not a file" );
};

subtest 'with no theme' => sub {
    $themedir = '';

    is( Trog::Themes::td(),                  '',                 "td() is empty" );
    is( Trog::Themes::themed('img/a.png'),   'www/img/a.png',    "themed() answers the stock file" );
    is( Trog::Themes::themed_script('a.js'), 'www/scripts/a.js', "and so does themed_script()" );
    is_deeply( [ Trog::Themes::themed_style('a.css') ], ['/styles/a.css'], "themed_style() links the stock sheet alone" );
};

subtest 'with a theme' => sub {
    $themedir = 'www/themes/spec';

    is( Trog::Themes::td(),                  '/themes/spec',                 "td() is the URL path of the theme, not its directory" );
    is( Trog::Themes::themed('img/a.png'),   'www/themes/spec/img/a.png',    "themed() answers the theme's copy" );
    is( Trog::Themes::themed('img/b.png'),   'www/img/b.png',                "and the stock file where the theme has no copy" );
    is( Trog::Themes::themed_script('a.js'), 'www/themes/spec/scripts/a.js', "themed_script() answers the theme's copy" );
    ok( Path::Tiny::path( Trog::Themes::themed("img/b.png") )->is_file, "what themed() answers is a file" );

    is_deeply( [ Trog::Themes::themed_style('a.css') ], [ '/styles/a.css', '/themes/spec/styles/a.css' ], "themed_style() links the stock sheet, then the theme's" );
    is_deeply( [ Trog::Themes::themed_style('b.css') ], ['/styles/b.css'],                                "and the stock sheet alone where the theme has none" );
};

done_testing();
