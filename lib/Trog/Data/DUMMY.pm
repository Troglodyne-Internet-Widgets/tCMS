package Trog::Data::DUMMY;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Carp qw{confess};
use JSON::MaybeXS;
use File::Slurper;
use File::Copy;
use Mojo::File;
use List::Util;

=head1 WARNING

Do not use this as a production data model.  It is *not* safe to race conditions, and is only here for testing.

=head1 QUERY FORMAT

The $query_language and $query_help variables are presented to the user as to how to use the search box in the tCMS header.

=cut

our $datastore      = 'data/DUMMY.json';
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

sub _read {
    confess "Can't find datastore!" unless -f $datastore;
    my $slurped = File::Slurper::read_text($datastore);
    return JSON::MaybeXS::decode_json($slurped);
}

sub _write($data) {
    open(my $fh, '>', $datastore) or confess;
    print $fh JSON::MaybeXS::encode_json($data);
    close $fh;
}

# These have to be sorted as requested by the client
sub get ($self, %request) {

    my $example_posts = _read();
    $request{acls} //= [];
    $request{tags} //=[];

    my @filtered = @$example_posts;

    # If an ID is passed, just get that (and all it's prior versions
    if ($request{id}) {
        @filtered = grep { $_->{id} eq $request{id} } @filtered if $request{id};

        @filtered = _dedup_versions($request{version}, @filtered);
        @filtered = _add_post_type(@filtered);
        # Next, add the type of post this is
        @filtered = _add_media_type(@filtered);
        # Finally, add visibility
        @filtered = _add_visibility(@filtered);
        return (1, \@filtered);
    }

    @filtered = _dedup_versions(undef, @filtered);

    # Next, handle the query, tags and ACLs
    @filtered = grep { my $tags = $_->{tags}; grep { my $t = $_; grep {$t eq $_ } @{$request{tags}} } @$tags } @filtered if @{$request{tags}};
    @filtered = grep { my $tags = $_->{tags}; grep { my $t = $_; grep {$t eq $_ } @{$request{acls}} } @$tags } @filtered unless grep { $_ eq 'admin' } @{$request{acls}};    
    @filtered = grep { $_->{data} =~ m/\Q$request{like}\E/i } @filtered if $request{like};

    # Finally, paginate
    my $offset = int($request{limit} // 25);
    $offset = @filtered < $offset ? @filtered : $offset;
    my $pages = int(scalar(@filtered) / ($offset || 1) );

    @filtered = splice(@filtered, ( int($request{page}) -1) * $offset, $offset) if $request{page} && $request{limit};
    
    # Next, go ahead and build the "post type"
    @filtered = _add_post_type(@filtered);
    # Next, add the type of post this is
    @filtered = _add_media_type(@filtered);
    # Finally, add visibility
    @filtered = _add_visibility(@filtered);

    return ($pages,\@filtered);
}

sub _dedup_versions ($version=-1, @posts) {
    if (defined $version) {
        my $version_max = List::Util::max(map { $_->{version } } @posts);
        return map {
            $_->{version_max} = $version_max;
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

sub total_posts {
    my $example_posts = _read();
    return scalar(@$example_posts);
}

sub _add_post_type (@posts) {
    return map {
        my $post = $_;
        my $type = 'file';
        $type = 'blog'      if grep { $_ eq 'blog' }    @{$post->{tags}};
        $type = 'microblog' if grep { $_ eq 'news' }    @{$post->{tags}};
        $type = 'profile'   if grep { $_ eq 'about' } @{$post->{tags}};
        $type = 'series'    if grep { $_ eq 'series'  } @{$post->{tags}};
        $post->{type} = $type;
        $post
    } @posts;
}

sub _add_media_type (@posts) {
    return map {
        my $post = $_;
        $post->{content_type} //= '';
        $post->{is_video} = 1 if $post->{content_type} =~ m/^video\//;
        $post->{is_audio} = 1 if $post->{content_type} =~ m/^audio\//;
        $post->{is_image} = 1 if $post->{content_type} =~ m/^image\//;
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

sub add ($self, @posts) {
    require UUID::Tiny;
    my $example_posts = _read();
    foreach my $post (@posts) {
        $post->{id} //= UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V1, UUID::Tiny::UUID_NS_DNS);
        my (undef, $existing_posts) = $self->get( id => $post->{id} );
        if (@$existing_posts) {
            my $existing_post = $existing_posts->[0];
            $post->{version}  = $existing_post->{version};
            $post->{version}++;
        }
        $post->{version} //= 0;

        $post = _process($post);
        push @$example_posts, $post;
    }
    _write($example_posts);
    return 0;
}

# Not actually a subprocess, kek
sub _process ($post) {

    $post->{href}    = _handle_upload($post->{file}, $post->{id})         if $post->{file};
    $post->{preview} = _handle_upload($post->{preview_file}, $post->{id}) if $post->{preview_file};
    $post->{preview} = $post->{href} if $post->{app} eq 'image';
    delete $post->{app};
    delete $post->{file};
    delete $post->{preview_file};

    delete $post->{route};
    delete $post->{domain};

    # Handle acls/tags
    $post->{tags} //= [];
    @{$post->{tags}} = grep { my $subj = $_; !grep { $_ eq $subj} qw{public private unlisted} } @{$post->{tags}};
    push(@{$post->{tags}}, delete $post->{acls}) if $post->{visibility} eq 'private';
    push(@{$post->{tags}}, delete $post->{visibility});

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

sub delete($self, @posts) {
    my $example_posts = _read();
    foreach my $update (@posts) {
        @$example_posts = grep { $_->{id} ne $update->{id} } @$example_posts;
    }
    _write($example_posts);
    return 0;
}

1;
