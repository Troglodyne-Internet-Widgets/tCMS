package Trog::DataModule;

use strict;
use warnings;

use UUID::Tiny;
use List::Util;
use File::Copy;
use Mojo::File;

no warnings 'experimental';
use feature qw{signatures};

=head1 QUERY FORMAT

The $query_language and $query_help variables are presented to the user as to how to use the search box in the tCMS header.

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

=head1 CONSTRUCTOR

=head2 new(Config::Simple $config)

Try not to do expensive things here.

=cut

sub new ($class, $config) {
    $config = $config->vars();
    return bless($config, $class);
}

#It is required that subclasses implement this
sub lang  ($self) { ... }
sub help  ($self) { ... }
sub read  ($self,$query={}) { ... }
sub write ($self) { ... }
sub count ($self) { ... }

=head1 METHODS

=head2 get(%request)

Queries the data model.  Should return the following:

    id   => Filter down to just the post by ID.  May be subsequently filtered by ACL, resulting in a 404 (which is good, as it does not disclose info).

    version => if id is passed, return the provided post version rather than the most recent one

    tags => ARRAYREF of tags, any one of which is required to give a result.  If none are passed, no filtering is performed.

    acls => ARRAYREF of acl tags, any one of which is required to give result. Filter applies after tags.  'admin' ACL being present skips this filter.

    page => Offset multiplier for pagination.

    limit => Offset for pagination.

    like => Search query, as might be passed in the search bar.

    author => filter by post author

If it is more efficient to filter within your data storage engine, you probably should override this method.
As implemented, this takes the data as a given and filters in post.

=cut

sub get ($self, %request) {

    my $posts = $self->read(\%request);

    my @filtered = $self->filter(\%request, @$posts);
    @filtered = $self->_fixup(@filtered);
    @filtered = $self->paginate(\%request,@filtered);
    return @filtered;
}

sub _fixup ($self, @filtered) {
    @filtered = _add_post_type(@filtered);
    # Next, add the type of post this is
    @filtered = _add_media_type(@filtered);
    # Finally, add visibility
    @filtered = _add_visibility(@filtered);

    #urlencode spaces in filenames
    @filtered = map {
        foreach my $param (qw{href preview video_href audio_href local_href wallpaper}) {
            next unless exists $_->{$param};
            $_->{$param} =~ s/ /%20/g;
        }
        $_
    } @filtered;

    return @filtered;
}

sub filter ($self, $query, @filtered) {
    my %request = %$query; #XXX update varnames instead
    $request{acls} //= [];
    $request{tags} //=[];

    # If an ID is passed, just get that (and all it's prior versions)
    if ($request{id}) {
        @filtered = grep { $_->{id} eq $request{id} } @filtered   if $request{id};
        @filtered = _dedup_versions($request{version}, @filtered);
        return @filtered;
    }

    @filtered = _dedup_versions(undef, @filtered);

    #Filter out posts which are too old
    #Coerce older into numeric
    $request{older} =~ s/[^0-9]//g if $request{older};
    @filtered = grep { $_->{created} < $request{older} } @filtered if $request{older};

    #XXX Heal bad data -- probably not needed
    @filtered = map { my $t = $_->{tags}; @$t = grep { defined $_ } @$t; $_ } @filtered;

    # Next, handle the query, tags and ACLs
    @filtered = grep { my $tags = $_->{tags}; grep { my $t = $_; grep {$t eq $_ } @{$request{tags}} } @$tags } @filtered if @{$request{tags}};
    @filtered = grep { my $tags = $_->{tags}; grep { my $t = $_; grep {$t eq $_ } @{$request{acls}} } @$tags } @filtered unless grep { $_ eq 'admin' } @{$request{acls}};

    @filtered = grep { $_->{title} =~ m/\Q$request{like}\E/i || $_->{data} =~ m/\Q$request{like}\E/i } @filtered if $request{like};

    @filtered = grep { $_->{user} eq $request{author} } @filtered if $request{author};
    return @filtered;
}

