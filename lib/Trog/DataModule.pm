package Trog::DataModule;

use strict;
use warnings;

use FindBin::libs;

use List::Util;
use File::Copy;
use Path::Tiny();
use Ref::Util();
use File::Basename qw{basename};
use File::Slurper();
use JSON::MaybeXS();
use JSON::Validator::Schema::Troglodyne();

use Trog::Themes();

use Trog::Log qw{:all};
use Trog::Utils;
use Trog::Auth();

no warnings 'experimental';
use feature qw{signatures state};

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

=head1 ABSTRACT METHODS

Subclasses must implement all of these; the stubs here do nothing but die.
count() belongs to this set as well, and is documented with the rest of the
querying interface below.

=head2 lang() = STRING $language

The name of the query language this data model understands, shown to the user
beside the search bar.

=head2 help() = STRING $help

Documentation for that query language, shown to the user alongside it.

=head2 read($query) = ARRAYREF $posts

Every post the data model holds, as an arrayref of hashrefs.  Filtering is
get()'s job unless your storage engine can do it more cheaply itself, in which
case honour $query here and override get() too.

=head2 write($posts)

Commit an arrayref of posts to storage.  Called by add() once the posts have
been filtered and validated; don't validate again here.

=head2 tags() = ARRAYREF $tags

Every tag known to the datastore, for building tag pickers.

=cut

#It is required that subclasses implement this
sub lang  ($self)                { ... }
sub help  ($self)                { ... }
sub read  ( $self, $query = {} ) { ... }
sub write ($self)                { ... }
sub count ($self)                { ... }
sub tags  ($self)                { ... }

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
        my $is_user_page = List::Util::any { ($_ // '') eq 'about' } @{ $subj->{tags} };
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

        $subj->{user_class} = Trog::Auth::username2classname( $subj->{user} );
        $subj
    } @filtered;

    return @filtered;
}

sub _filter_param ( $query, $param, @filtered ) {
    @filtered = grep { ( $_->{$param} || '' ) eq $query->{$param} } @filtered;
    @filtered = _dedup_versions( $query->{version}, @filtered );
    return @filtered;
}

=head2 filter($query, @posts) = @filtered

Apply a get() request's filters to a list of posts: tags, exclude_tags, acls,
visibility, id, title, form, search terms and author.

The ACL check is the load bearing one -- a post is only visible if the caller
holds one of its acls, or the post is public or unlisted.  Callers holding the
'admin' acl skip that filter entirely.

=cut

