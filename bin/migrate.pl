#!/usr/bin/env perl

use v5.36;
use re '/aa';

use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long qw{GetOptions};
use Time::HiRes  ();

use Trog::Config;
use Trog::Data::FlatFile;
use Trog::Data::SQLite;

=head1 SYNOPSIS

Move a site from the FlatFile data model to the SQLite one.

=head2 USAGE

    bin/migrate.pl [--dry-run] [--batch N] [--quiet]

Must be run from the tCMS root, as the data paths are relative to it.

    --dry-run   Say what would be carried over, and write nothing.
    --batch N   Posts per transaction.  Default 500.
    --quiet     Only complain; say nothing on success.

=head2 WHAT IT DOES

Reads every version of every post out of data/files and writes them into
data/posts.sqlite, oldest version first, so that the version bookkeeping ends up
the way it would have if the posts had been written there all along.

Nothing is deleted.  data/files is left exactly as it found it, and so is the
flat file model's tag index in data/posts.db, so the way back is to put
data_model back to FlatFile.

Safe to re-run.  Post versions already carried over are skipped rather than
duplicated, which also makes it safe to run once against a live site and again
after a final quiet period to pick up whatever was written in between.

When it has finished, switch the site over in config/main.cfg:

    [general]
        data_model=SQLite

...and restart, so the workers build the new model rather than the old one.

=head2 TERMINATION CONDITIONS

Exits non-zero if any post could not be carried over, having written everything
it could.  Each batch is a transaction, so a batch that fails is not half
applied, and re-running picks up from what actually landed.

=cut

# So that progress and complaints interleave in the order they happened when
# this is piped to a log rather than watched.
STDOUT->autoflush(1);
STDERR->autoflush(1);

my $usage = "Usage: bin/migrate.pl [--dry-run] [--batch N] [--quiet]\n";

# Printed and exited rather than died: Carp::Always is in the dependency chain,
# and a usage message wearing a stack trace reads like a crash.
sub usage_error (@complaint) {
    print STDERR @complaint, $usage;
    exit 2;
}

my ( $dry_run, $quiet, $batch_size ) = ( 0, 0, 500 );
GetOptions(
    'dry-run' => \$dry_run,
    'quiet'   => \$quiet,
    'batch=i' => \$batch_size,
) or usage_error();

usage_error("--batch must be a positive number of posts.\n") if $batch_size < 1;

sub say_unless_quiet (@args) {
    return if $quiet;
    say @args;
    return;
}

my $config = Trog::Config::get();
my $from   = Trog::Data::FlatFile->new($config);
my $to     = Trog::Data::SQLite->new($config);

# raw, so we get the history rather than only the current version of each post,
# and so that no acl filtering stands between a migration and the data it is
# supposed to be moving.
my $started = [ Time::HiRes::gettimeofday() ];
my @posts   = $from->get( raw => 1, limit => 0 );
if ( !@posts ) {
    print STDERR "No posts found in data/files -- is this a tCMS root, and is it on the FlatFile model?\n";
    exit 2;
}

# Oldest first: write() appends, and the version bookkeeping is maintained as it
# goes, so feeding it in order is what makes first_id and latest_id right.
@posts = sort { ( $a->{id} // '' ) cmp ( $b->{id} // '' ) || ( $a->{version} // 0 ) <=> ( $b->{version} // 0 ) } @posts;

# One query rather than one per post.
my $present = $to->versions_present();

# Separately: an array in a list assignment swallows everything after it.
my @batch;
my ( $written, $skipped, $failed ) = ( 0, 0, 0 );

sub flush_batch () {
    return unless @batch;

    if ($dry_run) {
        $written += scalar(@batch);
        @batch = ();
        return;
    }

    local $@;
    eval {
        $to->write( \@batch );
        $written += scalar(@batch);
        1;
    } or do {
        my $error = $@;
        $error =~ s/\n.*//s;

        # A batch is one transaction, so one bad post took every other post in
        # the batch down with it.  Go back over them one at a time: a migration
        # wants everything that can land to land, and a list naming exactly what
        # could not -- not five hundred posts rejected on account of one.
        say STDERR "A batch of " . scalar(@batch) . " failed ($error); retrying it one post at a time.";

        foreach my $post (@batch) {
            local $@;
            eval {
                $to->write( [$post] );
                $written++;
                1;
            } or do {
                my $why = $@;
                $why =~ s/\n.*//s;
                $failed++;
                say STDERR "  could not write $post->{id} version " . ( $post->{version} // 0 ) . ": $why";
            };
        }
    };

    @batch = ();
    return;
}

foreach my $post (@posts) {
    if ( !$post->{id} ) {
        say STDERR "Skipping a post with no id, which is not something this can carry over";
        $failed++;
        next;
    }

    if ( $present->{ $post->{id} }{ $post->{version} // 0 } ) {
        $skipped++;
        next;
    }

    push( @batch, $post );
    flush_batch() if @batch >= $batch_size;
}
flush_batch();

my $elapsed = Time::HiRes::tv_interval($started);

if ($dry_run) {
    say_unless_quiet( sprintf( "Would carry over %d post version(s); %d already present.", $written, $skipped ) );
    say_unless_quiet("Nothing was written.  Re-run without --dry-run to do it.");
    exit( $failed ? 1 : 0 );
}

# Worth stating plainly rather than trusting the counters: they say what this
# thought it did, and the databases say what is actually there.
my $expected = scalar( grep { $_->{id} } @posts );
my $have     = 0;
$have += scalar( keys %$_ ) foreach values %{ $to->versions_present() };

say_unless_quiet( sprintf( "Carried over %d post version(s), skipped %d already present, in %.1fs.", $written, $skipped, $elapsed ) );
say_unless_quiet( sprintf( "data/files holds %d post version(s); data/posts.sqlite now holds %d.", $expected, $have ) );

if ( $failed || $have < $expected ) {
    say STDERR sprintf( "%d post version(s) did not make it across.  Fix what the errors above name and re-run; what landed will be skipped.", $failed || ( $expected - $have ) );
    exit 1;
}

say_unless_quiet("Set general.data_model to SQLite in config/main.cfg and restart to serve from it.");
exit 0;