sub paginate ($self, $query, @filtered) {
    my %request = %$query; #XXX change varnames
    my $offset = int($request{limit} // 25);
    $offset = @filtered < $offset ? @filtered : $offset;
    @filtered = splice(@filtered, ( int($request{page}) -1) * $offset, $offset) if $request{page} && $request{limit};
    return @filtered;
}

sub _dedup_versions ($version=-1, @posts) {

    #ASSUMPTION made here - if we pass version this is direct ID query
    if (defined $version) {
        my $version_max = List::Util::max(map { $_->{version} } @posts);

        return map {
            $_->{version_max} //= $version_max;
            $_
        } grep { $_->{version} eq $version } @posts;
    }

    my @uniqids = List::Util::uniq(map { $_->{id} } @posts);
    my %posts_deduped;
    for my $id (@uniqids) {
        my @ofid = sort { $b->{version} cmp $a->{version} } grep { $_->{id} eq $id } @posts;
        my $version_max = List::Util::max(map { $_->{version } } @ofid);
        $posts_deduped{$id} = $ofid[0];
        $posts_deduped{$id}{version_max} = $version_max;
    }
    my @deduped = @posts_deduped{@uniqids};

    return @deduped;
}

#XXX this probably should be re-factored to be baked into the data from the get-go
sub _add_post_type (@posts) {
    return map {
        my $post = $_;
        my $type = 'file';
        $type = 'blog'      if grep { $_ eq 'blog'   } @{$post->{tags}};
        $type = 'microblog' if grep { $_ eq 'news'   } @{$post->{tags}};
        $type = 'profile'   if grep { $_ eq 'about'  } @{$post->{tags}};
        $type = 'series'    if grep { $_ eq 'series' } @{$post->{tags}};
        $post->{type} = $type;
        $post
    } @posts;
}

sub _add_media_type (@posts) {
    return map {
        my $post = $_;
        $post->{content_type} //= '';
        $post->{is_video}   = 1 if $post->{content_type} =~ m/^video\//;
        $post->{is_audio}   = 1 if $post->{content_type} =~ m/^audio\//;
        $post->{is_image}   = 1 if $post->{content_type} =~ m/^image\//;
        $post->{is_profile} = 1 if grep {$_ eq 'about' } @{$post->{tags}};
        $post
    } @posts;
}

sub _add_visibility (@posts) {
    return map {
        my $post = $_;
        my @visibilities = grep { my $tag = $_; grep { $_ eq $tag } qw{private unlisted public} } @{$post->{tags}};
        $post->{visibility} = $visibilities[0];
        $post
    } @posts;
}

=head2 count() = INT $num

Returns the total number of posts.
Used to determine paginator parameters.

=cut

=head2 add(@posts) = BOOL $failed_or_not

Add the provided posts to the datastore.
If any post already exists with the same id, a new post with a version higher than it will be added.

Passes an array of new posts to add to the data store module's write() function.

You probably won't want to override this.

=cut

sub add ($self, @posts) {
    my @to_write;
    foreach my $post (@posts) {
        $post->{id} //= UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V1, UUID::Tiny::UUID_NS_DNS);
        $post->{created} = time();
        my @existing_posts = $self->get( id => $post->{id} );
        if (@existing_posts) {
            my $existing_post = $existing_posts[0];
            $post->{version}  = $existing_post->{version};
            $post->{version}++;
        }
        $post->{version} //= 0;

        $post = _process($post);
        push @to_write, $post;
    }
    $self->write(\@to_write);
    return 0;
}

#XXX this level of post-processing seems gross, but may be unavoidable
# Not actually a subprocess, kek
sub _process ($post) {

    $post->{href}      = _handle_upload($post->{file}, $post->{id})         if $post->{file};
    $post->{preview}   = _handle_upload($post->{preview_file}, $post->{id}) if $post->{preview_file};
    $post->{wallpaper} = _handle_upload($post->{wallpaper_file}, $post->{id})    if $post->{wallpaper_file};
    $post->{preview} = $post->{href} if $post->{app} eq 'image';
    delete $post->{app};
    delete $post->{file};
    delete $post->{preview_file};

    delete $post->{scheme};
    delete $post->{route};
    delete $post->{domain};

    # Handle acls/tags
    $post->{tags} //= [];
    @{$post->{tags}} = grep { my $subj = $_; !grep { $_ eq $subj} qw{public private unlisted} } @{$post->{tags}};
    push(@{$post->{tags}}, delete $post->{acls}) if $post->{visibility} eq 'private';
    push(@{$post->{tags}}, delete $post->{visibility});

    # Add the 'series' tag if we are in a series, restrict to relevant acl
    if ($post->{series}) {
        push(@{$post->{tags}}, 'series');
        push(@{$post->{tags}}, $post->{series});
    }

    #Filter adding the same acl twice
    @{$post->{tags}} = List::Util::uniq(@{$post->{tags}});

    # Handle multimedia content types
    if ($post->{href}) {
        my $mf = Mojo::File->new("www/$post->{href}");
        my $ext = '.'.$mf->extname();
        $post->{content_type} = Plack::MIME->mime_type($ext) if $ext;
    }
    if ($post->{video_href}) {
        my $mf = Mojo::File->new("www/$post->{video_href}");
        my $ext = '.'.$mf->extname();
        $post->{video_content_type} = Plack::MIME->mime_type($ext) if $ext;
    }
    if ($post->{audio_href}) {
        my $mf = Mojo::File->new("www/$post->{audio_href}");
        my $ext = '.'.$mf->extname();
        $post->{audio_content_type} = Plack::MIME->mime_type($ext) if $ext;
    }

    return $post;
}

sub _handle_upload ($file, $uuid) {
    my $f = $file->{tempname};
    my $newname = "$uuid.$file->{filename}";
    File::Copy::move($f, "www/assets/$newname");
    return "/assets/$newname";
}

=head2 delete(@posts)

Delete the following posts.
Will remove all versions of said post.

You should override this, it is a stub here.

=cut

sub delete ($self) { die 'stub' }

1;
