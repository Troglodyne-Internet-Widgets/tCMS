package Trog::Data::SQLite;

use v5.36;
use re '/aa';

use Carp qw{confess};
use JSON::MaybeXS;
use List::Util qw{any};

use lib 'lib';
use Trog::Log qw{:all};
use Trog::SQLite;

use parent qw{Trog::DataModule};

our $schema = 'schema/sqlite.schema';
our $dbname = 'data/posts.sqlite';

our $parser = JSON::MaybeXS->new( utf8 => 1 );

sub lang { 'SQLite FTS5 substring match' }
sub help { 'https://sqlite.org/fts5.html' }

=head1 Trog::Data::SQLite

The posts themselves in SQLite, rather than a flat file per post with SQLite
kept alongside as an index of it.

Each row is one version of one post: the post's JSON exactly as the flat file
model would have written it, in C<post_data>, and nothing else that isn't
C<GENERATED ALWAYS ... VIRTUAL> out of that blob.  The blob stays the single
source of truth, the projections cost no storage, and they cannot drift from
what they were drawn from.

What that buys is get(): the filtering Trog::DataModule::filter() does in Perl
over every post on disk happens here in one indexed query.  See _where() for
the mapping, which is filter() clause for clause.

Adding a queryable field is one ALTER TABLE and one CREATE INDEX in
schema/sqlite.schema, with no migration, because the data itself never moves.

=head1 Termination Conditions

Dies if the database can't be opened or the schema can't be applied, both of
which mean there is no data model to serve from.

=cut

sub _dbh {
    return Trog::SQLite::dbh( $schema, $dbname );
}

=head1 QUERYING

=head2 get(%request)

Trog::DataModule::get() without the filtering pass: the query does that.

Everything filter() would have grepped for is a WHERE clause, and paginate()'s
slice is LIMIT/OFFSET, so what comes back out of the database is already the
answer.  _fixup() still runs, as that fills in display fields rather than
choosing rows.

=cut

sub get ( $self, %request ) {
    my $posts = $self->read( \%request );
    return @$posts if $request{raw};

    return $self->_fixup(@$posts);
}

=head2 read($query) = ARRAYREF $posts

The rows a query selects, decoded back into posts.

With C<raw>, every version of everything the query matches, untouched -- that is
what an index build or a version history wants.  Otherwise one post per id: the
newest version, carrying the version_max, created, modified and author fields
that Trog::DataModule::_dedup_versions() would have computed by hand.

=cut

sub read ( $self, $query = {} ) {
    my ( $sql, @bind ) = _build_query($query);

    my $rows = _dbh()->selectall_arrayref( $sql, { Slice => {} }, @bind );
    return [] unless ref $rows eq 'ARRAY';

    my @posts;
    foreach my $row (@$rows) {
        my $post = eval { $parser->decode( $row->{post_data} ) };
        if ( !$post ) {
            WARN("Could not decode post '$row->{uuid}' version $row->{version}: $@");
            next;
        }
        if ( !$query->{raw} ) {

            # What _dedup_versions() works out by sorting the versions in Perl.
            # Deliberately the same shape, so a caller cannot tell which data
            # model answered it.
            $post->{version_max} = $row->{version_max};

            # Only when we were not asked for one version in particular.
            # _dedup_versions() rewrites these from the version history, and a
            # request for version 3 wants version 3's own dates, not the post's.
            if ( !_pinned($query) ) {
                $post->{modified} = $post->{created};
                $post->{created}  = $row->{first_created};
                $post->{author}   = $row->{first_author};
            }
        }

        push( @posts, $post );
    }

    return \@posts;
}

# One version of one post per row, so "the current post" is a join against
# post_versions, which the schema's triggers keep pointing at the newest row for
# each uuid.  f is the oldest version, which is where _dedup_versions() takes
# the post's own birthday and original author from.
sub _from_clause {
    return q{
        FROM posts p
        JOIN post_versions v ON v.uuid = p.uuid
        JOIN posts f ON f.id = v.first_id
    };
}

# Whether the caller named a version.  Empty string counts as unasked, since
# that is what a form posts for a field nobody filled in.
sub _pinned ($query) {
    return defined $query->{version} && $query->{version} ne '';
}

