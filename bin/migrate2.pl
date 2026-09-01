#!/usr/bin/env perl

use v5.36;
use re '/aa';

# Migrate early on tcms3 flatfile sites to 'all posts are series code' (august 2021) code

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::Config;
use Trog::Data;
use List::Util;
use UUID::Tiny;

use Trog::SQLite;
use Trog::SQLite::TagIndex;

=head1 SYNOPSIS

Migrate early tCMS3 flatfile sites to the 'all posts are series' code (August
2021).

Re-keys every post from a timestamp onto a UUID, keeping the old URL as an
alias so nothing already linked breaks, and fills in the fields that release
started requiring: local_href, callback, method, visibility and the form each
post is edited with.  Then it rebuilds the index and adds the series posts
(/series, /about, /config) that the new code expects to exist.

=head2 USAGE

Edit $user and @extra_series below to suit your installation, then:

    bin/migrate2.pl

Run from the tCMS root.

=head2 CAVEATS

Historical, and one way.  It deletes the timestamp keyed flat files as it
rewrites them, so take a backup of data/ before running it.

Also unlinks data/posts.db up front, as the index is rebuilt at the end
regardless.

The form a post gets is guessed from its tags and content type, and series
child_form from the series title, so anything unusual will want checking
afterwards.

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

my %posts;
foreach my $post (@all) {
    $posts{ $post->{id} } //= [];

    # Re-do the IDs
    push( @{ $posts{ $post->{id} } }, $post );
}

foreach my $timestamp ( keys(%posts) ) {
    my $file_to_kill = "$FindBin::Bin/../data/files/$timestamp";
    my $new_id       = uuid();

    # Preserve old URLs
    foreach my $post ( @{ $posts{$timestamp} } ) {
        delete $post->{app};
        delete $post->{preview_file};
        delete $post->{wallpaper_file};

        delete $post->{scheme};
        delete $post->{route};
        delete $post->{domain};

        $post->{id}         = $new_id;
        $post->{local_href} = "/posts/$new_id";
        $post->{aliases}    = ["/posts/$timestamp"];
        $post->{callback}   = "Trog::Routes::HTML::posts";
        $post->{method}     = 'GET';
        @{ $post->{tags} } = grep { defined $_ } @{ $post->{tags} };

        $post->{content_type} //= 'text/html';
        $post->{form} = 'microblog.tx';
        $post->{form} = 'blog.tx' if grep { $_ eq 'blog' } @{ $post->{tags} };
        $post->{form} = 'file.tx' if $post->{content_type} =~ m/^video\//;
        $post->{form} = 'file.tx' if $post->{content_type} =~ m/^audio\//;
        $post->{form} = 'file.tx' if $post->{content_type} =~ m/^image\//;
        if ( grep { $_ eq 'about' } @{ $post->{tags} } ) {
            $post->{form}       = 'profile.tx';
            $post->{local_href} = "/users/$post->{user}";
            $post->{callback}   = "Trog::Routes::HTML::users";
        }
        if ( grep { $_ eq 'series' } @{ $post->{tags} } ) {
            $post->{form}       = 'series.tx';
            $post->{callback}   = "Trog::Routes::HTML::series";
            $post->{child_form} = 'microblog.tx';
            $post->{child_form} = 'blog.tx' if $post->{title} =~ m/^blog/i;
            $post->{child_form} = 'file.tx' if $post->{title} =~ m/^video\//;
            $post->{child_form} = 'file.tx' if $post->{title} =~ m/^audio\//;
            $post->{child_form} = 'file.tx' if $post->{title} =~ m/^image\//;
            $post->{local_href} = "/$post->{aclname}";
            $post->{aliases}    = [ "/series/$timestamp", "/series/$new_id" ];
        }

        $search_info->write( [$post] );
        unlink $file_to_kill;
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
        aliases      => [],
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
        aliases      => [],
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
        aliases        => [],
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

$search_info->add( @$series, @extra_series );
