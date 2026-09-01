use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};
use FindBin;

use lib "$FindBin::Bin/../lib";

# The components render real templates through the real renderer, which resolves
# them relative to the tCMS root.  Xslate also computes its cache dir from $HOME
# at load time, so point that somewhere disposable before it is loaded.
my $ROOT;

BEGIN {
    require File::Temp;
    $ROOT = File::Temp::tempdir( 'tcms-component-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    $ENV{HOME} = $ROOT;
    chdir("$FindBin::Bin/..") or die "could not chdir to the tCMS root: $!";
}

require_ok('Trog::Component')             or BAIL_OUT("Can't find SUT");
require_ok('Trog::Component::Header')     or BAIL_OUT("Can't find SUT");
require_ok('Trog::Component::PostHeader') or BAIL_OUT("Can't find SUT");

subtest 'the furniture with no arguments' => sub {

    # These six are empty or a stock placeholder, and read no variables at all.
    # The test is that each resolves its own template and comes back with a
    # string rather than dying -- which is the whole of what index.tx asks of it.
    foreach my $name (qw{HtmlTitle MidTitle TopBar LeftBar RightBar FootBar Footer}) {
        my $out = Trog::Component::component($name);
        is( exception { Trog::Component::component($name) }, undef, "$name renders" );
        isa_ok( $out, 'Text::Xslate::Type::Raw', "$name comes back marked raw" );
    }

    like( Trog::Component::component('HtmlTitle'), qr/tCMS/,     "HtmlTitle is the site title" );
    like( Trog::Component::component('Footer'),    qr{</html>}i, "Footer closes the document" );
};

subtest 'Header' => sub {
    my $out = Trog::Component::component(
        'Header',
        {
            title       => 'A Page',
            route       => '/somewhere',
            stylesheets => ['/styles/screen.css'],
            scripts     => ['/scripts/post.js'],
        }
    );

    like( $out, qr/<!doctype html>/i,              "the doctype is emitted by default" );
    like( $out, qr{<title>A Page</title>},         "the title lands" );
    like( $out, qr{href="/styles/screen\.css"},    "stylesheets land" );
    like( $out, qr{src="/scripts/post\.js"},       "scripts land" );
    like( $out, qr{lang="en-US"},                  "lang defaults rather than rendering empty" );
    like( $out, qr{href="/somewhere\?format=rss"}, "the rss link uses the route" );

    # rss_style() renders into an XSL document, so the doctype has to go.
    my $xsl = Trog::Component::component( 'Header', { title => 'RSS', no_doctype => 1 } );
    unlike( $xsl, qr/<!doctype/i, "no_doctype suppresses it" );

    # It also has no stylesheets or scripts to give, and must not invent any.
    unlike( $xsl, qr/rel="stylesheet" type="text\/css" href="\/styles\/screen/, "no stylesheets are conjured up" );

    # header.tx marks meta_tags raw, so social markup has to survive as markup.
    my $social = Trog::Component::component( 'Header', { meta_tags => '<meta name="twitter:card" />' } );
    like( $social, qr{<meta name="twitter:card" />}, "meta_tags stay markup" );
};

subtest 'CategoryBar' => sub {
    my $categories = [ { local_href => '/series/blog', title => 'Blog' } ];

    my $out = Trog::Component::component( 'CategoryBar', { categories => $categories } );
    like( $out, qr{href="/series/blog"}, "an anonymous reader gets the plain link" );

    my $secure = Trog::Component::component( 'CategoryBar', { categories => $categories, user => 'someone' } );
    like( $secure, qr{href="/secure/series/blog"}, "a logged in reader gets the secure link" );

    is( exception { Trog::Component::component('CategoryBar') }, undef, "no categories is not fatal" );
};

subtest 'PostHeader and PostFooter validate the name' => sub {

    # The name comes out of post data, and before this it went straight into a
    # path with nothing checking it.
    foreach my $bad ( '../../etc/passwd', 'headers/../../../etc/passwd', 'nope.tx', 'about_header' ) {
        like(
            exception { Trog::Component::component( 'PostHeader', { name => $bad } ) },
            qr/No such header/,
            "'$bad' is refused"
        );
    }

    # An empty name is how a post with no header asks, so it must not be fatal.
    is( Trog::Component::component( 'PostHeader', { name => '' } ),    '', "no name renders nothing" );
    is( Trog::Component::component('PostHeader'),                      '', "a missing name renders nothing" );
    is( Trog::Component::component( 'PostFooter', { name => undef } ), '', "an undef name renders nothing" );

    # Whatever the edit form offers has to actually render.
    my $available = Trog::Component::PostHeader::available();
    ok( scalar(@$available), "there is at least one stock header to try" ) or return;
    foreach my $name (@$available) {
        is( exception { Trog::Component::component( 'PostHeader', { name => $name } ) }, undef, "$name renders" );
    }

    # available() is the same list the series edit form is built from.
    is_deeply(
        $available,
        Trog::Themes::themed_templates_in_dir( 'headers', 'text/html', 1 ),
        "available() is the list the edit form offers"
    );
};

subtest 'the whole page still composes' => sub {
    require Trog::Renderer::Base;

    # index.tx is a page, not a component, so it resolves in www/templates/html
    # rather than the components dir and comes back as a PSGI triplet.
    my $psgi = eval {
        Trog::Renderer::Base::render(
            template    => 'index.tx',
            contenttype => 'text/html',
            code        => 200,
            data        => {
                title        => 'Composed',
                route        => '/',
                content      => '<p>the body</p>',
                categories   => [ { local_href => '/series/blog', title => 'Blog' } ],
                stylesheets  => ['/styles/screen.css'],
                print_styles => [],
                scripts      => [],
            },
        );
    };
    my $err = $@;
    is( $err, '', "index.tx renders" ) or diag($err);
    my $body = ref $psgi eq 'ARRAY' ? $psgi->[2][0] : undef;

    like( $body, qr/<!doctype html>/i,        "Header came through" );
    like( $body, qr{<title>Composed</title>}, "the title came through" );
    like( $body, qr{<p>the body</p>},         "the content is still the content" );
    like( $body, qr{href="/series/blog"},     "CategoryBar came through" );
    like( $body, qr{</html>},                 "Footer came through" );

    # The furniture divs are the bars' sockets; they must still be there even
    # though the stock bars render placeholders.
    like( $body, qr{id="leftbar"}, "the left bar socket is intact" );
    like( $body, qr{id="footbar"}, "the footer bar socket is intact" );
};

done_testing();
