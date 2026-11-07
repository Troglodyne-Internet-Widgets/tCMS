#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};
use Cwd();
use File::Path();
use File::Temp();
use File::Which();
use Path::Tiny();
use IPC::Run3();
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

subtest 'the commands' => sub {
    my %out = %{ Trog::Jobs::outputs_for('/assets/id.My Clip.mov') };
    is_deeply( \%out, { av1 => '/assets/id.My Clip.av1.mp4', h264 => '/assets/id.My Clip.h264.mp4' }, 'the outputs have new names beside the original' );

    foreach my $profile (qw{av1 h264}) {
        my @cmd = Trog::Jobs::ffmpeg_command( 'www/in.mov', 'www/out.part', $profile );
        my %at  = map { $cmd[$_] => $_ } 0 .. $#cmd;
        is( $cmd[0],                                'ffmpeg', "$profile runs ffmpeg" );
        is( $cmd[ $at{'-protocol_whitelist'} + 1 ], 'file',   "$profile allows only the file protocol" );
        ok( $at{'-protocol_whitelist'} < $at{'-i'}, '...before the input, where ffmpeg reads it' );
        is( $cmd[ $at{'-i'} + 1 ], 'www/in.mov', '...and the input is the original' );
        ok( $at{'-n'},         '...and it never overwrites' );
        ok( $at{'+faststart'}, '...and puts the index first' );
        is( $cmd[-1], 'www/out.part', '...and ends with the output' );
    }
    my @av1 = Trog::Jobs::ffmpeg_command(qw{a b av1});
    ok( ( grep { $_ eq 'libsvtav1' } @av1 ) && ( grep { $_ eq 'libopus' } @av1 ), 'the AV1 profile uses SVT-AV1 and Opus' );
    my @h264 = Trog::Jobs::ffmpeg_command(qw{a b h264});
    ok( ( grep { $_ eq 'libx264' } @h264 ) && ( grep { $_ eq 'aac' } @h264 ), 'the H.264 profile uses x264 and AAC' );
    like( exception { Trog::Jobs::asset_path('/assets/../config/auth.db') }, qr/(?-x:Not an asset path)/, 'a path out of the assets is refused' );
    like( exception { Trog::Jobs::asset_path('/assets/x/y.mp4') },           qr/(?-x:Not an asset path)/, 'so is one in a directory that is not the assets' );
    is( Trog::Jobs::asset_path('/assets/private/x.mp4'), 'www/assets/private/x.mp4', 'a private asset is allowed' );
};

subtest 'run_ffmpeg gives each way of failing a reason' => sub {
    ok( Trog::Jobs::run_ffmpeg( $^X, '-e', '1' ), 'a command that succeeds returns true' );

    like( exception { Trog::Jobs::run_ffmpeg('tcms-no-such-program') }, qr/(?-x:is not installed)/, 'a program that is not installed dies, and says so' );

    my $failure = exception { Trog::Jobs::run_ffmpeg( $^X, '-e', 'print STDERR "bad input\n"; exit 3' ) };
    like( $failure, qr/(?-x:exited with status 3)/, 'a command that fails dies with its status' );
    like( $failure, qr/(?-x:bad input)/,            '...and what it said' );

    no warnings "once";
    local $Trog::Jobs::ffmpeg_timeout = 1;
    my $started = time;
    like( exception { Trog::Jobs::run_ffmpeg( $^X, '-e', 'sleep 30' ) }, qr/(?-x:more than 1 seconds)/, 'a command that runs too long dies, with the limit' );
    ok( time - $started < 20, '...and is stopped at the limit' );
};

subtest 'a transcode writes new files beside the original' => sub {
    my $href = asset('good.mp4');
    my @ran;
    my $jobs = Test::MockModule->new('Trog::Jobs');
    $jobs->redefine(
        run_ffmpeg => sub (@cmd) {
            push @ran, [@cmd];
            Path::Tiny::path( $cmd[-1] )->spew_raw('transcoded');
            return 1;
        }
    );

    my $out = Trog::Jobs::transcode($href);
    is_deeply( $out, { av1 => '/assets/good.av1.mp4', h264 => '/assets/good.h264.mp4' }, 'it returns where the files are' );
    is( scalar(@ran),                                           2,            'it ran ffmpeg twice' );
    is( Path::Tiny::path('www/assets/good.av1.mp4')->slurp_raw, 'transcoded', 'the AV1 file is there' );
    is( Path::Tiny::path('www/assets/good.mp4')->slurp_raw,     $mp4,         'the original is as it was' );
    is_deeply( [ sort grep { /part/ } map { $_->basename } Path::Tiny::path('www/assets')->children ], [], 'no partial file is left' );

    @ran = ();
    unlink "www/assets/good.h264.mp4";
    Path::Tiny::path('www/assets/good.av1.mp4')->spew_raw('served');
    Trog::Jobs::transcode($href);
    is( scalar(@ran),                                           1,        'a file that is there is not made again' );
    is( Path::Tiny::path('www/assets/good.av1.mp4')->slurp_raw, 'served', '...and is never written over' );
};

