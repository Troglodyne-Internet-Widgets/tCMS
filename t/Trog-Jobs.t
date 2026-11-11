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
use Test::Fatal qw{exception};
use Text::Xslate();

use FindBin::libs;

# Every path in tCMS is relative to the root of an install, so the tests stand in
# a root of their own, before the code under test is loaded.
our $REPO   = Cwd::getcwd();
our $ROOT   = File::Temp::tempdir( 'tcms-jobs-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
our $OLDCWD = $REPO;

END {
    chdir($OLDCWD)                 if $OLDCWD;
    File::Path::remove_tree($ROOT) if $ROOT && -d $ROOT;
}

File::Path::make_path( "$ROOT/data", "$ROOT/www/assets/private" );
chdir($ROOT) or die $!;

require_ok('Trog::Jobs')       or BAIL_OUT("Can't find SUT");
require_ok('Trog::DataModule') or BAIL_OUT("Can't find Trog::DataModule");

# The first bytes of an MP4 file are enough for libmagic to say so.
my $mp4 = pack( 'N a4 a4 N a8 x64', 24, 'ftyp', 'isom', 512, 'isomiso2' );

my sub asset ( $name, $bytes = $mp4 ) {
    Path::Tiny::path("www/assets/$name")->spew_raw($bytes);
    return "/assets/$name";
}

my sub upload ( $name, $bytes ) {
    my $tmp = Path::Tiny::path("$ROOT/upload-$name");
    $tmp->spew_raw($bytes);
    return { tempname => "$tmp", filename => $name };
}

subtest 'an upload of a video is queued, and anything else is not' => sub {
    my @queued;
    my $jobs = Test::MockModule->new('Trog::DataModule');
    $jobs->redefine( WARN => sub { fail("Unexpected warning: @_") } );
    my $queue = Test::MockModule->new('Trog::Jobs');
    $queue->redefine( enqueue_transcode => sub ($href) { push @queued, $href; return 1 } );

    my $post = Trog::DataModule::process( { id => 'vid', visibility => 'public', file => upload( 'clip.mp4', $mp4 ) } );
    is_deeply( \@queued, ['/assets/vid.clip.mp4'], 'one job, for the file that was moved into the assets' );
    is( $post->{href},         '/assets/vid.clip.mp4', 'and the post is written with the original at once' );
    is( $post->{content_type}, 'video/mp4',            '...as a video' );
    ok( -e 'www/assets/vid.clip.mp4', 'and the original is where it was served' );

    @queued = ();
    Trog::DataModule::process( { id => 'doc', visibility => 'public', file => upload( 'note.txt', "just some words\n" ) } );
    is_deeply( \@queued, [], 'a text upload is not queued' );

    # The preview of a video is an image, and an attachment may be anything.
    Trog::DataModule::process( { id => 'pic', visibility => 'public', file => upload( 'a.txt', "words\n" ), preview_file => upload( 'p.mp4', $mp4 ) } );
    is_deeply( \@queued, ['/assets/pic.p.mp4'], 'each upload is judged by its own type' );

    @queued = ();
    $queue->redefine( enqueue_transcode => sub { die "the queue is down\n" } );
    my @warned;
    $jobs->redefine( WARN => sub { push @warned, shift } );
    my $survived = Trog::DataModule::process( { id => 'down', visibility => 'public', file => upload( 'down.mp4', $mp4 ) } );
    is( $survived->{href}, '/assets/down.down.mp4', 'a queue that is down does not lose the upload' );
    like( $warned[0], qr/(?-x:the queue is down)/, '...and it is a warning' );

    my $replaced = Trog::DataModule::process( { id => 'vid2', visibility => 'public', av1_href => '/assets/old.av1.mp4', h264_href => '/assets/old.h264.mp4', file => upload( 'new.txt', "x\n" ) } );
    ok( !exists $replaced->{av1_href} && !exists $replaced->{h264_href}, 'a new file does not keep the transcodes of the old one' );
};

subtest 'the outputs, and the assets they come from' => sub {
    my %out = %{ Trog::Jobs::outputs_for('/assets/id.My Clip.mov') };
    is_deeply( \%out, { av1 => '/assets/id.My Clip.av1.mp4', h264 => '/assets/id.My Clip.h264.mp4' }, 'the outputs have new names beside the original' );
    like( exception { Trog::Jobs::asset_path('/assets/../config/auth.db') }, qr/(?-x:Not an asset path)/, 'a path out of the assets is refused' );
    like( exception { Trog::Jobs::asset_path('/assets/x/y.mp4') },           qr/(?-x:Not an asset path)/, 'so is one in a directory that is not the assets' );
    is( Trog::Jobs::asset_path('/assets/private/x.mp4'), 'www/assets/private/x.mp4', 'a private asset is allowed' );
};

subtest 'the jobs can be listed' => sub {
    my $first  = Trog::Jobs::enqueue_transcode('/assets/one.mp4');
    my $second = Trog::Jobs::enqueue_transcode('/assets/two.mp4');
    is_deeply( [ map { $_->{id} } @{ Trog::Jobs::list_jobs(2) } ], [ $second, $first ], 'the newest first, as many as asked for' );
    is( Trog::Jobs::minion()->job($first)->info->{notes}{href}, '/assets/one.mp4', '...each with the file it is for' );
};

subtest 'only a failed job is retried' => sub {

    # A queue of its own, so that the dequeue takes this job and no job that an
    # earlier subtest queued.  A job fails only while a worker holds it, and a
    # worker takes only a task that it knows, as the worker of tCMS does.
    my $minion = Trog::Jobs::register_tasks( Trog::Jobs::minion() );
    my $id     = $minion->enqueue( transcode => ['/assets/three.mp4'], { queue => 'retrytest' } );
    ok( !Trog::Jobs::retry_failed($id), 'a job that waits in the queue is not retried' );

    my $worker = $minion->worker->register;
    my $job    = $worker->dequeue( 0, { queues => ['retrytest'] } );
    is( $job->id, $id, 'the worker holds the job' );
    ok( !Trog::Jobs::retry_failed($id), 'a job that runs is not retried' );

    $job->fail("The av1 transcode failed\n");
    is( $minion->job($id)->info->{state}, 'failed', 'the job failed' );
    ok( Trog::Jobs::retry_failed($id), 'a failed job is retried' );
    is_deeply( [ @{ $minion->job($id)->info }{qw{state retries}} ], [ 'inactive', 1 ], '...so it waits in the queue again, with one retry counted' );
    $worker->unregister;

    ok( !Trog::Jobs::retry_failed( $id + 1000 ), 'a job that is not there is not retried' );
};

subtest 'the video lists AV1 first, then H.264, then the original' => sub {
    my $tx   = Text::Xslate->new( path => ["$REPO/www/templates/html/components"], type => 'html' );
    my $html = $tx->render( 'video_sources.tx', { post => { href => '/assets/v.mov', content_type => 'video/quicktime', av1_href => '/assets/v.av1.mp4', h264_href => '/assets/v.h264.mp4' } } );
    my @src  = $html =~ m{<source\ssrc="([^"]+)"\stype=['"]([^'"]+)}g;
    is_deeply( [ @src[ 0, 2, 4 ] ], [qw{/assets/v.av1.mp4 /assets/v.h264.mp4 /assets/v.mov}], 'in that order' );
    like( $html, qr/av01/, 'AV1 has its codecs' );
    like( $html, qr/avc1/, 'H.264 has its codecs' );

    my $before = $tx->render( 'video_sources.tx', { post => { href => '/assets/v.mov', content_type => 'video/quicktime' } } );
    is( scalar( () = $before =~ /<source/g ), 1, 'until the job is done, only the original' );
};

subtest 'the existing videos are found, and no transcode is among them' => sub {
    asset('good.mp4');
    asset('x.av1.mp4');
    Path::Tiny::path('www/assets/private/secret.mp4')->spew_raw($mp4);
    Path::Tiny::path('www/assets/readme.txt')->spew_raw("words\n");
    my @found = Trog::Jobs::video_assets();
    ok( ( grep { $_ eq '/assets/private/secret.mp4' } @found ),       'a private video is found' );
    ok( ( grep { $_ eq '/assets/good.mp4' } @found ),                 'so is a public one' );
    ok( !( grep { /[.]av1[.]mp4\z|[.]h264[.]mp4\z|readme/ } @found ), 'an output and a text file are not' );
};

done_testing();
