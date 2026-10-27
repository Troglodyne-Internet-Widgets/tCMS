#!/usr/bin/env perl

# The OpenAPI document that TCMS.pm hands tPSGI, made from tCMS's own routing
# table.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin;
use FindBin::libs;

use Test::More;
use Test::MockModule                   qw{strict};
use Test::Fatal                        qw{exception};
use JSON::MaybeXS                      ();
use JSON::Validator::Schema::OpenAPIv3 ();

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-routes-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    # TCMS.pm builds its document at file scope, against whatever cwd is
    # current when it loads, and every path in tCMS is relative to that.
    $ENV{HOME} = $ROOT;
    File::Path::make_path( map { "$ROOT/$_" } qw{config schema data/files logs totp www/statics www/themes} );
    for my $schema (qw{auth.schema flatfile.schema log.schema}) { File::Copy::copy( "$REPO/schema/$schema", "$ROOT/schema/$schema" ) or die $! }

    open( my $fh, '>', "$ROOT/config/default.cfg" ) or die $!;
    print {$fh} "[general]\n    data_model=FlatFile\n    hostname=routes.test.test\n";
    close($fh) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

# The routes of posts, as the tag index of a FlatFile site gives them: by the
# name of their callback.
require_ok('Trog::SQLite::TagIndex') or BAIL_OUT("Can't load the tag index");
my $index = Test::MockModule->new('Trog::SQLite::TagIndex');
$index->redefine(
    routes => sub {
        return (
            '/posts/p-one'   => { method => 'GET', callback => 'Trog::Routes::HTML::posts' },
            '/posts/{curly}' => { method => 'GET', callback => 'Trog::Routes::HTML::posts' },
            '/secure/p-two'  => { method => 'GET', callback => 'Trog::Routes::HTML::posts' },
            '/p-private'     => { method => 'GET', callback => 'Trog::Routes::HTML::posts', secure => 1 },
        );
    }
);

# What a post's route runs, which the routes of posts name.
require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't load the routes");
my $html = Test::MockModule->new('Trog::Routes::HTML');
my $posted;

# It answers with where the request would be sent on, when it says.
$html->redefine( posts => sub ($query) { $posted = $query; return [ 200, [], [ exists $query->{to} ? $query->{to} : 'the post' ] ] } );

require_ok('TCMS') or BAIL_OUT("Can't load the dispatcher");

my %openapi = do { no warnings 'once'; %TCMS::openapi };

# Checked as JSON reads it, since tPSGI is not a prerequisite of tCMS: perl's
# booleans become JSON's, and a callback becomes null.
my $json   = JSON::MaybeXS->new( allow_unknown => 1, canonical => 1 );
my $schema = JSON::Validator::Schema::OpenAPIv3->new( $json->decode( $json->encode( \%openapi ) ) );
my $paths  = $openapi{paths};

