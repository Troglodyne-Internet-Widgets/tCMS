#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Cwd();
use File::Path();
use File::Temp();
use IPC::Run3();
use Path::Tiny();

use FindBin::libs;

our $REPO   = Cwd::getcwd();
our $OLDCWD = $REPO;
our $ROOT   = File::Temp::tempdir( 'tcms-transcode-existing-XXXXXX', TMPDIR => 1, CLEANUP => 0 );

END {
    chdir($OLDCWD)                 if $OLDCWD;
    File::Path::remove_tree($ROOT) if $ROOT && -d $ROOT;
}

File::Path::make_path( "$ROOT/data", "$ROOT/www/assets/private" );
chdir($ROOT) or die $!;

require_ok('Trog::Jobs') or BAIL_OUT("Can't find SUT");

my $mp4 = pack( 'N a4 a4 N a8 x64', 24, 'ftyp', 'isom', 512, 'isomiso2' );
Path::Tiny::path('www/assets/one.mp4')->spew_raw($mp4);
Path::Tiny::path('www/assets/private/two.mp4')->spew_raw($mp4);
Path::Tiny::path('www/assets/done.mp4')->spew_raw($mp4);
Path::Tiny::path('www/assets/done.av1.mp4')->spew_raw('x');
Path::Tiny::path('www/assets/done.h264.mp4')->spew_raw('x');
Path::Tiny::path('www/assets/note.txt')->spew_raw("words\n");

my sub run (@args) {
    my $out;
    IPC::Run3::run3( [ $^X, "-I$REPO/lib", "$REPO/bin/tcms-transcode-existing", @args ], \undef, \$out, \$out );
    return $out;
}

my $before = { map { $_->stringify => $_->slurp_raw } grep { $_->is_file } Path::Tiny::path('www/assets')->children, Path::Tiny::path('www/assets/private')->children };

my $dry = run('--dry-run');
like( $dry, qr/Would\squeue\s\/assets\/one[.]mp4/, 'a dry run names a video that it would queue' );
is( scalar( @{ Trog::Jobs::list_jobs(10) } ), 0, '...and queues nothing' );

my $out = run();
like( $out, qr/2\svideo\(s\)\squeued/, 'it queues the two videos that have no transcodes' );
my @jobs = @{ Trog::Jobs::list_jobs(10) };
is_deeply( [ sort map { $_->{args}[0] } @jobs ], [ '/assets/one.mp4', '/assets/private/two.mp4' ], 'one job for each, for the right files' );
is_deeply( [ map { $_->{task} } @jobs ],         [ ('transcode') x 2 ],                            '...of the transcode task' );

my $after = { map { $_->stringify => $_->slurp_raw } grep { $_->is_file } Path::Tiny::path('www/assets')->children, Path::Tiny::path('www/assets/private')->children };
is_deeply( $after, $before, 'no file was added, changed or removed' );

done_testing();
