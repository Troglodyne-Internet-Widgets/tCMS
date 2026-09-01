#!/usr/bin/env perl

use v5.36;
use re '/aa';

use FindBin;
use lib "$FindBin::Bin/../lib";

use Trog::Config;
use Trog::Data::FlatFile;
use Trog::Data::SQLite;

=head1 SYNOPSIS

Copy a FlatFile site's posts into the SQLite data model.

=head2 USAGE

    bin/migrate-to-sqlite.pl

Takes no arguments, and must be run from the tCMS root, as the data paths are
relative to it.

Reads every version of every post out of data/files and writes them into
data/posts.sqlite, oldest version first so that the version bookkeeping lands
the same way it would have if the posts had been written there all along.

Nothing is deleted: data/files is left exactly as it was, so the way back is to
put data_model back to FlatFile.  Once the site is running on SQLite, switch it
over in config/main.cfg:

    [general]
        data_model=SQLite

Safe to re-run.  Posts already carried over are skipped rather than duplicated,
which also makes it safe to run once against a live site and again after a
final quiet period to pick up whatever was written in between.

=cut

my $conf = Trog::Config::get();
my $from = Trog::Data::FlatFile->new($conf);
my $to   = Trog::Data::SQLite->new($conf);

# raw, so we get the history rather than just the current version of each post.
my @posts = $from->get( raw => 1, limit => 0 );
die "No posts found in data/files -- is this a tCMS root?\n" unless @posts;

# Oldest first.  write() appends, and post_versions is maintained as it goes.
@posts = sort { ( $a->{created} // 0 ) <=> ( $b->{created} // 0 ) || ( $a->{version} // 0 ) <=> ( $b->{version} // 0 ) } @posts;

my ( $written, $skipped, $failed ) = ( 0, 0, 0 );
foreach my $post (@posts) {
    if ( !$post->{id} ) {
        say STDERR "Skipping a post with no id (created $post->{created})";
        $failed++;
        next;
    }

    # Idempotent: (uuid, version) is unique, so this is asking the same question
    # the unique index would answer, just without making it an error.  read()
    # rather than get(), which would decorate the post with its author's display
    # name and drag the auth database into a migration that has no use for it.
    my $have = $to->read( { limit => 0, id => $post->{id}, version => $post->{version} // 0 } );
    if (@$have) {
        $skipped++;
        next;
    }

    local $@;
    eval {
        $to->write( [$post] );
        $written++;
        1;
    } or do {
        say STDERR "Could not write $post->{id} version " . ( $post->{version} // 0 ) . ": $@";
        $failed++;
    };
}

say "Carried over $written post versions, skipped $skipped already present, failed $failed.";
say "Set general.data_model to SQLite in config/main.cfg to start serving from it.";

exit( $failed ? 1 : 0 );
