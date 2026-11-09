package Trog::Jobs;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use File::Which();
use IPC::Run();
use List::Util();
use Minion();
use Path::Tiny();

use Trog::Config();
use Trog::Updates();
use Trog::Utils();

=head1 NAME

Trog::Jobs - the job queue of tCMS, and the video transcode that runs in it

=head1 DESCRIPTION

Work that a request must not wait for goes in a L<Minion> queue.  The queue is
an SQLite database in F<data/>, next to the other databases of tCMS.  A request
only puts a job in it.  A separate process, the worker of L<Trog::Jobs::App>,
takes the jobs out and runs them.  See the Readme for how to start it.

The tasks are C<transcode>, whose one argument is the C</assets/...> path of
an uploaded video, and C<update_check> and C<update> of L<Trog::Updates>.

All the paths here are relative to the root of the tCMS install, like the paths
of the rest of tCMS.

=cut

our $dsn = 'sqlite:data/jobs.db';

# Seconds that one ffmpeg may run.  AV1 encodes at about half of real time, so
# this is generous for a video of an hour, and it still ends a hung process.
our $ffmpeg_timeout = 21600;

# What the outputs are called, what is in them, and the codecs that a <source>
# tells the browser about.  The ffmpeg options come from the issue that asked
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
    $minion->add_task( transcode    => \&transcode_task );
    $minion->add_task( update_check => \&Trog::Updates::check_task );
    $minion->add_task( update       => \&Trog::Updates::update_task );
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

=head2 ffmpeg_command($in, $out, $profile) = LIST

The command line, as a list, that makes the file $out of the file $in.  A list
because no shell reads it.  C<-protocol_whitelist file> comes before C<-i>, so
that a playlist inside an upload can fetch no URL and read no other file.

=cut

sub ffmpeg_command ( $in, $out, $profile ) {
    return ( 'ffmpeg', qw{-nostdin -hide_banner -loglevel error -n -protocol_whitelist file}, '-i', $in, @{ $profiles{$profile}{args} }, '-f', 'mp4', $out );
}

=head2 run_ffmpeg(@command)

Run the command and wait for it for at most C<$ffmpeg_timeout> seconds.  Kills
it at the limit.  Dies with the reason if it fails, and the reason has the end
of what ffmpeg said.

=cut

sub run_ffmpeg (@command) {
    die "ffmpeg is not installed\n" unless File::Which::which( $command[0] );

    my ( $in, $out, $err ) = ( '', '', '' );
    my $ok  = eval { IPC::Run::run( \@command, \$in, \$out, \$err, IPC::Run::timeout($ffmpeg_timeout) ); 1 };
    my $why = $@;
    return 1 if $ok && $? == 0;

    $err = substr( $err, -500 ) if length $err > 500;
    $err =~ s/\s+\z//;
    $why = $why ? ( $why =~ /timeout/ ? "ffmpeg ran for more than $ffmpeg_timeout seconds and was stopped" : "ffmpeg did not run: $why" ) : sprintf( 'ffmpeg exited with status %d', $? >> 8 );
    die "$why\n$err\n";
}

=head2 transcode($href) = HASHREF

Make the files of outputs_for($href) from the original at $href.  Returns the
outputs by profile name.  Dies with the reason if one fails, and then leaves no
partial file.  The original stays.

A file that is there is not made again, and one is never written over.  A
finished output takes its name by a hard link, which fails if the name is
taken.  So a file that tCMS served is never changed in place.

=cut

sub transcode ($href) {
    my $in      = asset_path($href);
    my $outputs = outputs_for($href);
    die "The original is missing: $href\n" unless -e $in;

    foreach my $profile ( sort keys %$outputs ) {
        my $final = asset_path( $outputs->{$profile} );
        next if -e $final;

        my $part = "$final.part.$$";
        my $ok   = eval { run_ffmpeg( ffmpeg_command( $in, $part, $profile ) ); 1 };
        my $why  = $@;
        $ok &&= -s $part;
        $why ||= "ffmpeg made no $profile file\n";
        if ( $ok && !link( $part, $final ) && !-e $final ) {
            $ok  = 0;
            $why = "Could not keep $outputs->{$profile}: $!\n";
        }
        unlink $part;
        die "The $profile transcode failed: $why" unless $ok;
    }
    return $outputs;
}

=head2 update_posts($href, $outputs) = INTEGER

Point each post whose C<href> is $href at the files of $outputs, and save it as
a new version.  Returns how many posts it saved.

=cut

sub update_posts ( $href, $outputs ) {
    require Trog::Data;    # Not at load: the data models load this module.
    my $data = Trog::Data->new( Trog::Config::get() );

    my $saved = 0;
    foreach my $post ( grep { ( $_->{href} // '' ) eq $href } $data->get( limit => 0, acls => ['admin'] ) ) {
        $post->{ $profiles{$_}{field} } = $outputs->{$_} foreach keys %profiles;
        $data->add($post);
        $saved++;
    }
    return $saved;
}

# The post may not be written when the job starts, because the upload enqueues
# the job before add() stores the post.  So with no post to update, try again
# in a minute, a few times.  The files are made by then, so a try is cheap.
sub transcode_task ( $job, $href ) {
    my $outputs = eval { transcode($href) };
    if ( !$outputs ) {
        my $why = $@ || "The transcode failed for no reason\n";
        return $job->fail($why);
    }

    my $saved = update_posts( $href, $outputs );
    return $job->retry( { delay => 60 } ) if !$saved && $job->retries < 5;
    return $job->finish( { outputs => $outputs, posts => $saved } );
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
