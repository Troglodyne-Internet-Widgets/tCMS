#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};
use Text::Xslate();
use Cwd();
use File::Slurper();
use Trog::Bundle();

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
    is_deeply( [ @{$failed}{qw{created started finished}} ], [ 1700000000, 1700000010, 1700000020 ], 'times are raw epoch seconds, for the browser to localize' );
    is( $done->{file},  '/assets/b.mp4', 'a job without notes shows the file of its arguments' );
    is( $done->{error}, '',              'a job that did not fail shows no error' );

    my $text = Text::Xslate->new( path => ["$REPO/www/templates/html/components"], type => 'html' )->render( 'jobs.tx', $page );
    like( $text, qr/\/assets\/a[.]mp4/,              'the template shows the file' );
    like( $text, qr/(?-x:The av1 transcode failed)/, '...and the error' );
    my $open  = qr{<span[ ]class="unixtimestamp"[ ]data-time="1">};
    my $close = qr{</span>};
    like( $text, qr{$open 1700000000 $close}x, 'each time is a raw epoch in a unixtimestamp container' );
    unlike( $text, qr/\d{4}-\d\d-\d\d \d\d:\d\d:\d\d/, '...and no formatted date' );
    unlike( $text, qr/<script|toLocaleString/,         'the page carries no script of its own, since main.js localizes the times' );
};

subtest 'a failed job has a button that retries it, and no other job has one' => sub {
    my ($page) = @rendered;
    my $text   = Text::Xslate->new( path => ["$REPO/www/templates/html/components"], type => 'html' )->render( 'jobs.tx', $page );
    my $form   = qr{<form[ ]method="POST"[ ]action="/admin/jobs/retry">};
    my @forms  = $text =~ m{$form(.*?)</form>}sg;
    is( scalar(@forms), 1, 'one of the two jobs has a retry button' );
    like( $forms[0], qr{name="id"[ ]value="2"}, '...the failed one, which the form names' );
};

subtest 'the retry route' => sub {
    my $retry = do { no warnings "once"; $Trog::Routes::HTML::routes{"/admin/jobs/retry"} };
    ok( $retry, 'there is a route' );
    is_deeply( [ @{$retry}{qw{method auth noindex nocache}} ], [ 'POST', 1, 1, 1 ], 'for POST, behind a login, kept out of indexes and the cache' );
    is( $retry->{callback}, \&Trog::Routes::HTML::jobs_retry, 'and it is answered by jobs_retry()' );

    my @retried;
    my $answer = 1;
    $queue->redefine( retry_failed => sub ($id) { push @retried, $id; return $answer } );

    # What the page that the browser goes back to shows, out of the cookie of the redirect.
    my sub outcome ($response) {
        my %h = @{ $response->[1] };
        return ( $response->[0], $h{Location}, Trog::Routes::HTML::feedback_from_cookie( $h{'Set-Cookie'} // '' ) );
    }

    is( Trog::Routes::HTML::jobs_retry( request( id => 2 ) )->[0],                                              303, 'a visitor who is not logged in is sent to the login' );
    is( Trog::Routes::HTML::jobs_retry( request( id => 2, user => 'someone', user_acls => ['blogger'] ) )->[0], 403, 'a user who is not an admin gets 403' );
    ok( !@retried, 'and neither retries a job' );

    my $admin = request( user => 'boss', user_acls => ['admin'] );
    is_deeply( [ outcome( Trog::Routes::HTML::jobs_retry( { %$admin, id => 2 } ) ) ], [ 303, '/admin/jobs', 0, 'Job 2 is in the queue again.' ], 'an admin retries the job, and goes back to the jobs, which say so' );
    is_deeply( \@retried,                                                             [2],                                                       '...that the form named' );

    my ( undef, undef, $twice ) = outcome( Trog::Routes::HTML::jobs_retry( { %$admin, id => [ 1, 3 ] } ) );
    is( $twice,       0, 'a form that names the id twice retries one job' );
    is( $retried[-1], 3, '...the last that it names' );

    $answer = 0;
    is_deeply( [ outcome( Trog::Routes::HTML::jobs_retry( { %$admin, id => 1 } ) ) ], [ 303, '/admin/jobs', 1, 'Job 1 is not a failed job, so it was not retried.' ], 'a job that did not fail is not retried, and the page says so' );

    @retried = ();
    foreach my $bad ( undef, '', '2; DROP', '-1', '1.5' ) {
        my ( $code, $to, $failure ) = outcome( Trog::Routes::HTML::jobs_retry( { %$admin, id => $bad } ) );
        is_deeply( [ $code, $to, $failure ], [ 303, '/admin/jobs', 1 ], 'an id of ' . ( $bad // 'nothing' ) . ' is refused' );
    }
    ok( !@retried, '...and the queue is not asked about it' );
};

subtest 'main.js localizes the times, on every page' => sub {
    my $js = File::Slurper::read_text("$REPO/www/scripts/main.js");
    like( $js, qr/DOMContentLoaded/,                      'main.js waits for the page' );
    like( $js, qr/querySelectorAll[(]'[.]unixtimestamp'/, '...finds the times' );
    like( $js, qr/toLocaleString/,                        '...and shows the time of day for those with data-time' );
    ok( !-e "$REPO/www/templates/html/components/localize_times.tx", 'no template carries a copy' );

    my @global = Trog::Bundle::page_scripts();
    is_deeply( \@global,                                            ['main.js'],           'every page links main.js' );
    is_deeply( [ Trog::Bundle::page_scripts(qw{main.js post.js}) ], [qw{main.js post.js}], '...once, and before the scripts of the route' );
    is_deeply( [ Trog::Bundle::page_scripts(qw{post.js}) ],         [qw{main.js post.js}], '...also when the route does not name it' );
    like( Trog::Bundle::scripts(@global)->{body}, qr/toLocaleString/, 'and the bundle holds the handler' );
};

done_testing();
