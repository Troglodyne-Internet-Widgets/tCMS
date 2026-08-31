#!/usr/bin/env perl

use v5.36;
use re '/aa';

# Migrate early on tcms3 flatfile sites to store rather than compute much data (dec 2021) code

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::Config;
use Trog::Data;
use List::Util;
use UUID::Tiny;

use Trog::SQLite;
use Trog::SQLite::TagIndex;

=head1 SYNOPSIS

Migrate early tCMS3 flatfile sites to store rather than compute much data
(December 2021).

Visibility used to be worked out from a post's tags on every read, and whether
a series tiled its children from its href.  This walks every post and writes
those out as fields, so that the reading code doesn't have to derive them.

=head2 USAGE

Edit $user below to suit your installation, then:

    bin/migrate3.pl

Run from the tCMS root.  Assumes migrate2.pl has already been run.

=head2 CAVEATS

Historical.  Posts are re-saved through the data model, so this creates a new
revision of every post on the site.

Posts with no visibility tag at all are left without one, as there's no safe
guess between public and private.

The 'All Posts' series at the end is left commented out; uncomment it if your
instance wants /posts to be a series of its own.

=cut

# Kill the post index
unlink "$FindBin::Bin/../data/posts.db";
$ENV{NOHUP} = 1;

sub uuid { return UUID::Tiny::create_uuid_as_string( UUID::Tiny::UUID_V1, UUID::Tiny::UUID_NS_DNS ); }

# Modify these variables to suit your installation.
my $user = 'george';
my @extra_series;

my $conf        = Trog::Config::get();
my $search_info = Trog::Data->new($conf);

my @all = $search_info->get( raw => 1, limit => 0 );
foreach my $post (@all) {
    if ( defined $post->{form} && $post->{form} eq 'series.tx' ) {
        $post->{tiled} = scalar( grep { $_ eq $post->{local_href} } qw{/files /audio /video /image /series /about} );
    }
    if ( !defined $post->{visibility} ) {
        $post->{visibility} = 'public'   if grep { $_ eq 'public' } @{ $post->{tags} };
        $post->{visibility} = 'private'  if grep { $_ eq 'private' } @{ $post->{tags} };
        $post->{visibility} = 'unlisted' if grep { $_ eq 'unlisted' } @{ $post->{tags} };
    }

    # Otherwise re-save the posts with is_video etc
    $search_info->add($post);
}

# Rebuild the index
Trog::SQLite::TagIndex::build_index($search_info);
Trog::SQLite::TagIndex::build_routes($search_info);

# Add in the series
my $series = [
    {
        "acls"       => [],
        aliases      => [],
        "callback"   => "Trog::Routes::HTML::posts",
        method       => 'GET',
        "data"       => "All Posts",
        "href"       => "/posts",
        "local_href" => "/posts",
        "preview"    => "/img/sys/testpattern.jpg",
        "tags"       => [qw{series}],
        visibility   => 'unlisted',
        "title"      => "All Posts",
        user         => $user,
        form         => 'series.tx',
        child_form   => 'series.tx',
        aclname      => 'posts',
    },
];

#$search_info->add(@$series,@extra_series);