subtest 'the document' => sub {
    is_deeply( $schema->errors, [], 'is valid OpenAPI 3' ) or diag explain $schema->errors;
    ok( !exists $paths->{default},          'and has no path for the setup route, which is not one' );
    ok( !( grep { m/[(]/ } keys(%$paths) ), 'nor any regex left' ) or diag explain [ grep { m/[(]/ } keys(%$paths) ];
};

subtest 'an operation' => sub {
    my $manual = $paths->{'/lib/{module+}'}{get};
    ok( $manual, 'the manual of a module is a GET of /lib/{module+}' );
    is( ref $manual->{'x-tpsgi-callback'}, 'CODE', 'with a callback' );
    is( $manual->{'x-tcms-auth'},          1,      'and its auth as x-tcms-auth' );
    is_deeply(
        [ grep { $_->{in} eq 'path' } @{ $manual->{parameters} } ],
        [ { name => 'module+', in => 'path', required => true, schema => { type => 'string' } } ],
        'and each variable of the template as a required path parameter'
    );

    my $totp = $paths->{'/totp'}{get};
    is( $totp->{'x-tcms-totp_exempt'}, 1, 'totp_exempt is x-tcms-totp_exempt' );
    is_deeply( $paths->{'/sitemap/{map}.xml'}{get}{'x-tpsgi-data'}, { xml => 1 }, 'and data is x-tpsgi-data' );
    ok( $paths->{'/auth'}{post} && !$paths->{'/auth'}{get}, 'the method is the key of the operation' );
};

subtest 'the routes of posts' => sub {
    is( ref $paths->{'/posts/p-one'}{get}{'x-tpsgi-callback'}, 'CODE', 'a post named by its callback is routed' );
    ok( $paths->{'/secure/posts/p-one'}{get}, 'and so is its /secure copy' );
    is( $paths->{'/secure/posts/p-one'}{get}{'x-tcms-secure'}, 1, 'which is secure' );
    ok( !exists $paths->{'/posts/p-one'}{get}{'x-tcms-secure'}, 'while the route of the post is not' );
    is( $paths->{'/secure/'}{get}{'x-tcms-secure'},      1, 'and the /secure index is secure too' );
    is( $paths->{'/secure'}{get}{'x-tcms-secure'},       1, 'at /secure without the slash too' );
    is( $paths->{'/secure/p-two'}{get}{'x-tcms-secure'}, 1, 'a post whose own path is under /secure is secure' );
    ok( !exists $paths->{'/secure/secure/p-two'}, 'and gets no second copy' );

    # The flag that says setup is done, or the default route answers instead.
    open( my $fh, '>', 'config/setup' ) or die $!;
    close($fh)                          or die $!;
    my $res = $paths->{'/posts/p-one'}{get}{'x-tpsgi-callback'}->( { log_dir => "$ROOT/logs", verbose => 0 }, { route => '/posts/p-one', dispatcher => $paths->{'/posts/p-one'}{get} } );
    is_deeply( $res->[2], ['the post'], 'and it runs the sub that the name names' );
    ok( !exists $paths->{'/posts/{curly}'}, 'but a post whose path has a brace is not, since it would be a template' );
};

{

    package FakeTPSGI;
    sub new       ($class)   { return bless { log_dir => "$main::ROOT/logs", verbose => 0 }, $class }
    sub redirect  ( $, $to ) { return [ 302, [ Location => $to ], [''] ] }
    sub notfound  ( $, $ )   { return [ 404, [], ['Not Found'] ] }
    sub forbidden ( $, $ )   { return [ 403, [], ['Forbidden'] ] }
    sub ok        ( $, $ )   { return [ 200, [], ['Ok'] ] }
}

subtest 'a secure host' => sub {
    my $auth = Test::MockModule->new('Trog::Auth');
    $auth->redefine( session2user => sub ($cookie) { return $cookie eq 'good' ? 'someone' : '' } );
    $auth->redefine( acls4user    => sub ($user) { return [] } );

    my $secure_host = '';
    my $public_host = '';
    $html->redefine( secure_host => sub { return $secure_host } );
    $html->redefine( public_host => sub { return $public_host } );

    # What the route of $path and $method answers to a request for it on $host.
    # tPSGI answers a HEAD with the GET of the path.
    my $ask = sub ( $method, $path, $host, %request ) {
        undef $posted;
        my $operation = $paths->{$path}{ $method eq 'HEAD' ? 'get' : lc $method } or die "No $method $path";
        return $operation->{'x-tpsgi-callback'}->(
            FakeTPSGI->new(),
            { route => $path, method => $method, domain => $host, query_string => '', dispatcher => $operation, %request },
        );
    };

    my $res = $ask->( qw{GET /secure/posts/p-one routes.test.test}, cookies => 'tcmslogin=good' );
    is_deeply( $res->[2], ['the post'], 'without the setting, a route under /secure answers on any host' );
    is( $posted->{user},        'someone', 'for the user that the cookie names' );
    is( $posted->{secure_base}, '',        'and pages link to the login routes on this host' );
    ok( !$posted->{nocache}, 'and may be saved' );

    $secure_host = 'secure.test.test';

    $res = $ask->( qw{GET /login routes.test.test}, query_string => 'to=%2Fposts%2Fp-one' );
    is( $res->[0],                      302,                                                  'with it, GET /login on the public host is a redirect' );
    is( { @{ $res->[1] } }->{Location}, 'https://secure.test.test/login?to=%2Fposts%2Fp-one', 'to the same path and query on the secure host' );

    $res = $ask->(qw{GET /logout routes.test.test});
    is( { @{ $res->[1] } }->{Location}, 'https://secure.test.test/logout', 'a request without a query string is redirected without one' );

    $res = $ask->(qw{HEAD /secure/posts/p-one routes.test.test});
    is( $res->[0], 302, 'HEAD of a route under /secure is a redirect too' );
    ok( !$posted, 'and its callback does not run' );

    $res = $ask->(qw{POST /auth routes.test.test});
    is( $res->[0], 404, 'POST /auth on the public host is a 404, not a redirect' );

    $res = $ask->( qw{GET /lib/{module+} routes.test.test}, cookies => 'tcmslogin=good' );
    is( $res->[0], 302, 'a route with auth goes to the secure host, even with a cookie' );

    $res = $ask->( qw{GET /posts/p-one routes.test.test}, cookies => 'tcmslogin=good' );
    is_deeply( $res->[2], ['the post'], 'a route of both hosts answers on the public host' );
    is( $posted->{user},        '',                         'for nobody, whatever the cookie says' );
    is( $posted->{secure_base}, 'https://secure.test.test', 'and links to the login routes on the secure host' );
    ok( !$posted->{nocache}, 'and may be saved' );

    $res = $ask->( qw{GET /secure/posts/p-one Secure.Test.Test:443}, cookies => 'tcmslogin=good' );
    is_deeply( $res->[2], ['the post'], 'a route under /secure answers on the secure host, whatever the case and the port' );
    is( $posted->{user}, 'someone', 'for the user that the cookie names' );
    ok( $posted->{nocache}, 'and is never saved, since nginx would serve it on every host' );

    $res = $ask->(qw{GET /posts/p-one secure.test.test});
    is( $posted->{secure_base}, 'https://secure.test.test', "without general.hostname, a reader's page answers on the secure host too, and links the same way" );

    $public_host = 'routes.test.test';
    $res         = $ask->( qw{GET /posts/p-one secure.test.test}, query_string => 'page=2' );
    is( $res->[0],                      302,                                           "with it, a reader's page on the secure host is a redirect" );
    is( { @{ $res->[1] } }->{Location}, 'https://routes.test.test/posts/p-one?page=2', 'to the same path and query on the public host' );
    ok( !$posted, 'and its callback does not run' );

    $res = $ask->( qw{GET /p-private secure.test.test}, cookies => 'tcmslogin=good' );
    is_deeply( $res->[2], ['the post'], 'a secure route of a post is no reader\'s page, so it stays on the secure host' );
    is( $posted->{user}, 'someone', 'for the user that the cookie names' );

    $res = $ask->( qw{GET /p-private routes.test.test}, cookies => 'tcmslogin=good' );
    is( { @{ $res->[1] } }->{Location}, 'https://secure.test.test/p-private', 'and on the public host it is a redirect to the secure host' );

    $res = $ask->( qw{GET /secure/posts/p-one secure.test.test}, cookies => 'tcmslogin=good' );
    is_deeply( $res->[2], ['the post'], 'the /secure copy of a page stays on the secure host' );

    $res = $ask->(qw{GET /status secure.test.test});
    is( $res->[0], 200, 'and so does a route with no /secure copy, which is not a reader\'s page' );

    $public_host = $secure_host;
    $res         = $ask->(qw{GET /posts/p-one secure.test.test});
    is_deeply( $res->[2], ['the post'], 'a general.hostname that is the secure host sends nothing anywhere' );
};

subtest 'where a redirect may send you' => sub {
    my $operation = $paths->{'/posts/p-one'}{get};
    my $to        = sub ($to) {
        return $operation->{'x-tpsgi-callback'}->( { log_dir => "$ROOT/logs", verbose => 0 }, { route => '/posts/p-one', dispatcher => $operation, input => { to => $to } } )->[2][0];
    };
    is( $to->('/config'),              '/config',     'a path on this site is kept' );
    is( $to->('https://bogus.test/x'), '/x',          'the path of another site is all that is kept of it' );
    is( $to->('https://bogus.test'),   '/',           'and another site with no path is the root, not the other site' );
    is( $to->('//bogus.test'),         '/',           'even without a scheme' );
    is( $to->('////bogus.test'),       '/bogus.test', 'and a path that starts with two slashes, which names a site, starts with one' );
};

subtest 'the scripts of a route' => sub {
    my $post = $paths->{'/posts/p-one'}{get};
    is_deeply( $post->{'x-tcms-scripts'},                              [qw{highlight.min.js reveal.min.js}], 'a post page has the scripts of one' );
    is_deeply( $post->{'x-tcms-authenticated_scripts'},                [qw{post.js post_relations.js}],      'and the editing scripts for a reader who is logged in' );
    is_deeply( $paths->{'/secure/posts/p-one'}{get}{'x-tcms-scripts'}, $post->{'x-tcms-scripts'},            'and so does its /secure copy' );

    is_deeply( $paths->{'/metrics'}{get}{'x-tcms-scripts'}, ['chart.min.js'], 'a route that names its own has those' );
    ok( !exists $paths->{'/metrics'}{get}{'x-tcms-authenticated_scripts'}, 'and no others' );
    ok( !exists $paths->{'/login'}{get}{'x-tcms-scripts'},                 'a route that names none has none' );

    no warnings qw{once};
    my %declared = %Trog::Bundle::declared;
    ok( $declared{'main+highlight.min+reveal.min'},                     'the bundle of a post page is declared at startup, with main.js first' );
    ok( $declared{'main+highlight.min+reveal.min+post+post_relations'}, 'and the one for a reader who is logged in' );
    ok( $declared{'main+chart.min'},                                    'and the bundle of every other route' );
    ok( $declared{'main'},                                              'and a route that names no script has main.js alone' );
    ok( !$declared{'main+reveal.min+highlight.min'},                    'but no other list' );

    local @Theme::scripts = qw{theme.js};
    my $themed = { TCMS::build_routes() }->{paths};
    is_deeply( $themed->{'/login'}{get}{'x-tcms-scripts'},                     [qw{theme.js}],                                "a theme's scripts go on a route that names none" );
    is_deeply( $themed->{'/metrics'}{get}{'x-tcms-scripts'},                   [qw{theme.js chart.min.js}],                   "and before the scripts of a route that names its own" );
    is_deeply( $themed->{'/posts/p-one'}{get}{'x-tcms-scripts'},               [qw{theme.js highlight.min.js reveal.min.js}], "and before the scripts of a post page" );
    is_deeply( $themed->{'/secure/posts/p-one'}{get}{'x-tcms-scripts'},        [qw{theme.js highlight.min.js reveal.min.js}], "once, on a /secure copy that shares the route of its post" );
    is_deeply( $themed->{'/posts/p-one'}{get}{'x-tcms-authenticated_scripts'}, [qw{post.js post_relations.js}],               "and not among the scripts for a reader who is logged in, who gets both lists" );
    ok( $Trog::Bundle::declared{'main+theme+chart.min'}, 'the bundle of a themed route is declared' );

    @Theme::scripts = ();
    is_deeply( { TCMS::build_routes() }->{paths}{'/metrics'}{get}{'x-tcms-scripts'}, ['chart.min.js'], "and building the routes again does not keep the theme's scripts of the last build" );
};

subtest 'validation' => sub {
    my $token = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';
    is_deeply( [ $schema->validate_request( [ get => '/api/auth_change_request/{token}' ], { path => { token => $token } } ) ], [], 'a token that is a UUID is taken' );
    ok( scalar $schema->validate_request( [ get => '/api/auth_change_request/{token}' ], { path => { token => "$token|x" } } ), 'and one with more after it is not' );

    is_deeply( [ $schema->validate_request( [ get => '/api/requests_per' ], { query => { period => 'week', num_periods => 2 } } ) ], [], 'a period that requests_per knows is taken' );
    ok( scalar $schema->validate_request( [ get => '/api/requests_per' ], { query => { period      => 'fortnight' } } ), 'and one it does not is refused' );
    ok( scalar $schema->validate_request( [ get => '/api/requests_per' ], { query => { num_periods => 'many' } } ),      'as is a count that is not a number' );
};

subtest 'what a route takes from the request' => sub {
    my $names = sub ( $operation, $in = 'query' ) {
        return [ sort map { $_->{name} } grep { $_->{in} eq $in } @{ $operation->{parameters} // [] } ];
    };

    my @urchin = qw{utm_campaign utm_content utm_medium utm_source utm_term};
    is_deeply(
        $names->( $paths->{'/posts/p-one'}{get} ),
        [ sort qw{like page limit version older newer format embed nochrome year month}, @urchin ],
        'a page of posts takes its paging, search, feed and embed, and a campaign'
    );
    is_deeply( $names->( $paths->{'/humans.txt'}{get} ), $names->( $paths->{'/posts/p-one'}{get} ), 'and so does a route of posts that fixes its tag' );
    is_deeply( $names->( $paths->{'/search'}{get} ),     $names->( $paths->{'/posts/p-one'}{get} ), 'and so does the search, which is a page of posts' );
    is_deeply( $names->( $paths->{'/totp'}{get} ),       \@urchin,                                  'and a page that is not one takes no search' );
    ok( !( grep { $_ eq 'map' } @{ $names->( $paths->{'/sitemap/{map}.xml'}{get} ) } ), 'a name the path holds is not one of the query too' );
    is_deeply( $names->( $paths->{'/sitemap/{map}.xml'}{get}, 'path' ), ['map'], 'but of the path' );
    ok( !( grep { $_ eq 'title' || $_ eq 'scripts' || $_ eq 'template' } @{ $names->( $paths->{'/login'}{get} ) } ), 'the login page takes none of the names its page is made of' );

    my $form = sub ($operation) { return $operation->{requestBody}{content}{'application/x-www-form-urlencoded'}{schema} };
    is_deeply( [ sort keys( %{ $form->( $paths->{'/auth'}{post} )->{properties} } ) ], [qw{app contact_email display_name password to token username}], 'a login takes the fields of its form' );
    ok( !exists $form->( $paths->{'/auth'}{post} )->{additionalProperties},                   'and no others' );
    ok( $form->( $paths->{'/post/save'}{post} )->{additionalProperties},                      'a post takes the fields of its type too' );
    ok( exists $form->( $paths->{'/config/save'}{post} )->{properties}{'general.data_model'}, 'the configuration takes each setting by its name' );
    ok( !$paths->{'/post/save'}{post}{parameters},                                            'and a POST takes nothing in its query' );
};

subtest 'tPSGI routes by the document' => sub {
    plan skip_all => 'tPSGI is not installed' unless eval { require TPSGI::Router; 1 };

    my $router;
    is( exception { $router = TPSGI::Router->new( 'TCMS.pm' => \%openapi ) }, undef, 'which it can compile, so no route gives a name to two places' );
    return unless $router;

    my $login = $router->match( 'GET', '/login' );
    is_deeply( [ $router->validate( $login, query => { to => '/config' } ) ], [], 'the login page takes where to go next' );
    my ($status) = $router->validate( $login, query => { scripts => '//bogus.test/x.js' } );
    is( $status, 400, 'and nothing it does not declare' );
    ($status) = $router->validate( $router->match( 'POST', '/auth' ), body => { username => 'x', title => '<b>x</b>' }, content_type => 'application/x-www-form-urlencoded' );
    is( $status, 400, 'nor does a login' );
};

subtest 'robots' => sub {
    my $banned;
    my $renderer = Test::MockModule->new('Trog::Renderer');
    $renderer->redefine( render => sub { my ( $class, %args ) = @_; $banned = $args{data}{banned}; return [ 200, [], [''] ] } );

    TCMS::robots( { domain => 'routes.test.test' } );
    ok( ( grep { $_ eq '/avatar/*' } @$banned ),               'a template with no robot_name is disallowed with * for its variable' );
    ok( ( grep { $_ eq '/guest/reprovision/log/' } @$banned ), 'and one with a robot_name by that' );
    ok( !( grep { m/[{}]/ } @$banned ),                        'and no template is written as it is' );
};

done_testing();
