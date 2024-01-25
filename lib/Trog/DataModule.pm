package Trog::DataModule;

use strict;
use warnings;

use FindBin::libs;

use List::Util;
use File::Copy;
use Mojo::File;
use Plack::MIME;
use Path::Tiny();
use Ref::Util();

use Trog::Log qw{:all};
use Trog::Utils;
use Trog::Auth();

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

sub new ( $class, $config ) {
    $config = $config->vars();
    return bless( $config, $class );
}

#It is required that subclasses implement this
sub lang ($self)                { ... }
sub help ($self)                { ... }
sub read ( $self, $query = {} ) { ... }
sub write ($self)               { ... }
sub count ($self)               { ... }
sub tags ($self)                { ... }

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

sub get ( $self, %request ) {

    my $posts = $self->read( \%request );
    return @$posts if $request{raw};

    my @filtered = $self->filter( \%request, @$posts );
    @filtered = $self->_fixup(@filtered);
    @filtered = $self->paginate( \%request, @filtered );
    return @filtered;
}

sub _fixup ( $self, @filtered ) {

    my %user2display;

    # urlencode spaces in filenames
    @filtered = map {
        my $subj = $_;
        foreach my $param (qw{href preview video_href audio_href local_href wallpaper}) {
            next unless exists $subj->{$param};

            #XXX I don't remember what this fixes, but it also breaks things.  URI::Escape usage instead is indicated.
            $subj->{$param} =~ s/ /%20/g;
        }

        $user2display{ $subj->{user} } //= Trog::Auth::username2display( $subj->{user} );
        $subj->{display_name} = $user2display{ $subj->{user} };

        #XXX Add dynamic routing data for posts which don't have them (/posts/$id) and (/users/$user)
        my $is_user_page = List::Util::any { $_ eq 'about' } @{ $subj->{tags} };
        if ( !exists $subj->{local_href} ) {
            $subj->{local_href} = "/posts/$subj->{id}";

            #XXX this needs to be correctly populated in the form?
            if ($is_user_page) {
                my $display_name = $user2display{ $subj->{user} };
                die "No display name for user!" unless $display_name;
                $subj->{local_href} = "/users/$display_name";
            }
        }
        if ( !exists $subj->{callback} ) {
            $subj->{callback} = "Trog::Routes::HTML::posts";
            $subj->{callback} = "Trog::Routes::HTML::users" if $is_user_page;
        }

        $subj->{method} = 'GET' unless exists( $subj->{method} );

        $subj->{user_class} = Trog::Auth::username2classname($subj->{user});
        $subj
    } @filtered;

    return @filtered;
}

sub filter ( $self, $query, @filtered ) {
    $query->{acls}         //= [];
    $query->{tags}         //= [];
    $query->{exclude_tags} //= [];

    # If an ID is passed, just get that (and all it's prior versions)
    if ( $query->{id} ) {
        @filtered = grep { $_->{id} eq $query->{id} } @filtered;
        @filtered = _dedup_versions( $query->{version}, @filtered );
        return @filtered;
    }

    # XXX aclname and id are essentially serving the same purpose, should unify
    if ( $query->{aclname} ) {
        @filtered = grep { ( $_->{aclname} || '' ) eq $query->{aclname} } @filtered;
        @filtered = _dedup_versions( $query->{version}, @filtered );
        return @filtered;
    }

    @filtered = _dedup_versions( undef, @filtered );

    #Filter out posts which are too old
    #Coerce older into numeric
    if ( $query->{older} ) {
        $query->{older} =~ s/[^0-9]//g;
        @filtered = grep { $_->{created} < $query->{older} } @filtered;
    }
    if ( $query->{newer} ) {
        $query->{newer} =~ s/[^0-9]//g;
        @filtered = grep { $_->{created} > $query->{newer} } @filtered;
    }

    # Filter posts not matching the passed tag(s), if any
    @filtered = grep {
        my $tags = $_->{tags};
        grep {
            my $t = $_;
            grep { $t eq $_ } @{ $query->{tags} }
          } @$tags
    } @filtered if @{ $query->{tags} };

    # Filter posts *matching* the passed exclude_tag(s), if any
    @filtered = grep {
        my $tags = $_->{tags};
        !grep {
            my $t = $_;
            grep { $t eq $_ } @{ $query->{exclude_tags} }
          } @$tags
    } @filtered if @{ $query->{exclude_tags} };

    # Filter posts without the proper ACLs
    @filtered = grep {
        my $tags = $_->{tags};
        grep {
            my $t = $_;
            grep { $t eq $_ } @{ $query->{acls} }
          } @$tags
    } @filtered unless grep { $_ eq 'admin' } @{ $query->{acls} };

    @filtered = grep { $_->{title} =~ m/\Q$query->{like}\E/i || $_->{data} =~ m/\Q$query->{like}\E/i } @filtered if $query->{like};

    @filtered = grep { $_->{user} eq $query->{author} } @filtered if $query->{author};

    return @filtered;
}