sub _build_query ($query) {
    my $select = q{SELECT p.post_data, p.uuid, p.version, v.version_max, v.first_created, f.author AS first_author};

    my ( $where, $bind ) = _where($query);

    # A raw read with no filters has no clauses at all, and "WHERE" on its own
    # is a syntax error rather than "everything".
    push( @$where, '1 = 1' ) unless @$where;

    my $sql = "$select " . _from_clause() . " WHERE " . join( ' AND ', @$where );

    # Newest first, by the same date the caller gets back as created -- the
    # post's birthday.  The flat file model returned posts in readdir order,
    # which is to say whatever order the filesystem felt like; every caller that
    # cared went through the tag index, which ordered by created DESC.
    $sql .= ' ORDER BY v.first_created DESC, p.uuid DESC';

    # 0 means unlimited, as it does in the flat file model.
    my @extra;
    my $limit = defined $query->{limit} ? int( $query->{limit} ) : 25;
    if ($limit) {
        $sql .= ' LIMIT ?';
        push( @extra, $limit );
        if ( $query->{page} ) {
            $sql .= ' OFFSET ?';
            push( @extra, ( int( $query->{page} ) - 1 ) * $limit );
        }
    }

    return ( $sql, @$bind, @extra );
}

# filter(), clause for clause.  Read the two side by side when changing either.
sub _where ($query) {
    my ( @where, @bind );

    # Which versions are in play.  Everything else filters within that.
    #
    # raw is the exception: it means "the history, as stored", which is what a
    # migration or an index rebuild reads, so it pins nothing.
    if ( _pinned($query) ) {
        push( @where, 'p.version = ?' );
        push( @bind,  int( $query->{version} ) );
    }
    elsif ( !$query->{raw} ) {
        push( @where, 'p.id = v.latest_id' );
    }

    # An id, title or aclname query is answered on its own, with no tag, acl or
    # visibility filtering after it -- exactly as filter() returns early for
    # these three.  It is how add() asks whether a post already exists, and how
    # a route fetches the post it is about to render.
    foreach my $key (qw{id title aclname}) {
        next unless $query->{$key};
        my $column = $key eq 'id' ? 'p.uuid' : "p.$key";
        push( @where, "$column = ?" );
        push( @bind,  $query->{$key} );
        return ( \@where, \@bind );
    }

    # Against the first version's date, not this row's.  filter() applies these
    # after _dedup_versions() has already rewritten created to the oldest
    # version's, so older/newer have always meant the post's birthday rather
    # than the date of its most recent edit.
    if ( $query->{older} ) {
        ( my $older = $query->{older} ) =~ s/[^0-9]//g;
        push( @where, 'v.first_created < ?' );
        push( @bind,  $older );
    }
    if ( $query->{newer} ) {
        ( my $newer = $query->{newer} ) =~ s/[^0-9]//g;
        push( @where, 'v.first_created > ?' );
        push( @bind,  $newer );
    }

    # Any one of these tags.  post_tags is one row per tag per post version, so
    # membership is an indexed lookup rather than a scan of every post's array.
    if ( ref $query->{tags} eq 'ARRAY' && @{ $query->{tags} } ) {
        my $binds = join( ',', map { '?' } @{ $query->{tags} } );
        push( @where, "p.id IN (SELECT post_id FROM post_tags WHERE tag IN ($binds))" );
        push( @bind,  @{ $query->{tags} } );
    }

    # None of these.
    if ( ref $query->{exclude_tags} eq 'ARRAY' && @{ $query->{exclude_tags} } ) {
        my $binds = join( ',', map { '?' } @{ $query->{exclude_tags} } );
        push( @where, "p.id NOT IN (SELECT post_id FROM post_tags WHERE tag IN ($binds))" );
        push( @bind,  @{ $query->{exclude_tags} } );
    }

    # The load bearing one: a post is only visible to a caller holding one of
    # its tags, since visibility and acls are both stored as tags.  admin skips
    # it, as it does in filter().
    my $acls = ref $query->{acls} eq 'ARRAY' ? $query->{acls} : [];
    if ( $query->{raw} ) {

        # raw skips filter() altogether in the flat file model, acls included.
        # Only bin/migrate*.pl and an index rebuild ask for it.
    }
    elsif ( @$acls && !any { $_ eq 'admin' } @$acls ) {
        my $binds = join( ',', map { '?' } @$acls );
        push( @where, "p.id IN (SELECT post_id FROM post_tags WHERE tag IN ($binds))" );
        push( @bind,  @$acls );
    }
    elsif ( !@$acls ) {

        # filter() greps against an empty list here, which matches nothing.
        push( @where, '0 = 1' );
    }

    if ( $query->{form} ) {
        push( @where, 'COALESCE(p.form, ?) = ?' );
        push( @bind, '', $query->{form} );
    }

    if ( $query->{author} ) {
        push( @where, 'p.user = ?' );
        push( @bind,  $query->{author} );
    }

    if ( length( $query->{like} // '' ) ) {
        my ( $clause, @like_bind ) = _like_clause( $query->{like} );
        push( @where, $clause );
        push( @bind,  @like_bind );
    }

    return ( \@where, \@bind );
}

=head2 _like_clause($term)

The 'like' filter: a case insensitive substring match over a post's title and
its content.

Answered by the FTS5 index, which is built with the trigram tokenizer precisely
so that substring is a thing it can answer.  The term goes in as a quoted
phrase, doubling any quote in it, so that a search for C<AND> or C<"> is a
search for that text rather than FTS5 query syntax the user did not ask for.

Trigram indexes nothing shorter than three characters, so shorter terms fall
back to a LIKE scan.  That is the slow path, and it is the only one -- but a one
or two character search matches most of the site anyway.

=cut

sub _like_clause ($term) {

    if ( length($term) < 3 ) {
        my $escaped = $term;
        $escaped =~ s/([\\%_])/\\$1/g;
        return ( "(p.title LIKE ? ESCAPE '\\' OR p.data LIKE ? ESCAPE '\\')", "%$escaped%", "%$escaped%" );
    }

    my $phrase = $term;
    $phrase =~ s/"/""/g;
    return ( 'p.id IN (SELECT rowid FROM posts_fts WHERE posts_fts MATCH ?)', qq{"$phrase"} );
}

=head1 WRITING

=head2 write($posts)

Insert each post as a new row.

No read-modify-write, and so nothing to lose: the flat file model had to take a
lock around rewriting the whole version history of a post, because the history
was the file.  Here a version is a row, and the unique index on (uuid, version)
is what rejects two workers writing the same version rather than one of them
silently winning.

=cut

sub write ( $self, $data ) {
    my $dbh = _dbh();

    my $insert = $dbh->prepare('INSERT INTO posts (post_data) VALUES (?)');

    foreach my $post (@$data) {
        confess "Cannot write a post with no id" unless $post->{id};

        # Not stored: they are computed per query from the version history, and
        # writing them would bake one query's answer into the post forever.
        my %stored = %$post;
        delete @stored{qw{version_max modified display_name user_class post_id}};
        $stored{version} //= 0;

        # Checked rather than fired and forgotten: DBI is not in RaiseError mode
        # here, so a rejected write -- the unique index catching two workers on
        # the same version, most of all -- would otherwise be a warning on
        # stderr and a save the user was told had succeeded.
        $insert->execute( $parser->encode( \%stored ) )
          or confess "Could not write post '$post->{id}' version $stored{version}: " . $dbh->errstr;
    }

    return 1;
}

=head2 delete(@posts)

Remove every version of each post.  The triggers in the schema take the tag rows
and the search index with them.

=cut

sub delete ( $self, @posts ) {
    my $dbh    = _dbh();
    my $delete = $dbh->prepare('DELETE FROM posts WHERE uuid = ?');

    $delete->execute( $_->{id} ) foreach @posts;

    return 0;
}

=head2 count() = INT

How many posts there are, counting a post once however many versions it has.

=cut

sub count ($self) {
    my ($count) = _dbh()->selectrow_array('SELECT COUNT(DISTINCT uuid) FROM posts');
    return $count // 0;
}

=head2 index_fields(@fields)

Give each named custom field a virtual column and an index, and take the indexes
back off the fields no longer named.

This is what the Post Type Wizard's per-field "Index this field" checkbox does
when the site is on this data model.  A virtual generated column costs no
storage and ADD COLUMN on one rewrites nothing, so the expensive half is
building the index, which is a one-off.

Called with every indexed field across every post type, not just the type that
was saved -- two types can declare the same field name, and reconciling against
the whole picture is what stops saving one of them dropping the other's index.

Only indexes this created are ever dropped, which is why they carry a prefix.
The columns are left in place: they cost nothing, something may reference one,
and re-ticking the box then only has to rebuild the index.

Field names are re-validated here rather than trusted from the caller -- they
reach SQLite as an identifier and a JSON path, neither of which can be bound as
a parameter.

=cut

our $index_prefix = 'posts_custom_';

# The columns schema/sqlite.schema defines for itself.  The wizard already
# refuses a custom field named after anything in the post schema, which covers
# most of these; this is the backstop for the ones that are not post fields at
# all, and it is what stops "index this field" quietly indexing the blob.
our %reserved = map { $_ => 1 } qw{id post_data uuid version created title user author form aclname visibility local_href data};

sub index_fields ( $self, @fields ) {
    my $dbh = _dbh();

    my %want;
    foreach my $field (@fields) {
        my ($safe) = ( $field // '' ) =~ m/^([a-z][a-z0-9_]{0,31})$/;
        if ( !defined $safe ) {
            WARN( "Refusing to index '" . ( $field // '' ) . "': not a field name" );
            next;
        }
        if ( $reserved{$safe} ) {
            WARN("Refusing to index '$safe': the schema owns that column, and already indexes the ones worth indexing");
            next;
        }
        $want{$safe} = 1;
    }

    # Whatever is already there, base columns included.  A custom field can
    # never be named after one of those -- the wizard refuses any name already
    # in the post schema -- so anything found here is either ours or was added
    # by hand, and either way there is nothing to add.
    #
    # xinfo rather than info: table_info omits generated columns, which is every
    # column on this table bar the blob, so it would report an empty slate every
    # time and ADD COLUMN would fail on the second call for the same field.
    my %have = map { $_->{name} => 1 } @{ $dbh->selectall_arrayref( 'PRAGMA table_xinfo(posts)', { Slice => {} } ) // [] };

    my $built = 0;
    foreach my $field ( sort keys %want ) {
        if ( !$have{$field} ) {
            ## no critic(ValuesAndExpressions::PreventSQLInjection) -- $field is the anchored capture above
            $dbh->do("ALTER TABLE posts ADD COLUMN $field TEXT GENERATED ALWAYS AS (json_extract(post_data, '\$.$field')) VIRTUAL")
              or confess "Could not add a column for '$field': " . $dbh->errstr;
        }

        ## no critic(ValuesAndExpressions::PreventSQLInjection) -- as above
        $dbh->do("CREATE INDEX IF NOT EXISTS $index_prefix$field ON posts($field)")
          or confess "Could not index '$field': " . $dbh->errstr;
        $built++;
    }

    # Anything we built before and were not asked for this time.
    my $ours = $dbh->selectall_arrayref(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'posts' AND name LIKE ?",
        { Slice => {} },
        "$index_prefix%"
    ) // [];

    my $dropped = 0;
    foreach my $index ( map { $_->{name} } @$ours ) {
        my $field = substr( $index, length($index_prefix) );
        next if $want{$field};

        ## no critic(ValuesAndExpressions::PreventSQLInjection) -- $index came out of sqlite_master
        $dbh->do("DROP INDEX IF EXISTS $index") or confess "Could not drop the index on '$field': " . $dbh->errstr;
        $dropped++;
    }

    INFO("Indexed $built custom field(s), dropped $dropped") if $built || $dropped;
    return $built;
}

=head2 tags() = @tags

Every tag in use, from the index the schema's triggers maintain.

=cut

sub tags ($self) {
    my $rows = _dbh()->selectall_arrayref( 'SELECT DISTINCT tag FROM post_tags ORDER BY tag', { Slice => {} } );
    return () unless ref $rows eq 'ARRAY';
    return map { $_->{tag} } @$rows;
}

1;
