package Trog::DataSource;

use v5.36;
use re '/aa';

use Trog::DataModule ();
use Trog::Log        qw{:all};

=head1 Trog::DataSource

What a datasource is, and the default answers for the parts of it a given
datasource doesn't care to implement.

A post type can say its posts come from somewhere other than the datastore --
see Trog::DataSource::Virt, which builds them out of libvirt guests.  The series
is still an ordinary post; only its children are synthesized, and they are
rebuilt on every view rather than stored.

Datasources are plain packages under this namespace, called as functions rather
than methods, and named by a post type's sidecar in x-tcms-datasource.

=head1 THE CONTRACT

    posts($series, $query) = @posts       required

The children of $series, as post hashrefs.  Enough of a post to survive being
rendered like one -- see Trog::DataSource::Virt::_post_for for the shape.

    EDITABLE                              optional constant

Whether the wizard should generate an editor for a type drawn from this source.
A source which builds its posts from somewhere else has nothing to edit, and
saying nothing means no.

    CACHEABLE                             optional constant

Whether a page drawn from this source may be saved as a static render.  Saying
nothing means no -- see cacheable() for why that is the safe way round.

    filter($query, @posts) = @posts       optional

Apply the viewer's search to the synthesized posts.  Defaulted below; implement
it to search the fields your posts actually carry.

    order($query, @posts) = @posts        optional

The order they belong in.  Defaulted below; implement it if your posts have an
order of their own that a date and a title don't capture.

    lang() = STRING                       optional
    help() = STRING                       optional

What the search box is searching, and where to read about it, for a page drawn
from this source.  Defaulted below.

=head1 A NOTE ON WHAT A LISTING DISCLOSES

A datasource turns something into a list, and a list of names is itself
information.  Two things follow that are worth thinking about before you write
one.

The first is that the names may be more sensitive than the things.  A file whose
contents the webserver will refuse to serve still has a name, and publishing that
name publishes the fact of it.  Decide deliberately what your source is willing
to enumerate, rather than enumerating whatever it can reach and relying on
whatever gates the contents.

The second is that the webserver is part of the security model and you cannot see
it from here.  On a correctly provisioned site nginx auth_requests the
/authenticated route -- which answers 200 for a request carrying a live session
and 403 otherwise -- and gates www/assets/private on the result.  That protection
is real, it is why that route exists, and it is also invisible to this code and
absent on a site provisioned some other way.  Do not lean on it, and do not
duplicate it either: your job is to decide what to put in the list.

Trog::DataSource::DirIndex is the worked example, and documents where it drew
that line and why.

=head1 FUNCTIONS

=head2 filter($query, @posts) = @posts

The default search over synthesized posts: the query's C<like>, C<author>,
C<older> and C<newer>, with the same meanings they have for stored posts.

Deliberately not the tag, acl or version filtering Trog::DataModule::filter()
also does.  Those are answers about the datastore, and they are already settled
before a datasource is reached: the series carries the acls, the reader got to
its page by holding them, and every synthesized post belongs to that series.
Applying them again would at best be redundant, and at worst would blank the
page for a source whose posts carry no tags -- which nothing requires them to.

Nor does it paginate.  That is the route's job and is the same for every source
-- see order(), which is the part a source does get a say in.

A source with more to search than a title should say so by implementing filter()
rather than by hoping this one covers it.

=cut

