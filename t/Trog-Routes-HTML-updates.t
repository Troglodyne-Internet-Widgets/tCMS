#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};
use Text::Xslate();
use Cwd();

use FindBin::libs;

our $REPO = Cwd::getcwd();

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

{

    package FakeTPSGI;
    sub new       ($class)      { return bless {}, $class }
    sub see_also  ( $, $to, @ ) { return [ 303, [ Location => $to ], [''] ] }
    sub forbidden ( $, $, @ )   { return [ 403, [], ['Forbidden'] ] }
}

my sub request (%over) { return { tpsgi => FakeTPSGI->new, %over } }

my %routes = do { no warnings 'once'; %Trog::Routes::HTML::routes };
foreach my $path (qw{/config/updates/check /config/updates/pull}) {
    is_deeply( [ @{ $routes{$path} }{qw{method auth}} ], [ 'POST', 1 ], "$path is a POST, behind a login" );
}

my ( @checks, @pulls );
my $updates = Test::MockModule->new('Trog::Updates');
$updates->redefine( enqueue_check => sub { push @checks, 1; return 1 } );
$updates->redefine( enqueue_update => sub ($name) { die "There is no checkout named $name to update\n" if $name eq 'bogus'; push @pulls, $name; return 1 } );

my @shown;
my $html = Test::MockModule->new('Trog::Routes::HTML');
$html->redefine( config => sub ( $query = {} ) { push @shown, $query; return [ 200, [], ['config'] ] } );

subtest 'who may check and pull' => sub {
    foreach my $route ( \&Trog::Routes::HTML::updates_check, \&Trog::Routes::HTML::updates_pull ) {
        is( $route->( request( checkout => 'tCMS' ) )->[1][1],                                           '/login', 'a visitor who is not logged in is sent to the login' );
        is( $route->( request( checkout => 'tCMS', user => 'someone', user_acls => ['blogger'] ) )->[0], 403,      'a user who is not an admin gets 403' );
    }
    ok( !@checks && !@pulls, 'and neither queues anything' );
};

subtest 'updates_check' => sub {
    my $res = Trog::Routes::HTML::updates_check( request( user => 'boss', user_acls => ['admin'] ) );
    is( scalar @checks, 1,         'an admin queues a check' );
    is( $res->[1][1],   '/config', '...and goes back to /config' );
};

subtest 'updates_pull' => sub {
    my $res = Trog::Routes::HTML::updates_pull( request( user => 'boss', user_acls => ['admin'], checkout => [qw{tPSGI tCMS}] ) );
    is_deeply( \@pulls, ['tCMS'], 'an admin queues an update of the checkout, the last one posted' );
    is( $res->[1][1], '/config', '...and goes back to /config' );

    Trog::Routes::HTML::updates_pull( request( user => 'boss', user_acls => ['admin'], checkout => 'bogus' ) );
    is_deeply( [ @{ $shown[-1] }{qw{failure message}} ], [ 1, 'There is no checkout named bogus to update' ], 'a name that is not a checkout shows /config with the reason' );
};

subtest 'the Versions section of /config' => sub {
    my %page = (
        config_sections => [],
        themes          => [],
        updates         => {
            checked_at  => 1700000000,
            pending     => [ { task => 'update', state => 'active', checkout => 'tPSGI' } ],
            last_update => { state => 'failed', checkout => 'tCMS', error => 'The system packages in metamerge.yml change' },
            checkouts   => [
                { name => 'tCMS',  label => 'tCMS',  branch => 'master', short_head => 'aaaaaaaaaaaa', short_upstream => 'bbbbbbbbbbbb', state => 'behind',  behind => 3, dirty => 0 },
                { name => 'tPSGI', label => 'tPSGI', branch => 'master', short_head => 'cccccccccccc', short_upstream => 'cccccccccccc', state => 'current', dirty  => 0 },
                { name => 'theme', label => 'spec',  branch => 'main',   short_head => 'dddddddddddd', state          => 'private',      dirty => 0 },
                { name => 'other', label => 'other', branch => 'main',   short_head => 'eeeeeeeeeeee', short_upstream => 'ffffffffffff', state => 'behind', behind => 1, dirty => 1 },
            ],
        },
    );
    my $text = Text::Xslate->new( path => ["$REPO/www/templates/html/components"], type => 'html' )->render( 'config.tx', \%page );

    like( $text, qr/aaaaaaaaaaaa .* bbbbbbbbbbbb .* behind[ ]by[ ]3/s, 'a checkout shows its commit, the upstream and how far behind' );
    my @buttons = $text =~ /name="checkout"[ ]value="([^"]+)"/g;
    is_deeply( \@buttons, ['tCMS'], 'only a checkout that is behind and clean gets a button' );
    like( $text, qr/(?-x:behind by 1, with local changes)/,                       'a dirty one says why it has none' );
    like( $text, qr/(?-x:Update of tPSGI is running)/,                            'a running update is shown' );
    like( $text, qr/(?-x:The last update, of tCMS, failed: The system packages)/, 'and why the last one failed' );
    like( $text, qr{action="/config/updates/check"},                              'a check can be asked for' );
};

done_testing();
