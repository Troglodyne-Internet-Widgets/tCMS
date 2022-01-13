#!/usr/bin/perl

use strict;
use warnings;

# Migrate early on tcms3 flatfile sites to 'all posts are series code' (august 2021) code

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::Config;
use Trog::Data;
use List::Util;
use UUID::Tiny;

use Trog::SQLite;
use Trog::SQLite::TagIndex;

# Kill the post index
unlink "$FindBin::Bin/../data/posts.db";
$ENV{NOHUP} = 1;

sub uuid { return UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V1, UUID::Tiny::UUID_NS_DNS); }

# Modify these variables to suit your installation.
my $user = 'george';
my @extra_series = (
);

my $conf = Trog::Config::get();
my $search_info = Trog::Data->new($conf);

my @all = $search_info->get( raw => 1, limit => 0 );
#TODO add in the various things we need to data
foreach my $post (@all) {
    if ( defined $post->{form} && $post->{form} eq 'series.tx' ) {
        $post->{tiled} = scalar(grep { $_ eq $post->{local_href} } qw{/files /audio /video /image /series /about});
    }
    if (!defined $post->{visibility}) {
        $post->{visibility} = 'public' if grep { $_ eq 'public' } @{$post->{tags}};
        $post->{visibility} = 'private' if grep { $_ eq 'private' } @{$post->{tags}};
        $post->{visibility} = 'unlisted' if grep { $_ eq 'unlisted' } @{$post->{tags}};
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