sub filter ( $query, @posts ) {
    $query //= {};

    if ( length( $query->{like} // '' ) ) {
        my $like = $query->{like};
        @posts = grep { searchable_match( $like, $_->{title}, $_->{data} ) } @posts;
    }

    @posts = grep { ( $_->{user} // '' ) eq $query->{author} } @posts if $query->{author};

    # Coerced to a number the same way Trog::DataModule::filter() does it, since
    # this arrives straight off a query string.
    if ( $query->{older} ) {
        ( my $older = $query->{older} ) =~ s/[^0-9]//g;
        @posts = grep { ( $_->{created} // 0 ) < $older } @posts if length $older;
    }
    if ( $query->{newer} ) {
        ( my $newer = $query->{newer} ) =~ s/[^0-9]//g;
        @posts = grep { ( $_->{created} // 0 ) > $newer } @posts if length $newer;
    }

    return @posts;
}

=head2 searchable_match($like, @values) = BOOL

Whether any of @values contains $like, case insensitively.

The same case insensitive substring test Trog::DataModule::filter() applies to a
stored post's title and body, factored out so that a datasource can hand it the
fields its own posts actually carry without having to restate what a search
means.  Quotemeta'd, so a search for '*' looks for an asterisk.

Anything in @values which isn't a plain string is skipped, so an arrayref body
or a nested structure is passed over rather than matched against its address.

=cut

sub searchable_match ( $like, @values ) {
    return 0 unless length( $like // '' );

    foreach my $value (@values) {
        next     if !defined $value || ref $value;
        return 1 if $value =~ m/\Q$like\E/i;
    }
    return 0;
}

=head2 order($query, @posts) = @posts

The order synthesized posts belong in: newest first, then by title, then by id.

Pagination hands out page 2 of an order, so there had better be one, and it had
better be the same order next time somebody asks -- a list that comes back
shuffled makes page 2 a lottery rather than the next page.  Sorting the ties out
by title and then id is what makes this total rather than merely mostly decided.

Newest-first matches how stored posts are listed.  The tiebreaks carry the
weight in practice, because a source that builds its posts on the fly tends to
stamp them all with the time it built them: every libvirt guest comes back with
the same created, so what this really does for that page is sort it by name.

=cut

sub order ( $query, @posts ) {
    return sort { ( $b->{created} // 0 ) <=> ( $a->{created} // 0 ) || ( $a->{title} // '' ) cmp ( $b->{title} // '' ) || ( $a->{id} // '' ) cmp ( $b->{id} // '' ) } @posts;
}

=head2 lang() = STRING

What the search box searches on a page drawn from a datasource which hasn't said.

Not the data model's answer: the model's query language describes what it can do
to the datastore, and a datasource page is not being served out of the datastore.

=cut

sub lang { 'Case insensitive substring' }

=head2 help() = STRING

Where to read about it.

=cut

sub help { 'https://en.wikipedia.org/wiki/Substring' }

=head2 cacheable($source) = BOOL

Whether pages drawn from $source may be cached as static renders.

A datasource page is cached like any other unless something says not to, and
nothing else ever invalidates it: saving a post does not, because no post was
saved -- whatever the source draws on changed instead.  So a source has to
answer one of two questions, and it has to answer deliberately.

Either it knows what it depends on and can say when that changes, in which case
it should register a watch (Trog::DataSource::DirIndex::_watch is the worked
example) and declare CACHEABLE.  Or it doesn't, in which case its pages must not
be cached at all, because the cached copy has no way of ever becoming right
again.

Absent means not cacheable, which is the same way round as EDITABLE: a source
whose author has not thought about invalidation gets the answer that is merely
slow rather than the one that is wrong.

=cut

sub cacheable ($source) {
    return 0 unless $source && $source->can('CACHEABLE');
    return $source->CACHEABLE ? 1 : 0;
}

=head2 for_type($form) = STRING or undef

The datasource a post type names, or nothing when it names none.

Checked against this namespace rather than requiring whatever we were told to:
the name comes out of a sidecar, and a sidecar cannot be allowed to make us load
an arbitrary module.  Returns the module name without loading it; see load().

=cut

sub for_type ( $form = '' ) {
    return undef unless length( $form // '' );

    my $meta   = Trog::DataModule::type_meta_for($form);
    my $source = $meta->{'x-tcms-datasource'};
    return undef unless $source && !ref $source;

    if ( $source !~ m/^Trog::DataSource::\w+$/ ) {
        WARN("Post type '$form' names a datasource '$source' which isn't one");
        return undef;
    }

    return $source;
}

=head2 load($source) = BOOL

Load a datasource named by for_type(), returning whether it worked.

=cut

sub load ($source) {
    my $modpath = $source;
    $modpath =~ s{::}{/}g;
    $modpath .= '.pm';

    local $@;
    eval { require $modpath; 1 } or do {
        WARN("Datasource '$source' will not load: $@");
        return 0;
    };

    return 1;
}

1;
