package Trog::Jobs;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use List::Util();
use Minion();
use Path::Tiny();

use Trog::Jobs::Transcode();
use Trog::Jobs::Updates();
use Trog::Utils();

=head1 NAME

Trog::Jobs - the job queue of tCMS, and the video transcode that runs in it

=head1 DESCRIPTION

Work that a request must not wait for goes in a L<Minion> queue.  The queue is
an SQLite database in F<data/>, next to the other databases of tCMS.  A request
only puts a job in it.  A separate process, the worker of L<Trog::Jobs::App>,
takes the jobs out and runs them.  See the Readme for how to start it.

This module is the queue, and the part of each task that a request, or a
script such as F<bin/tcms-transcode-existing>, runs: it queues the jobs and
reads them.  The tasks themselves run in the worker, and are in modules of
their own under C<Trog::Jobs::>, so that it is clear which process a sub runs
in.  They are C<transcode>, in L<Trog::Jobs::Transcode>, whose one argument is
the C</assets/...> path of an uploaded video, and C<update_check> and
C<update>, in L<Trog::Jobs::Updates>.

All the paths here are relative to the root of the tCMS install, like the paths
of the rest of tCMS.

=cut

our $dsn = 'sqlite:data/jobs.db';

# What the outputs are called, what is in them, and the codecs that a <source>
# tells the browser about.  outputs_for reads the names here, and the
# transcode in Trog::Jobs::Transcode reads the options.  The ffmpeg options come from the issue that asked
# for the transcode, and they are a starting point: tune them on real uploads.
our %profiles = (
    av1 => {
        suffix => '.av1.mp4',
        field  => 'av1_href',
        args   => [qw{-c:v libsvtav1 -preset 6 -crf 40 -g 120 -c:a libopus -b:a 96k -movflags +faststart}],
    },
    h264 => {
        suffix => '.h264.mp4',
        field  => 'h264_href',
        args   => [qw{-c:v libx264 -preset slow -crf 23 -g 120 -profile:v high -c:a aac -b:a 128k -movflags +faststart}],
    },
);

=head1 FUNCTIONS

=head2 minion() = Minion

The queue.  Memoized.

=cut

sub minion {
    state $minion = Minion->new( SQLite => $dsn );
    return $minion;
}

=head2 register_tasks($minion) = $minion

Teach $minion the tasks of tCMS.  The application of the worker calls this.

=cut

sub register_tasks ($minion) {
    $minion->add_task( transcode    => \&Trog::Jobs::Transcode::transcode_task );
    $minion->add_task( update_check => \&Trog::Jobs::Updates::check_task );
    $minion->add_task( update       => \&Trog::Jobs::Updates::update_task );
    return $minion;
}

=head2 enqueue_transcode($href) = ID

Put a transcode of the video at C</assets/...> $href in the queue.  A post that
holds that path is updated when the job is done.

=cut

sub enqueue_transcode ($href) {
    return minion()->enqueue( transcode => [$href], { notes => { href => $href } } );
}

=head2 list_jobs($limit) = ARRAYREF

The newest $limit jobs, each a hashref as L<Minion::Backend/list_jobs> gives it.

=cut

sub list_jobs ( $limit = 100 ) {
    return minion()->backend->list_jobs( 0, $limit )->{jobs};
}

=head2 retry_failed($id) = BOOL

Put the job $id back in the queue, if it failed.  Returns true if it did, and
false for a job that is not there or did not fail.  A transcode that runs again
skips each output that is already there, so the retry of a job whose encode
finished does only what came after the encode.

=cut

sub retry_failed ($id) {
    my $job = minion()->job($id) or return 0;
    return 0 unless $job->info->{state} eq 'failed';
    return $job->retry ? 1 : 0;
}

=head2 asset_path($href) = STRING

The file under F<www/> that the C</assets/...> path $href names.  Dies for a
path that is not directly in F<www/assets> or F<www/assets/private>, so that
nothing outside them reaches ffmpeg.

=cut

sub asset_path ($href) {
    my $dotted = defined $href && $href =~ m{(?:\A|/)[.][.]?(?:/|\z)};
    die "Not an asset path: $href\n" if !defined $href || $dotted || $href !~ m{\A/assets/(?:private/)?[^/\0]+\z};
    return "www$href";
}

=head2 outputs_for($href) = HASHREF

The paths of the files that the transcode of $href writes, by profile name.
They sit beside the original, under names that tCMS never served before.

=cut

sub outputs_for ($href) {
    ( my $stem = $href ) =~ s/[.][^.\/]+\z//;
    return { map { $_ => "$stem$profiles{$_}{suffix}" } keys %profiles };
}

=head2 video_assets() = LIST

The C</assets/...> path of each video file in F<www/assets> and
F<www/assets/private>, except the outputs of a transcode.

=cut

sub video_assets {
    my @found;
    foreach my $dir ( 'assets', 'assets/private' ) {
        next unless -d "www/$dir";
        foreach my $file ( sort map { $_->basename } grep { $_->is_file } Path::Tiny::path("www/$dir")->children ) {
            next if List::Util::any { $file =~ /\Q$_->{suffix}\E\z/ } values %profiles;
            my $href = "/$dir/$file";
            push @found, $href if ( Trog::Utils::mime_type( asset_path($href) ) // '' ) =~ m{\Avideo/};
        }
    }
    return @found;
}

1;
