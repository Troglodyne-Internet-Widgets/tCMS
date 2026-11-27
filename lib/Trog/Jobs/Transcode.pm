package Trog::Jobs::Transcode;

# ABSTRACT: The transcode of an uploaded video, in the worker of the queue

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Config();
use File::Which();
use IPC::Run();
use URI::Escape();

use Trog::Config();
use Trog::Jobs();
use Trog::Utils();

=head1 DESCRIPTION

This is the task C<transcode>, and what it runs.  It runs in the worker of the
job queue, C<bin/tcms-jobs minion worker>, and never in a request: its process
is a child of that worker, in the unit of the worker, and not of the master of
tPSGI.  A request queues the task with C<enqueue_transcode> of L<Trog::Jobs>,
which also has the profiles of the outputs, and where they go.

All the paths here are relative to the root of the tCMS install, like the paths
of the rest of tCMS.

=cut

# Seconds that one ffmpeg may run.  AV1 encodes at about half of real time, so
# this is generous for a video of an hour, and it still ends a hung process.
our $ffmpeg_timeout = 21600;

=head1 FUNCTIONS

=head2 ffmpeg_command($in, $out, $profile) = LIST

The command line, as a list, that makes the file $out of the file $in.  A list
because no shell reads it.  C<-protocol_whitelist file> comes before C<-i>, so
that a playlist inside an upload can fetch no URL and read no other file.

=over 4

=item in - Str - the file to read

=item out - Str - the file to write

=item profile - Str - the name of a profile in C<%Trog::Jobs::profiles>, such as C<av1>

=back

Returns Array of Str, the program C<ffmpeg> and its arguments.

    my @cmd = Trog::Jobs::Transcode::ffmpeg_command( 'www/in.mov', 'www/out.part', 'av1' );

=cut

sub ffmpeg_command ( $in, $out, $profile ) {
    return ( 'ffmpeg', qw{-nostdin -hide_banner -loglevel error -n -protocol_whitelist file}, '-i', $in, @{ $Trog::Jobs::profiles{$profile}{args} }, '-f', 'mp4', $out );
}

=head2 run_ffmpeg(@command)

Run the command and wait for it for at most C<$ffmpeg_timeout> seconds.  Kills
it at the limit.  Dies with the reason if it fails, and the reason has the end
of what ffmpeg said.  The reason gives the exit status, or the name of the
signal that killed ffmpeg.

=over 4

=item @command - Str - the program and its arguments, as ffmpeg_command() gives them

=back

Returns Int, 1 when the command exits 0.

Dies when the program is not installed, does not run, runs for too long, is
killed by a signal, or exits with a status that is not 0.

    run_ffmpeg( ffmpeg_command( $in, $part, $profile ) );

=cut

sub run_ffmpeg (@command) {
    die "ffmpeg is not installed\n" unless File::Which::which( $command[0] );

    my ( $in, $out, $err ) = ( '', '', '' );
    my $ok = eval { IPC::Run::run( \@command, \$in, \$out, \$err, IPC::Run::timeout($ffmpeg_timeout) ); 1 };
    my ( $why, $status ) = ( $@, $? );
    return 1 if $ok && $status == 0;

    $err = substr( $err, -500 ) if length $err > 500;
    $err =~ s/\s+\z//;
    $why =
        index( $why, q{timeout} ) >= 0 ? "ffmpeg ran for more than $ffmpeg_timeout seconds and was stopped"
      : $why                           ? "ffmpeg did not run: $why"
      : $status & 127                  ? 'ffmpeg was killed by signal ' . signal_name( $status & 127 )
      :                                  sprintf( 'ffmpeg exited with status %d', $status >> 8 );
    die "$why\n$err\n";
}

=head2 signal_name($number) = STRING

The name of the signal $number on this system, such as C<SEGV>, or the number
itself if the system has no name for it.

=over 4

=item number - Int - the number of the signal

=back

Returns Str|Int, the name, or $number.

    my $name = Trog::Jobs::Transcode::signal_name(9);

=cut

sub signal_name ($number) {
    my @names = split ' ', $Config::Config{sig_name};
    return $names[$number] // $number;
}

=head2 transcode($href) = HASHREF

Make the files of outputs_for($href) from the original at $href.  The original
stays.

A file that is there is not made again, and one is never written over.  A
finished output takes its name by a hard link, which fails if the name is
taken.  So a file that tCMS served is never changed in place.

=over 4

=item href - Str - the C</assets/...> path of the original

=back

Returns HashRef[Str], the outputs by profile name, as outputs_for() of
L<Trog::Jobs> gives them.

Dies with the reason if $href is not an asset path, if the original is
missing, or if one output fails, and then leaves no partial file.

    my $outputs = Trog::Jobs::Transcode::transcode($href);

=cut

sub transcode ($href) {
    my $in      = Trog::Jobs::asset_path($href);
    my $outputs = Trog::Jobs::outputs_for($href);
    die "The original is missing: $href\n" unless -e $in;

    foreach my $profile ( sort keys %$outputs ) {
        my $final = Trog::Jobs::asset_path( $outputs->{$profile} );
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

Point each post whose C<href> names the file of $href at the files of
$outputs, and save it as a new version.

$href is the name of the file, as C</assets/a b.mp4>, because transcode() reads
the file by it, so it is not decoded.  A post matches when its C<href> decoded
is that name, as C</assets/a%20b.mp4> is.  A post saved before uploads were
encoded holds the name as it is, and matches too.

The outputs are names of files too, so each post gets them percent-encoded,
as C</assets/a%20b.av1.mp4>, whatever its own C<href> holds.

=over 4

=item href - Str - the C</assets/...> path of the original, not encoded

=item outputs - HashRef[Str] - the outputs by profile name, as transcode() gives them

=back

Returns Int, how many posts it saved.

    my $saved = Trog::Jobs::Transcode::update_posts( $href, $outputs );

=cut

sub update_posts ( $href, $outputs ) {
    require Trog::Data;    # Not at load: the data models load this module.
    my $data = Trog::Data->new( Trog::Config::get() );

    my $saved = 0;
    foreach my $post ( grep { local ($_) = $_; my $stored = $_->{href} // ''; $stored eq $href || URI::Escape::uri_unescape($stored) eq $href } $data->get( limit => 0, acls => ['admin'] ) ) {
        foreach my $profile ( keys %Trog::Jobs::profiles ) {
            $post->{ $Trog::Jobs::profiles{$profile}{field} } = Trog::Utils::path_href( $outputs->{$profile} );
        }
        $data->add($post);
        $saved++;
    }
    return $saved;
}

=head2 transcode_task($job, $href)

The task C<transcode>.  Makes the outputs of $href with transcode(), and
points the posts at them with update_posts().  When no post holds $href yet,
it retries the job in a minute, up to five times.  The result of the job has
C<outputs> and C<posts>, how many posts it saved.  When the transcode fails,
the job fails with the reason.

=over 4

=item job - Minion::Job - the job

=item href - Str - the C</assets/...> path of the video

=back

Returns Bool, what L<Minion::Job/fail>, L<Minion::Job/retry> or
L<Minion::Job/finish> returns.

Minion calls it as

    Trog::Jobs::Transcode::transcode_task( $job, $href );

=cut

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

1;
