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

my $route = do { no warnings "once"; $Trog::Routes::HTML::routes{"/admin/jobs"} };
ok( $route, 'there is a route' );
is_deeply( [ @{$route}{qw{method auth noindex nocache}} ], [ 'GET', 1, 1, 1 ], 'for GET, behind a login, kept out of indexes and the cache, as /admin/sessions is' );
is( $route->{callback}, \&Trog::Routes::HTML::jobs, 'and it is answered by jobs()' );

my $queue = Test::MockModule->new('Trog::Jobs');
$queue->redefine(
    list_jobs => sub ($limit) {
        return [
            { id => 2, task => 'transcode', state => 'failed',   notes => { href => '/assets/a.mp4' }, args => ['/assets/a.mp4'], created => 1700000000, started => 1700000010, finished => 1700000020, result => "The av1 transcode failed: bad\n" },
            { id => 1, task => 'transcode', state => 'finished', notes => {}, args => ['/assets/b.mp4'], created => 1700000000, started => 1700000010, finished => 1700000020, result => { posts => 1 } },
        ];
    }
);

my @rendered;
my $html = Test::MockModule->new('Trog::Routes::HTML');
$html->redefine( index => sub ( $data, @rest ) { push @rendered, $data; return [ 200, [], ['jobs'] ] } );

my sub request (%over) { return { tpsgi => FakeTPSGI->new, %over } }

subtest 'who may see it' => sub {
    my $anon = Trog::Routes::HTML::jobs( request() );
    is( $anon->[0],    303,      'a visitor who is not logged in is redirected' );
    is( $anon->[1][1], '/login', '...to the login' );

    my $user = Trog::Routes::HTML::jobs( request( user => 'someone', user_acls => ['blogger'] ) );
    is( $user->[0], 403, 'a user who is not an admin gets 403' );

    ok( !@rendered, 'and neither is shown the page' );

    my $admin = Trog::Routes::HTML::jobs( request( user => 'boss', user_acls => ['admin'] ) );
    is( $admin->[0], 200, 'an admin gets the page' );
};

subtest 'what the page shows' => sub {
    my ($page) = @rendered;
    is( $page->{template}, 'jobs.tx', 'it renders its template' );
    my ( $failed, $done ) = @{ $page->{jobs} };
    is_deeply(
        [ @{$failed}{qw{task state file error}} ],
        [ qw{transcode failed /assets/a.mp4}, "The av1 transcode failed: bad\n" ],
        'a failed job shows its task, state, file and why'
    );
    like( $failed->{created}, qr/\A\d{4}-\d\d-\d\d\s\d\d:\d\d:\d\d\z/, 'times are dates' );
    ok( $failed->{started} && $failed->{finished}, '...for the start and the finish too' );
    is( $done->{file},  '/assets/b.mp4', 'a job without notes shows the file of its arguments' );
    is( $done->{error}, '',              'a job that did not fail shows no error' );

    my $text = Text::Xslate->new( path => ["$REPO/www/templates/html/components"], type => 'html' )->render( 'jobs.tx', $page );
    like( $text, qr/\/assets\/a[.]mp4/,              'the template shows the file' );
    like( $text, qr/(?-x:The av1 transcode failed)/, '...and the error' );
};

done_testing();
