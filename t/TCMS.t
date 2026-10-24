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
    File::Copy::copy( "$REPO/schema/$_", "$ROOT/schema/$_" ) or die $! for qw{auth.schema flatfile.schema log.schema};

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
        );
    }
);

# What a post's route runs, which the routes of posts name.
require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't load the routes");
my $html = Test::MockModule->new('Trog::Routes::HTML');
$html->redefine( posts => sub { return [ 200, [], ['the post'] ] } );

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
        $manual->{parameters},
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

    # The flag that says setup is done, or the default route answers instead.
    open( my $fh, '>', 'config/setup' ) or die $!;
    close($fh)                          or die $!;
    my $res = $paths->{'/posts/p-one'}{get}{'x-tpsgi-callback'}->( { log_dir => "$ROOT/logs", verbose => 0 }, { route => '/posts/p-one', dispatcher => $paths->{'/posts/p-one'}{get} } );
    is_deeply( $res->[2], ['the post'], 'and it runs the sub that the name names' );
    ok( !exists $paths->{'/posts/{curly}'}, 'but a post whose path has a brace is not, since it would be a template' );
};

subtest 'validation' => sub {
    my $token = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';
    is_deeply( [ $schema->validate_request( [ get => '/api/auth_change_request/{token}' ], { path => { token => $token } } ) ], [], 'a token that is a UUID is taken' );
    ok( scalar $schema->validate_request( [ get => '/api/auth_change_request/{token}' ], { path => { token => "$token|x" } } ), 'and one with more after it is not' );

    is_deeply( [ $schema->validate_request( [ get => '/api/requests_per' ], { query => { period => 'week', num_periods => 2 } } ) ], [], 'a period that requests_per knows is taken' );
    ok( scalar $schema->validate_request( [ get => '/api/requests_per' ], { query => { period      => 'fortnight' } } ), 'and one it does not is refused' );
    ok( scalar $schema->validate_request( [ get => '/api/requests_per' ], { query => { num_periods => 'many' } } ),      'as is a count that is not a number' );
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
