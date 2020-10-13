package Trog::Data::DUMMY;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

=head1 QUERY FORMAT

The $query_language and $query_help variables are presented to the user as to how to use the search box in the tCMS header.

=cut

our $query_language = 'Perl Regex in Quotemeta';
our $query_help     = 'https://perldoc.perl.org/functions/quotemeta.html';

=head1 POST STRUCTURE

Posts generally need to have the following:

    data: Brief description of content, or the content itself.
    content_type: What this content actually is.  Used to filter into the appropriate pages.
    href: Primary link.  This is the subject of a news post, or a link to the item itself.  Can be local or remote.
    local_href: Backup link.  Automatically created link to a static cache of the content.
    title: Title of the content.  Used as link name for the 'href' attribute.
    user: User was banned for this post
    id: Internal identifier in datastore for the post.
    tags: array ref of appropriate tags.
    created: timestamp of creation of this version of the post
    version: revision # of this post.

=cut

my $example_posts = [
    {
        content_type => "text/html",
        data         => "Here, caveman",
        href         => '/',
        local_href   => "/assets/today.html",
        title        => 'Example Post',
        user         => 'Nobody',
        id           => 665,
        tags         => ['news', 'public'],
        created      => time(),
        version      => 0,
    },
    {
        content_type => "text/html",
        data         => "Is amazing",
        href         => '/',
        local_href   => "/assets/blog/Muh Blog.html",
        title        => 'Muh Blog',
        user         => 'Nobody',
        id           => 666,
        tags         => ['blog', 'public'],
        created      => time(),
        version      => 0,
    },
    {
        content_type => "text/html",
        data         => "Vote for Nobody, nobody really cares!",
        href         => '/',
        local_href   => "/assets/about/Nobody.html",
        title        => 'Nobody',
        user         => 'Nobody',
        id           => 669,
        tags         => ['about', 'profile', 'public'],
        created      => time(),
        version      => 0,
    },
    { 
        content_type => "image/gif",
        data         => "Default avatar for new users",
        href         => "/img/avatar/humm.gif",
        local_href   => "/img/avatar/humm.gif",
        title        => "humm.gif",
        user         => 'Nobody',
        id           => 420,
        tags         => ['image', 'files', 'profile-image', 'public'],
        created      => time(),
        version      => 0,
        preview      => '/img/avatar/humm.gif',
    },
    { 
        content_type => "image/jpeg",
        data         => "Test Pattern",
        href         => "/img/sys/testpattern.jpg",
        local_href   => "/img/sys/testpattern.jpg",
        title        => "testpattern.jpg",
        user         => 'Nobody',
        id           => 90210,
        tags         => ['image', 'files', 'public'],
        created      => time(),
        version      => 0,
        preview      => '/img/sys/testpattern.jpg',
    },
    {
        content_type => "audio/mpeg",
        data         => "Test recording for tCMS",
        href         => "/assets/audio/test.mp3",
        local_href   => "/assets/audio/test.mp3",
        title        => "test.mp3",
        user         => "Nobody",
        id           => 111,
        tags         => ["audio", "files", 'public'],
        created      => time(),
        version      => 0,
        preview      => '/img/sys/testpattern.jpg',
    },
    {
        content_type => "video/ogg",
        data         => "Test video for tCMS",
        href         => "/assets/video/test.ogv",
        local_href   => "/assets/video/test.ogv",
        title        => "test.ogv",
        user         => "Nobody",
        id           => "222",
        tags         => ["video", "files", 'public'],
        created      => time(),
        version      => 0,
        preview      => '/img/sys/testpattern.jpg',
    },
    {
        content_type => 'text/plain',
        data         => "Admin ACL",
        href         => "/config",
        local_href   => '/config',
        title        => 'admin',
        user         => 'Nobody',
        id           => "900",
        tags         => ['series'],
        created      => time(),
        version      => 0,
        preview      => '/img/sys/testpattern.jpg',
    },
    { 
        content_type => "image/svg",
        data         => "tCMS Logo",
        href         => "/img/icon/tCMS.svg",
        local_href   => "/img/icon/tCMS.svg",
        title        => "tCMS.svg",
        user         => 'Nobody',
        id           => 90211,
        tags         => ['image', 'files', 'admin'],
        created      => time(),
        version      => 0,
        preview      => '/img/icon/tCMS.svg',
    },
];

=head1 CONSTRUCTOR

=head2 new(Config::Simple $config)

Try not to do expensive things here.  

=cut

sub new ($class, $config) {
    $config = $config->vars();
    $config->{lang} = $query_language;
    $config->{help} = $query_help;
    return bless($config,__PACKAGE__);
}

=head1 METHODS

=head2 get(%request)

Queries the data model in the way a "real" data model module ought to.

    id   => Filter down to just the post by ID.  May be subsequently filtered by ACL, resulting in a 404 (which is good, as it does not disclose info).

    tags => ARRAYREF of tags, any one of which is required to give a result.  If none are passed, no filtering is performed.

    acls => ARRAYREF of acl tags, any one of which is required to give result. Filter applies after tags.  'admin' ACL being present skips this filter.

    page => Offset multiplier for pagination.

    limit => Offset for pagination.

    like => Search query, as might be passed in the search bar.

=cut

# These have to be sorted as requested by the client
sub get ($self, %request) {
    my @filtered = @$example_posts;

    # If an ID is passed, just get that
    @filtered = grep { $_->{id} eq $request{id} } @filtered if $request{id};

    # First, paginate
    my $offset = int($request{limit});
    $offset = @filtered < $offset ? @filtered : $offset;
    @filtered = splice(@filtered, ( int($request{page}) -1) * $offset, $offset) if $request{page} && $request{limit}; 

    # Next, handle the query, tags and ACLs
    @filtered = grep { my $tags = $_->{tags}; grep { my $t = $_; grep {$t eq $_ } @{$request{tags}} } @$tags } @filtered if @{$request{tags}};
    @filtered = grep { my $tags = $_->{tags}; grep { my $t = $_; grep {$t eq $_ } @{$request{acls}} } @$tags } @filtered unless grep { $_ eq 'admin' } @{$request{acls}};    
    @filtered = grep { $_->{data} =~ m/\Q$request{like}\E/i } @filtered if $request{like};

    # Next, go ahead and build the "post type"
    @filtered = _add_post_type(@filtered);
    # Next, add the type of post this is
    @filtered = _add_media_type(@filtered);

    return \@filtered;
}

sub total_posts {
    return scalar(@$example_posts);
}

sub _add_post_type (@posts) {
    return map {
        my $post = $_;
        my $type = 'file';
        $type = 'blog'      if grep { $_ eq 'blog' }    @{$post->{tags}};
        $type = 'microblog' if grep { $_ eq 'news' }    @{$post->{tags}};
        $type = 'profile'   if grep { $_ eq 'profile' } @{$post->{tags}};
        $post->{type} = $type;
        $post
    } @posts;
}

sub _add_media_type (@posts) {
    return map {
        my $post = $_;
        $post->{is_video} = 1 if $post->{content_type} =~ m/^video\//;
        $post->{is_audio} = 1 if $post->{content_type} =~ m/^audio\//;
        $post->{is_image} = 1 if $post->{content_type} =~ m/^image\//;
        $post
    } @posts;
}

sub add ($self, @posts) {
    return 1;
}

sub update($self, @posts) {
    return 1;
}

sub delete($self, @ids) {
    return 1;
}

1;