sub filter ( $self, $query, @filtered ) {
    $query->{acls}         //= [];
    $query->{tags}         //= [];
    $query->{exclude_tags} //= [];

    # If an ID or title or acl is passed, just get that (and all it's prior versions)
    foreach my $key (qw{id title aclname}) {
        next unless $query->{$key};
        return _filter_param( $query, $key, @filtered );
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
            grep { ($t // '') eq $_ } @{ $query->{tags} }
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

    @filtered = grep { ($_->{form} || '') eq $query->{form} } @filtered if $query->{form};

    @filtered = grep { $_->{title} =~ m/\Q$query->{like}\E/i || $_->{data} =~ m/\Q$query->{like}\E/i } @filtered if $query->{like};

    @filtered = grep { $_->{user} eq $query->{author} } @filtered if $query->{author};

    return @filtered;
}

=head2 paginate($query, @posts) = @page

The slice of @posts named by the request's page and limit.  Both have to be
present to page at all; limit defaults to 25 when computing the offset.

=cut

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

These will have their parameters filtered to those described by the post type's
schema (see schema_for()), and then validated against it.  If the post doesn't
hold up, this dies with an ARRAYREF of validation error strings -- a ref rather
than a string so that Carp::Always doesn't staple a stack trace onto something
we intend to show the user.

You probably won't want to override this.

=cut

# The shape of a post, as an OpenAPIv3 object schema.
#
# This covers the fields every post has regardless of which form produced it.
# Anything a *particular* post type ingests lives in that type's JSON sidecar
# next to its template in the forms directory -- see _schema_for().
our %post_schema = (
    type       => 'object',
    properties => {

        ## Parameters which must be in every single post
        title      => { type => 'string' },
        callback   => { type => 'callback' },
        tags       => { type => 'array',   items   => { type => 'string' } },
        version    => { type => 'integer', minimum => 0 },
        visibility => { type => 'string',  enum    => [qw{public unlisted private}] },
        aliases    => { type => 'array',   items   => { type => 'string' } },

        # title links here
        href => { type => 'string' },

        # Link to post locally
        local_href => { type => 'string' },

        # Post body.  Multi-page types (presentations, invoices) send an array.
        data => {
            oneOf => [
                { type => 'string' },
                { type => 'array', items => { type => 'string' } },
            ],
        },

        # How do I edit this post?
        form => { type => 'string' },

        # Post is restricted to visibility to these ACLs if not public/unlisted
        acls => { type => 'array', items => { type => 'string' } },
        id   => { type => 'string' },

        # Author of the post
        user    => { type => 'string' },
        created => { type => 'integer' },

        # Posts are always GET, but it's stored, so it has to be describable.
        method => { type => 'string' },
    },
);

# Uploads arrive as an HTTP::Body hashref on the way in, and as the href string
# they were turned into on the way back out of the datastore.  Sidecars say
# 'upload' and mean this.
our %upload_schema = (
    oneOf => [
        { type => 'string' },
        { type => 'object' },
    ],
);

=head2 schema_for($form)

Return the OpenAPIv3 schema describing what the named post type ingests: the
base post schema above, with the type's JSON sidecar merged over the top.

Sidecars live beside their templates (blog.tx has blog.json) and are written
either by hand or by the Post Type Wizard.  A post with no form, or a form with
no sidecar, just gets the base schema.

Cached, but keyed on the mtimes of the component dirs rather than memoized
outright: adding or editing a sidecar bumps one of them, so every forked worker
picks the change up on its very next add() with no restart needed.

=cut

# Stat the forms dirs, not their parents -- writing blog.json bumps the mtime
# of forms/, and nothing above it.  Both candidates, since either one gaining a
# sidecar changes the answer.
sub _sidecar_generation {
    return join( ':', map { ( stat("$_/forms") )[9] // 0 } Trog::Themes::template_dirs( 'text/html', 1 ) );
}

# A signature default only covers an absent arg, and plenty of posts have an
# explicitly undef form.
sub _type_of ($form) {
    $form = '' if !defined $form || ref $form;
    my ($type) = $form =~ m/^([A-Za-z0-9_-]+)\.tx$/;
    return $type // '';
}

=head2 type_meta_for($form)

The parts of a post type's sidecar which aren't schema: x-tcms-relations,
x-tcms-post-type and friends.

schema_for() deliberately keeps only properties and required, since everything
else would be noise to the validator -- but the relation tables and the post
type's own metadata live out there and something has to read them.

=cut

sub type_meta_for ( $form = '' ) {
    state %cache;

    my $generation = _sidecar_generation();
    %cache = () unless exists $cache{$generation};

    my $type = _type_of($form);
    return $cache{$generation}{$type} if exists $cache{$generation}{$type};

    my $path = $type ? Trog::Themes::themed_file_in_dir( 'forms', "$type.json", 'text/html', 1 ) : undef;
    my $sidecar = $path ? _read_sidecar($path) : undef;

    my %meta;
    if ($sidecar) {
        %meta = map { $_ => $sidecar->{$_} } grep { $_ ne 'properties' && $_ ne 'required' && $_ ne 'type' } keys(%$sidecar);
    }

    $cache{$generation}{$type} = \%meta;
    return $cache{$generation}{$type};
}

=head2 relations_for($form)

The x-tcms-relations table for a post type, as a hashref keyed on the template
variable the resolved posts land in.  Empty when the type declares none.

Each entry is { form => 'other.tx', from => 'field_name' } -- 'from' naming the
field holding a UUID to resolve, or absent to mean every post of that type.

=cut

sub relations_for ( $form = '' ) {
    my $relations = type_meta_for($form)->{'x-tcms-relations'};
    return {} unless Ref::Util::is_hashref($relations);
    return $relations;
}

sub schema_for ( $form = '' ) {
    state %cache;

    my $generation = _sidecar_generation();

    # Only ever keep the current generation around.
    %cache = () unless exists $cache{$generation};

    my $type = _type_of($form);
    return $cache{$generation}{$type} if exists $cache{$generation}{$type};

    my %merged = ( %post_schema, properties => { %{ $post_schema{properties} } } );

    # Themed like the templates themselves: a theme that overrides blog.tx can
    # ship its own blog.json alongside it, and one that doesn't still gets the
    # stock schema rather than nothing at all.
    my $path    = $type ? Trog::Themes::themed_file_in_dir( 'forms', "$type.json", 'text/html', 1 ) : undef;
    my $sidecar = $path ? _read_sidecar($path)                                                      : undef;
    if ($sidecar) {

        # The base schema is merged *last*, so a sidecar can add fields but can
        # never redefine one of ours.  That matters: a sidecar retyping
        # 'callback' as a plain string would defeat the check that the sub it
        # names actually exists, which is a privilege problem rather than a
        # cosmetic one.
        %{ $merged{properties} } = ( %{ $sidecar->{properties} // {} }, %{ $merged{properties} } );

        # A sidecar may insist on its own fields, but it can't relax anything
        # the base schema already demands.
        my @required = List::Util::uniq( @{ $post_schema{required} // [] }, @{ $sidecar->{required} // [] } );

        # An empty required list isn't legal OpenAPI, so don't emit one.
        $merged{required} = \@required if @required;
    }

    $cache{$generation}{$type} = \%merged;
    return $cache{$generation}{$type};
}

sub _read_sidecar ($path) {
    return undef unless -f $path;

    local $@;
    my $spec = eval { JSON::MaybeXS::decode_json( File::Slurper::read_text($path) ) };
    if ( !$spec ) {
        WARN("Could not parse post type sidecar '$path': $@");
        return undef;
    }
    return undef unless Ref::Util::is_hashref($spec);

    _expand_pseudo_types($spec);
    return $spec;
}

# A relation is stored as the referenced post's UUID, and resolved into the
# post itself at render time -- see the x-tcms-relations table a sidecar
# declares alongside it, and Trog::Routes::HTML::_enrich_post.  The pseudo-type
# exists so a sidecar can say what a field *means* rather than just that it
# happens to be a string.
our %relation_schema = ( type => 'string' );

# Sugar: a sidecar says {"type":"upload"} rather than spelling out the
# string-or-hashref dance every upload field would otherwise need.  Uploads are
# a hashref on the way in from the browser and the href string they became on
# the way back out of the datastore.
sub _expand_pseudo_types ($node) {
    return unless Ref::Util::is_hashref($node);

    my %pseudo = (
        upload   => \%upload_schema,
        relation => \%relation_schema,
    );

    my $type = $node->{type} // '';
    if ( $pseudo{$type} ) {
        delete $node->{type};
        %$node = ( %$node, %{ $pseudo{$type} } );
        return;
    }

    _expand_pseudo_types($_) foreach values( %{ $node->{properties} // {} } );
    _expand_pseudo_types( $node->{items} ) if $node->{items};
    foreach my $key (qw{oneOf anyOf allOf}) {
        next unless Ref::Util::is_arrayref( $node->{$key} );
        _expand_pseudo_types($_) foreach @{ $node->{$key} };
    }
    return;
}

=head2 validate($post)

Filter a post down to the fields its type actually describes, then run what's
left through the schema.

Returns the list of validation errors, which is empty when the post is good.
Note that filtering happens first and silently: the query hash handed to us by
the router is full of things which aren't post fields at all, and never was
meant to round-trip.

=cut

sub validate ($post) {
    state $validator;
    $validator //= JSON::Validator::Schema::Troglodyne->new();

    my $schema = schema_for( $post->{form} );

    foreach my $key ( keys(%$post) ) {

        # Drop everything the schema doesn't describe.
        my $property = $schema->{properties}{$key};
        if ( !$property ) {
            delete $post->{$key};
            next;
        }

        # An untouched form input submits the empty string, which is HTML for
        # "I wasn't filled in" rather than a number, a boolean or a file.  We
        # leave it alone for actual string fields, which is what got stored
        # before any of this was typed.
        delete $post->{$key}
          if defined $post->{$key}
          && !ref $post->{$key}
          && $post->{$key} eq ''
          && ( $property->{type} // '' ) ne 'string';
    }

    # OpenAPIv3 coerces as it goes, so "4" lands in the datastore as 4 and
    # checkbox values land as real booleans.
    return $validator->validate( $post, $schema );
}

sub add ( $self, @posts ) {
    my @to_write;

    foreach my $post (@posts) {

        # Filter to what this post type actually describes, then validate it.
        my @errors = validate($post);

        # An arrayref rather than a string on purpose.  These errors get shown
        # to whoever submitted the post, and Carp::Always decorates a string
        # die with a stack trace they have no use for.
        die [ map { "$_" } @errors ] if @errors;

        $post->{id}      //= Trog::Utils::uuid();
        $post->{aliases} //= [];
        $post->{aliases} = [ $post->{aliases} ] unless ref $post->{aliases} eq 'ARRAY';

        if ( $post->{aclname} ) {

            # Then this is a series
            $post->{local_href} //= "/$post->{aclname}";
            push( @{ $post->{aliases} }, "/posts/$post->{id}", "/series/$post->{id}" );
        }

        # Every post needs one: _process pushes it into the tags, and an
        # undef there is a tag no query will ever match, which makes the post
        # invisible to everyone but an admin.  A post type built without a
        # visibility selector would otherwise produce exactly that.  Private
        # rather than public, because guessing wrong in the other direction
        # publishes something nobody asked to publish.
        $post->{visibility} //= 'private';

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

        #XXX if local_href has /secure paths in it, fix this.  We don't want to save that.
        if (index($post->{local_href}, '/secure/') == 0) {
            $post->{local_href} =~ s|/secure||gmx;
        }

        $post = _process($post);

        push @to_write, $post;
    }
    $self->write( \@to_write );

    return 0;
}

#XXX this level of post-processing seems gross, but may be unavoidable
# Not actually a subprocess, kek
sub _process ($post) {

    # If the post is private, make sure it's associated assets are too.
    my $is_private_post = $post->{visibility} eq 'private';

    $post->{href}      = _handle_upload( $post->{file},           $post->{id}, $is_private_post ) if $post->{file};
    $post->{preview}   = _handle_upload( $post->{preview_file},   $post->{id}, $is_private_post ) if $post->{preview_file};
    $post->{wallpaper} = _handle_upload( $post->{wallpaper_file}, $post->{id}, $is_private_post ) if $post->{wallpaper_file};
    @{ $post->{attachments} } = map { _handle_upload( $_, $post->{id}, $is_private_post ) } @{ $post->{attachments} } if $post->{attachments};
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
    push( @{ $post->{tags} }, @{ $post->{acls} } ) if $is_private_post;
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
    $post->{content_type}       = Trog::Utils::mime_type("www/$post->{href}")       if $post->{href};
    $post->{video_content_type} = Trog::Utils::mime_type("www/$post->{video_href}") if $post->{video_href};
    $post->{audio_content_type} = Trog::Utils::mime_type("www/$post->{audio_href}") if $post->{audio_href};
    $post->{content_type} ||= 'text/html';

    $post->{is_video}   = 1 if $post->{content_type} =~ m/^video\//;
    $post->{is_audio}   = 1 if $post->{content_type} =~ m/^audio\//;
    $post->{is_image}   = 1 if $post->{content_type} =~ m/^image\//;
    $post->{is_profile} = 1 if grep { $_ eq 'about' } @{ $post->{tags} };

    return $post;
}

# Browsers try and save time in the event that the same file is sent twice, so handle that.
my %seen_files;

sub _handle_upload ( $file, $uuid, $private=0 ) {
    my $fname;
    if ( ref $file ne 'HASH' ) {
        use Data::Dumper;
        $file =~ s/\\/\//g;
        $fname = basename($file);
        FATAL("Did not expect bogus file before its real counterpart!") unless $seen_files{$fname};
        return $seen_files{$fname};
    }
    my $f = $file->{tempname};
    $fname = basename( $file->{filename} );
    my $newname = "$uuid.$file->{filename}";
    $newname = "private/$newname" if $private;
    File::Copy::move( $f, "www/assets/$newname" );
    # Regrettably, we have no control over the perms of the temp file that starman creates for uploads.
    chmod(0755, "www/assets/$newname");
    $seen_files{$fname} = "/assets/$newname";
    return $seen_files{$fname};
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
