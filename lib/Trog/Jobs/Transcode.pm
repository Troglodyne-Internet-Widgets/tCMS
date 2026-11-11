package Trog::Jobs::Transcode;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use File::Which();
use IPC::Run();
use URI::Escape();

use Trog::Config();
use Trog::Jobs();

=head1 NAME

Trog::Jobs::Transcode - the transcode of an uploaded video, in the worker of the queue

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

=cut

sub ffmpeg_command ( $in, $out, $profile ) {
    return ( 'ffmpeg', qw{-nostdin -hide_banner -loglevel error -n -protocol_whitelist file}, '-i', $in, @{ $Trog::Jobs::profiles{$profile}{args} }, '-f', 'mp4', $out );
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
$outputs, and save it as a new version.  Returns how many posts it saved.

The two are compared decoded, because a post can hold its C<href>
percent-encoded, as C</assets/a%20b.mp4>, and a job holds the name of the
file, as C</assets/a b.mp4>.

=cut

sub update_posts ( $href, $outputs ) {
    require Trog::Data;    # Not at load: the data models load this module.
    my $data = Trog::Data->new( Trog::Config::get() );

    my $file  = URI::Escape::uri_unescape($href);
    my $saved = 0;
    foreach my $post ( grep { URI::Escape::uri_unescape( $_->{href} // '' ) eq $file } $data->get( limit => 0, acls => ['admin'] ) ) {
        $post->{ $Trog::Jobs::profiles{$_}{field} } = $outputs->{$_} foreach keys %Trog::Jobs::profiles;
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

1;