sub paginate ( $self, $query, @filtered ) {
    my $offset = int( $query->{limit} // 25 );
    $offset   = @filtered < $offset ? @filtered : $offset;
    @filtered = splice( @filtered, ( int( $query->{page} ) - 1 ) * $offset, $offset ) if $query->{page} && $query->{limit};
    return @filtered;
}

sub _dedup_versions ( $version = -1, @posts ) {

    #ASSUMPTION made here - if we pass version this is direct ID query
    if ( defined $version ) {
        my $version_max = List::Util::max( map { $_->{version} } @posts );

        return map {
            $_->{version_max} //= $version_max;
            $_
        } grep { $_->{version} eq $version } @posts;
    }

    my @uniqids = List::Util::uniq( map { $_->{id} } @posts );
    my %posts_deduped;
    for my $id (@uniqids) {
        my @ofid        = sort { $b->{version} <=> $a->{version} } grep { $_->{id} eq $id } @posts;
        my $version_max = List::Util::max( map { $_->{version} } @ofid );
        $posts_deduped{$id} = $ofid[0];
        $posts_deduped{$id}{version_max} = $version_max;

        # Show orig creation date, and original author.
        # XXX this doesn't show the mtime correctly for whatever reason, so I'm omitting it from the interface
        $posts_deduped{$id}{modified} = $ofid[0]{created};
        $posts_deduped{$id}{created}  = $ofid[-1]{created};
        $posts_deduped{$id}{author}   = $ofid[-1]{author};
    }
    my @deduped = @posts_deduped{@uniqids};

    return @deduped;
}

=head2 count() = INT $num

Returns the total number of posts.
Used to determine paginator parameters.

=cut

=head2 add(@posts) = BOOL $failed_or_not

Add the provided posts to the datastore.
If any post already exists with the same id, a new post with a version higher than it will be added.

Passes an array of new posts to add to the data store module's write() function.

These will have their parameters filtered to those present in the %schema hash.

You probably won't want to override this.

=cut

my $not_ref = sub {
    return !Ref::Util::is_ref(shift);
};

my $valid_cb = sub {
    my $subname = shift;
    my ($modname) = $subname =~ m/^([\w|:]+)::\w+$/;
    eval { require $modname; } or do {
        WARN("Post uses a callback whos module cannot be found!");
        return 0;
    };

    no strict 'refs';
    my $ref = eval '\&' . $subname;
    use strict;
    return is_coderef($ref);
};

my $hashref_or_string = sub {
    my $subj = shift;
    return Ref::Util::is_hashref($subj) || $not_ref->($subj);
};

# TODO more strict validation of strings?
our %schema = (
    ## Parameters which must be in every single post
    'title'      => $not_ref,
    'callback'   => $valid_cb,
    'tags'       => \&Ref::Util::is_arrayref,
    'version'    => $not_ref,
    'visibility' => $not_ref,
    'aliases'    => \&Ref::Util::is_arrayref,
    'tiled'      => $not_ref,

    # title links here
    'href' => $not_ref,

    # Link to post locally
    'local_href' => $not_ref,

    # Post body
    'data' => $not_ref,

    # How do I edit this post?
    'form' => $not_ref,

    # Post is restricted to visibility to these ACLs if not public/unlisted
    'acls' => \&Ref::Util::is_arrayref,
    'id'   => $not_ref,

    # Author of the post
    'user'    => $not_ref,
    'created' => $not_ref,
    ## Series specific parameters
    'child_form' => $not_ref,
    'aclname'    => $not_ref,
    ## User specific parameters
    'user_acls'      => \&Ref::Util::is_arrayref,
    'username'       => $not_ref,
    'display_name'   => $not_ref,
    'contact_email'  => $not_ref,
    'wallpaper_file' => $hashref_or_string,
    'wallpaper'      => $not_ref,

    # user avatar, but does double duty in content posts as preview images on videos, etc
    'preview_file' => $hashref_or_string,
    'preview'      => $not_ref,
    ## Content specific parameters
    'audio_href' => $not_ref,
    'video_href' => $not_ref,
    'file'       => $hashref_or_string,
);

sub add ( $self, @posts ) {
    my @to_write;

    foreach my $post (@posts) {

        # Filter all the irrelevant data
        foreach my $key ( keys(%$post) ) {

            # We need to have the key in the schema, and it validate.
            delete $post->{$key} unless List::Util::any { ( $_ eq $key ) && ( $schema{$key}->( $post->{$key} ) ) } keys(%schema);
        }

        $post->{id}      //= Trog::Utils::uuid();
        $post->{aliases} //= [];
        $post->{aliases} = [ $post->{aliases} ] unless ref $post->{aliases} eq 'ARRAY';

        if ( $post->{aclname} ) {

            # Then this is a series
            $post->{local_href} //= "/$post->{aclname}";
            push( @{ $post->{aliases} }, "/posts/$post->{id}", "/series/$post->{id}" );
        }

        $post->{callback} //= 'Trog::Routes::HTML::posts';

        # If this is a user creation post, add in the /user/ route
        if ( $post->{callback} eq 'Trog::Routes::HTML::users' ) {
            $post->{local_href} //= "/users/$post->{display_name}";
            $post->{title}      //= $post->{display_name};
        }

        $post->{local_href} //= "/posts/$post->{id}";
        $post->{method}     //= 'GET';
        $post->{created} = time();
        my @existing_posts = $self->get( id => $post->{id} );
        if (@existing_posts) {
            my $existing_post = $existing_posts[0];
            $post->{version} = $existing_post->{version};
            $post->{version}++;
        }
        $post->{version} //= 0;

        $post = _process($post);

        push @to_write, $post;
    }
    $self->write( \@to_write );

    #hup the parent to refresh the routing table
    Trog::Utils::restart_parent();

    # Gorilla cache invalidation
    Path::Tiny::path('www/statics')->remove_tree;

    return 0;
}

#XXX this level of post-processing seems gross, but may be unavoidable
# Not actually a subprocess, kek
sub _process ($post) {

    $post->{href}      = _handle_upload( $post->{file},           $post->{id} ) if $post->{file};
    $post->{preview}   = _handle_upload( $post->{preview_file},   $post->{id} ) if $post->{preview_file};
    $post->{wallpaper} = _handle_upload( $post->{wallpaper_file}, $post->{id} ) if $post->{wallpaper_file};
    $post->{preview} = $post->{href} if $post->{app} && $post->{app} eq 'image';
    delete $post->{app};
    delete $post->{file};
    delete $post->{preview_file};
    delete $post->{wallpaper_file};

    delete $post->{scheme};
    delete $post->{route};
    delete $post->{domain};

    # Handle acls/tags
    $post->{tags} //= [];
    $post->{acls} //= [];
    @{ $post->{tags} } = grep {
        my $subj = $_;
        !grep { $_ eq $subj } qw{public private unlisted}
    } @{ $post->{tags} };
    push( @{ $post->{tags} }, @{ $post->{acls} } ) if $post->{visibility} eq 'private';
    delete $post->{acls};
    push( @{ $post->{tags} }, $post->{visibility} );

    # Add the 'series' tag if we are in a series, restrict to relevant acl
    if ( $post->{series} ) {
        push( @{ $post->{tags} }, 'series' );
        push( @{ $post->{tags} }, $post->{series} );
    }

    #Filter adding the same acl twice
    @{ $post->{tags} }    = List::Util::uniq( @{ $post->{tags} } );
    @{ $post->{aliases} } = List::Util::uniq( @{ $post->{aliases} } );

    # Handle multimedia content types
    if ( $post->{href} ) {
        my $mf  = Mojo::File->new("www/$post->{href}");
        my $ext = '.' . $mf->extname();
        $post->{content_type} = Plack::MIME->mime_type($ext) if $ext;
    }
    if ( $post->{video_href} ) {
        my $mf  = Mojo::File->new("www/$post->{video_href}");
        my $ext = '.' . $mf->extname();
        $post->{video_content_type} = Plack::MIME->mime_type($ext) if $ext;
    }
    if ( $post->{audio_href} ) {
        my $mf  = Mojo::File->new("www/$post->{audio_href}");
        my $ext = '.' . $mf->extname();
        $post->{audio_content_type} = Plack::MIME->mime_type($ext) if $ext;
    }
    $post->{content_type} ||= 'text/html';

    $post->{is_video} = 1 if $post->{content_type} =~ m/^video\//;
    $post->{is_audio} = 1 if $post->{content_type} =~ m/^audio\//;
    $post->{is_image} = 1 if $post->{content_type} =~ m/^image\//;
    $post->{is_profile} = 1 if grep { $_ eq 'about' } @{ $post->{tags} };

    return $post;
}

sub _handle_upload ( $file, $uuid ) {
    my $f       = $file->{tempname};
    my $newname = "$uuid.$file->{filename}";
    File::Copy::move( $f, "www/assets/$newname" );
    return "/assets/$newname";
}

=head2 delete(@posts)

Delete the following posts.
Will remove all versions of said post.

You should override this, it is a stub here.

=cut

sub delete ($self) { die 'stub' }

=head2 routes() = HASH

Returns the routes to each post.
You should override this for performance reasons, as it's just a wrapper around get() by defualt.

=cut

sub routes ($self) {
    my %routes = map { $_->{local_href} => { method => $_->{method}, callback => \&{ $_->{callback} } } } ( $self->get( limit => 0, acls => ['admin'] ) );
    return %routes;
}

=head2 aliases() = HASH

Returns the aliases for each post, indexed by aliases.
You should override this for performance reasons, as it's just a wrapper around get() by defualt.

=cut

sub aliases ($self) {
    my @posts = $self->get( limit => 0, acls => ['admin'] );
    my %aliases;
    foreach my $post (@posts) {
        @aliases{ @{ $post->{aliases} } } = $post->{local_href};
    }
    return %aliases;
}

1;
