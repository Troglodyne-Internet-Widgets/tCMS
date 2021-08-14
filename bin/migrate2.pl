use strict;
use warnings;

# Migrate early on tcms3 flatfile sites to 'all posts are series code' (august 2021) code

use lib '../lib';

use Trog::Config;
use Trog::Data;
use List::Util;
use UUID::Tiny;

use Trog::SQLite;
use Trog::SQLite::TagIndex;

sub uuid { return UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V1, UUID::Tiny::UUID_NS_DNS); }

# Modify these variables to suit your installation.
my $user = 'george';
my @extra_series = (
     {
            "aclname"    => "blog",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "Blog",
            "href"       => "/blog",
            "local_href" => "/blog",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar public}],
            visibility   => 'public',
            "title"      => "Blog",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'blog.tx',
        },
        {
            "aclname"    => "video",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "Videos",
            "href"       => "/video",
            "local_href" => "/video",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar public}],
            visibility   => 'public',
            "title"      => "Videos",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'file.tx',
        },
        {
            "aclname"    => "files",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "Downloads",
            "href"       => "/files",
            "local_href" => "/files",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar public}],
            visibility   => 'public',
            "title"      => "Downloads",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'file.tx',
        },
);

my $conf = Trog::Config::get();
my $search_info = Trog::Data->new($conf);

# Kill the post index
unlink "../data/posts.db";

my @all = $search_info->get( raw => 1, limit => 0 );

my %posts;
foreach my $post (@all) {
    $posts{$post->{id}} //= [];
    # Re-do the IDs
    push(@{$posts{$post->{id}}},$post);
}

foreach my $timestamp (keys(%posts)) {
    my $file_to_kill = "../data/files/$timestamp";
    my $new_id = uuid();
    # Preserve old URLs
    foreach my $post (@{$posts{$timestamp}}) {
        $post->{id}         = $new_id;
        $post->{local_href} = "/posts/$timestamp";
        $post->{callback}   = "Trog::Routes::HTML::series";
        $post->{method}     = 'GET';
        @{$post->{tags}} = grep { defined $_ } @{$post->{tags}};

        $post->{content_type} //= 'text/html';
        $post->{form}       = 'microblog.tx';
        $post->{form}       = 'blog.tx' if grep {$_ eq 'blog' } @{$post->{tags}};
        $post->{form}       = 'file.tx' if $post->{content_type} =~ m/^video\//;
        $post->{form}       = 'file.tx' if $post->{content_type} =~ m/^audio\//;
        $post->{form}       = 'file.tx' if $post->{content_type} =~ m/^image\//;
        $post->{form}       = 'profile.tx' if grep {$_ eq 'about' } @{$post->{tags}};
        $search_info->write([$post]);
        unlink $file_to_kill if -f $file_to_kill;
    }
}

# Rebuild the index
Trog::SQLite::TagIndex::build_index($search_info);
Trog::SQLite::TagIndex::build_routes($search_info);

# Add in the series
my $series = [
        {
            "aclname"    => "series",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "Series",
            "href"       => "/series",
            "local_href" => "/series",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar}],
            visibility   => 'public',
            "title"      => "Series",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'series.tx',
        },
        {
            "aclname"    => "about",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "About",
            "href"       => "/about",
            "local_href" => "/about",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar public}],
            visibility   => 'public',
            "title"      => "About",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'profile.tx',
        },
        {
            "aclname"      => "admin",
            acls           => [],
            "callback"     => "Trog::Routes::HTML::config",
            'method'       => 'GET',
            "content_type" => "text/plain",
            "data"         => "Config",
            "href"         => "/config",
            "local_href"   => "/config",
            "preview"      => "/img/sys/testpattern.jpg",
            "tags"         => [qw{admin}],
            visibility     => 'private',
            "title"        => "Configure tCMS",
            user           => $user,
        },
];

$search_info->add(@$series,@extra_series);
