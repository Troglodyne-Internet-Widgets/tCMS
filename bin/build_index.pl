#!/usr/bin/env perl

use 5.040;
use re '/aa';

use lib 'lib';
use Trog::Data;
use Trog::Config;
use Trog::SQLite::TagIndex;

=head1 SYNOPSIS

Rebuild the FlatFile model's tag index and route table, data/posts.db, from the
posts in data/files.

Use this to build the index after you import posts, otherwise it is not needed:
tCMS keeps the index up to date as it writes posts, so the only time it gets out
of step with the flat files is when something other than tCMS put them there.

The SQLite model keeps its tags and routes with the posts, and has no separate
index.  On a site served from it, this says so and changes nothing.

=head2 USAGE

    bin/build_index.pl

Takes no arguments, and must be run from the tCMS root, as the data paths in
the configuration are relative to it.

Safe to re-run.  It empties the index first and builds it again, in one
transaction, so tags and routes that no post has any more are gone afterwards.

=cut

my $data = Trog::Data->new( Trog::Config::get() );
if ( !$data->isa('Trog::Data::FlatFile') ) {
    say "This site serves from " . ref($data) . ", which has no separate index.  Nothing to do.";
    exit 0;
}

Trog::SQLite::TagIndex::rebuild($data);
