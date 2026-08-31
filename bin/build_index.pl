#!/usr/bin/perl

use strict;
use warnings;

use lib 'lib';
use Trog::Data;
use Trog::Config;
use Trog::SQLite::TagIndex;

=head1 SYNOPSIS

Rebuild the post index and the route table from the posts on disk.

Use this to build the post index after you import data, otherwise it's not
needed -- the index is maintained as posts are written, so the only time it
gets out of step with the flat files is when something other than tCMS put them
there.

=head2 USAGE

    bin/build_index.pl

Takes no arguments, and must be run from the tCMS root, as the data paths in
the configuration are relative to it.

Safe to re-run; it rebuilds from scratch rather than adding to what's there.

=cut

my $conf   = Trog::Config::get();
my $search = Trog::Data->new($conf);

Trog::SQLite::TagIndex::build_index($search);
Trog::SQLite::TagIndex::build_routes($search);