subtest 'a failure keeps the original, leaves nothing, and says why' => sub {
    my $href = asset('bad.mp4');
    my $jobs = Test::MockModule->new('Trog::Jobs');
    $jobs->redefine(
        run_ffmpeg => sub (@cmd) {
            Path::Tiny::path( $cmd[-1] )->spew_raw('half');
            die "ffmpeg exited with status 1\nInvalid data found when processing input\n";
        }
    );

    my $why = !eval { Trog::Jobs::transcode($href); 1 } ? $@ : '';
    like( $why, qr/(?-x:av1 transcode failed.*Invalid data found)/s, 'the reason says what failed and what ffmpeg said' );
    is( Path::Tiny::path('www/assets/bad.mp4')->slurp_raw, $mp4, 'the original is as it was' );
    ok( !-e 'www/assets/bad.av1.mp4' && !-e 'www/assets/bad.h264.mp4', 'no output is served' );
    is_deeply( [ grep { /part/ } map { $_->basename } Path::Tiny::path('www/assets')->children ], [], 'and no partial file is left' );

    like( exception { Trog::Jobs::transcode('/assets/missing.mp4') }, qr/(?-x:original is missing)/, 'a missing original fails, and says so' );
};

subtest 'the task records the outcome in the job' => sub {
    my $href = asset('task.mp4');
    my $jobs = Test::MockModule->new('Trog::Jobs');
    my $saved;
    $jobs->redefine( update_posts => sub ( $h, $o ) { return $saved } );
    $jobs->redefine( run_ffmpeg   => sub (@cmd) { Path::Tiny::path( $cmd[-1] )->spew_raw('ok'); return 1 } );

    my $minion = Trog::Jobs::register_tasks( Trog::Jobs::minion() );
    my $id     = Trog::Jobs::enqueue_transcode($href);

    $saved = 2;
    $minion->perform_jobs;
    my $job = $minion->job($id);
    is( $job->info->{state},         'finished', 'a job that made its files, and saved the posts, finishes' );
    is( $job->info->{result}{posts}, 2,          '...and says how many posts it saved' );
    is( $job->info->{notes}{href},   $href,      '...and which file it was for' );

    # The post is not stored when the upload queues the job, so the job asks again.
    $saved = 0;
    my $again = Trog::Jobs::enqueue_transcode($href);
    $minion->perform_jobs;
    is( $minion->job($again)->info->{state},   'inactive', 'with no post to save yet, the job waits to run again' );
    is( $minion->job($again)->info->{retries}, 1,          '...and counts the try' );
    $minion->job($again)->remove;

    $jobs->redefine( run_ffmpeg => sub (@cmd) { die "ffmpeg exited with status 1\nno good\n" } );
    my $bad = Trog::Jobs::enqueue_transcode( asset('fail.mp4') );
    $minion->perform_jobs;
    my $failed = $minion->job($bad)->info;
    is( $failed->{state}, 'failed', 'a job that could not transcode fails' );
    like( $failed->{result}, qr/(?-x:no good)/, '...and its result is the reason' );

    my @listed = map { $_->{id} } @{ Trog::Jobs::list_jobs(10) };
    ok( ( grep { $_ == $bad } @listed ) && ( grep { $_ == $id } @listed ), 'the jobs can be listed' );
};

subtest 'the posts of the video list the new files' => sub {
    my @added;
    my $fake = bless {}, 'FakeData';
    {
        no warnings 'once';
        *FakeData::get = sub { return ( { id => 'a', href => '/assets/v.mp4' }, { id => 'b', href => '/assets/other.mp4' }, { id => 'c', href => '/assets/v.mp4' } ) };
        *FakeData::add = sub ( $, $post ) { push @added, $post; return 0 };
    }
    my $data = Test::MockModule->new('Trog::Data');
    $data->redefine( new => sub { return $fake } );
    my $conf = Test::MockModule->new('Trog::Config');
    $conf->redefine( get => sub { return {} } );

    my $outputs = Trog::Jobs::outputs_for('/assets/v.mp4');
    is( Trog::Jobs::update_posts( '/assets/v.mp4', $outputs ), 2, 'it saves the posts of that file' );
    is_deeply( [ map { $_->{id} } @added ],                   [qw{a c}],                                     '...and no other' );
    is_deeply( [ $added[0]{av1_href}, $added[0]{h264_href} ], [ '/assets/v.av1.mp4', '/assets/v.h264.mp4' ], 'each now holds both files' );
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
    asset('x.av1.mp4');
    Path::Tiny::path('www/assets/private/secret.mp4')->spew_raw($mp4);
    Path::Tiny::path('www/assets/readme.txt')->spew_raw("words\n");
    my @found = Trog::Jobs::video_assets();
    ok( ( grep { $_ eq '/assets/private/secret.mp4' } @found ),       'a private video is found' );
    ok( ( grep { $_ eq '/assets/good.mp4' } @found ),                 'so is a public one' );
    ok( !( grep { /[.]av1[.]mp4\z|[.]h264[.]mp4\z|readme/ } @found ), 'an output and a text file are not' );
};

subtest 'with ffmpeg, a real clip is transcoded' => sub {
    plan skip_all => 'ffmpeg is not installed' unless File::Which::which('ffmpeg');

    my $encoders;
    IPC::Run3::run3( [qw{ffmpeg -hide_banner -encoders}], \undef, \$encoders, \$encoders );
    plan skip_all => 'ffmpeg has no libx264 or libsvtav1' unless $encoders =~ /libx264/ && $encoders =~ /libsvtav1/;

    my $made;
    IPC::Run3::run3( [qw{ffmpeg -nostdin -loglevel error -f lavfi -i testsrc=duration=1:size=128x96:rate=10 -pix_fmt yuv420p www/assets/real.mp4}], \undef, \$made, \$made );
    is( $?, 0, 'ffmpeg made a clip' ) or diag($made);
    my $before = Path::Tiny::path('www/assets/real.mp4')->slurp_raw;
    my $out    = Trog::Jobs::transcode('/assets/real.mp4');
    ok( -s "www$out->{av1}" && -s "www$out->{h264}", 'both files exist' );
    is( Path::Tiny::path('www/assets/real.mp4')->slurp_raw, $before, 'and the original is as it was' );
};

done_testing();
