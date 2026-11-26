package Trog::SQLite::TagIndex;

# ABSTRACT: An SQLite index of the posts of the flat file data model, by tag, with their routes and aliases

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use URI::Escape;
use List::Util qw{uniq};
use Trog::SQLite;

=head1 Trog::SQLite::TagIndex

An SQLite3 index of posts by tag and date.
Used to speed up the flat-file data model.

Also used to retrieve cached routes from posts.

=head1 FUNCTIONS

=cut

=head2 posts_for_tags(@tags)

The ids of the posts that have one of @tags, the newest created first.  With
no tags, the ids of every post in the index.

=over 4

=item @tags - Str - the tags

=back

Returns a list of Str, the ids of the posts, each once.

    my @ids = Trog::SQLite::TagIndex::posts_for_tags( @{ $query->{tags} } );

=cut

sub posts_for_tags (@tags) {
    my $dbh    = dbh();
    my $clause = @tags ? "WHERE tag IN (" . join( ',', ( map { '?' } @tags ) ) . ")" : '';
    ## no critic(ValuesAndExpressions::PreventSQLInjection)
    my $rows = $dbh->selectall_arrayref( "SELECT DISTINCT id FROM posts $clause ORDER BY created DESC", { Slice => {} }, @tags );
    return () unless ref $rows eq 'ARRAY' && @$rows;
    return map { $_->{id} } @$rows;
}

=head2 routes()

Maps the route of each post to its C<id>, C<route>, C<method> and C<callback>.
C<secure> is true for the route of a post tagged C<private>, so that it
answers only to somebody who is logged in.

Returns a HASH as a list: each route, unescaped, and a HashRef of its id,
route, method, callback and secure.

    my %routes = Trog::SQLite::TagIndex::routes();

=cut

sub routes {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT id, route, method, callback, secure FROM all_routes", { Slice => {} } );
    return () unless ref $rows eq 'ARRAY' && @$rows;

    #XXX not sure how this gets escaped going in.
    my %routes = map { local ($_) = $_; URI::Escape::uri_unescape( $_->{route} ) => $_ } @$rows;
    return %routes;
}

=head2 aliases()

The aliases of the posts in the index.

Returns a HASH as a list: each alias, and the route that it stands for.

    my %aliases = Trog::SQLite::TagIndex::aliases();

=cut

sub aliases {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT actual,alias FROM aliases", { Slice => {} } );
    return () unless ref $rows eq 'ARRAY' && @$rows;
    my %aliases = map { $_->{alias} => $_->{actual} } @$rows;
    return %aliases;
}

=head2 tags()

Returns a list of Str, every tag in the index.

    my @tags = Trog::SQLite::TagIndex::tags();

=cut

sub tags {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM tag", { Slice => {} } );
    return () unless ref $rows eq 'ARRAY' && @$rows;
    return map { $_->{name} } @$rows;
}

=head2 add_post($post, $data_obj)

Replace the tag rows and the routes of $post in the index.  posts_for_tags()
orders by C<created>, so pass the post as get() returns it, dated by its first
version and not by this save.  It is one transaction.  It sets the post_id,
method_id and callback_id of $post.

=over 4

=item post - HashRef - the post

=item data_obj - Trog::DataModule - the data model that holds the post

=back

Returns 1.

Dies when the database refuses a change.  Then it changes nothing.

    Trog::SQLite::TagIndex::add_post( $post, $data );

=cut

sub add_post ( $post, $data_obj ) {
    my $dbh = dbh();
    Trog::SQLite::transaction(
        $dbh,
        sub {
            # posts_index has no key for INSERT OR IGNORE to skip a duplicate on,
            # so a save would add every tag again and keep the ones it removed.
            $dbh->do( "DELETE FROM posts_index WHERE post_id IN (SELECT id FROM post WHERE uuid=?)", undef, $post->{id} );
            build_index( $data_obj, [$post] );
            build_routes( $data_obj, [$post] );
        }
    );
    return 1;
}

=head2 rebuild($data_obj)

Empty the index, the route table and the aliases, then fill them again from
every post $data_obj holds.  It is one transaction, so a reader sees the old
index or the new one, and never an empty one.

The HTTP methods are kept, as the schema fills those rather than any post.

=over 4

=item data_obj - Trog::DataModule - the data model to index

=back

Returns 1.

Dies when the database refuses a change.  Then it changes nothing.

    Trog::SQLite::TagIndex::rebuild($data);

=cut

sub rebuild ($data_obj) {
    my $dbh = dbh();
    Trog::SQLite::transaction(
        $dbh,
        sub {
            # Cascades to posts_index, routes and post_aliases.
            $dbh->do("DELETE FROM post");
            $dbh->do("DELETE FROM tag");
            $dbh->do("DELETE FROM callbacks");
            build_index($data_obj);
            build_routes($data_obj);
        }
    );
    return 1;
}

=head2 remove_post($post)

Remove $post from the index, with its tag rows, its route and its aliases.
Then remove each tag and each callback that no post uses any more.

=over 4

=item post - HashRef - the post.  Only its id counts.

=back

Returns 1.

    Trog::SQLite::TagIndex::remove_post($post);

=cut

sub remove_post ($post) {
    my $dbh = dbh();

    # Deleting the post will cascade to the post index & primary route, which cascades to the aliases
    $dbh->do( "DELETE FROM post WHERE uuid=?", undef, $post->{id} );

    # Now that we've wasted the routes and post, let's reap any dangling tags or callbacks.
    # We won't ever reap methods, because they're just HTTP methods in an enum table.
    $dbh->do("DELETE from callbacks WHERE id NOT IN (SELECT DISTINCT callback_id FROM routes)");
    $dbh->do("DELETE from tag WHERE id NOT IN (SELECT DISTINCT tag_id FROM posts_index)");
    return 1;
}

my sub id_for_uuid ( $dbh, @uuids ) {
    my $bind = join( ',', ( map { '?' } @uuids ) );
    Trog::SQLite::bulk_insert( $dbh, 'post', ['uuid'], 'IGNORE', @uuids );
    ## no critic(ValuesAndExpressions::PreventSQLInjection)
    return $dbh->selectall_hashref( "SELECT id,uuid FROM post WHERE uuid IN ($bind)", 'uuid', {}, @uuids );
}

=head2 build_index($data_obj, $posts)

Add the ids and the tags of the posts to the index.  It does not remove the
rows that a post has already, so call add_post() or rebuild(), which do.  It
sets the post_id of each post.

=over 4

=item data_obj - Trog::DataModule - the data model that holds the posts

=item posts - ArrayRef[HashRef] - the posts.  When it is empty, which is the default, every post that read() of $data_obj gives.

=back

Returns 1.

    Trog::SQLite::TagIndex::build_index( $data, [$post] );

=cut

sub build_index ( $data_obj, $posts = [] ) {
    my $dbh = dbh();
    $posts = $data_obj->read( { limit => 0, acls => ['admin'] } ) unless @$posts;

    # First, slap in the UUIDs
    my @uuids = map { $_->{id} } @$posts;
    Trog::SQLite::bulk_insert( $dbh, 'post', ['uuid'], 'IGNORE', @uuids );
    my $pids = id_for_uuid( $dbh, @uuids );
    foreach my $post (@$posts) {
        $post->{post_id} = $pids->{ $post->{id} }{id};
    }

    # Slap in the tags, plus the aclname in the event this is a series
    my @tags = uniq map { ( @{ $_->{tags} }, $_->{aclname} ) } @$posts;
    Trog::SQLite::bulk_insert( $dbh, 'tag', ['name'], 'IGNORE', @tags );

    #TODO restrict query to only the specific tags we care about
    my $t = $dbh->selectall_hashref( "SELECT id,name FROM tag", 'name' );
    foreach my $k ( keys(%$t) ) { $t->{$k} = $t->{$k}->{id} }

    # Finally, index the posts
    Trog::SQLite::bulk_insert(
        $dbh,
        'posts_index',
        [qw{post_id post_time tag_id}],
        'IGNORE',
        map {
            my $subj = $_;
            map { ( $subj->{post_id}, $subj->{created}, $t->{$_} ) } @{ $subj->{tags} }
        } @$posts
    );
    return 1;
}

# It is important we use get() instead of read() because of incomplete data.

=head2 build_routes($data_obj, $posts)

Add the route, the method, the callback and the aliases of each post.  It sets
the post_id, method_id and callback_id of each post.

=over 4

=item data_obj - Trog::DataModule - the data model that holds the posts

=item posts - ArrayRef[HashRef] - the posts.  When it is empty, which is the default, it fills it with every post that get() of $data_obj gives.

=back

Returns 1.

    Trog::SQLite::TagIndex::build_routes( $data, [$post] );

=cut

sub build_routes ( $data_obj, $posts = [] ) {
    my $dbh = dbh();
    @$posts = $data_obj->get( limit => 0, acls => ['admin'] ) unless @$posts;

    my @uuids = map { $_->{id} } @$posts;
    my $pids  = id_for_uuid( $dbh, @uuids );
    foreach my $post (@$posts) {
        $post->{post_id} = $pids->{ $post->{id} }{id};
    }

    # Ensure the callbacks we need are installed
    Trog::SQLite::bulk_insert( $dbh, 'callbacks', [qw{callback}], 'IGNORE', ( uniq map { $_->{callback} } @$posts ) );

    my $m = $dbh->selectall_hashref( "SELECT id, method FROM methods", 'method' );
    foreach my $k ( keys(%$m) ) { $m->{$k} = $m->{$k}->{id} }
    my $c = $dbh->selectall_hashref( "SELECT id, callback FROM callbacks", 'callback' );
    foreach my $k ( keys(%$c) ) { $c->{$k} = $c->{$k}->{id} }
    @$posts = map {
        $_->{method_id}   = $m->{ $_->{method} };
        $_->{callback_id} = $c->{ $_->{callback} };
        $_
    } @$posts;

    my @routes = map { ( $_->{post_id}, $_->{local_href}, $_->{method_id}, $_->{callback_id} ) } @$posts;
    Trog::SQLite::bulk_insert( $dbh, 'routes', [qw{post_id route method_id callback_id}], 'IGNORE', @routes );

    # Now, compile the post aliases
    my %routes_actual = routes();
    foreach my $post (@$posts) {
        next unless ( ref $post->{aliases} eq 'ARRAY' ) && @{ $post->{aliases} };
        my $route = $post->{local_href};
        Trog::SQLite::bulk_insert( $dbh, 'post_aliases', [qw{route_id alias}], 'IGNORE', map { ( $routes_actual{$route}{id}, $_ ) } @{ $post->{aliases} } );
    }
    return 1;
}

=head2 dbh()

The handle to the tag index, data/posts.db, with its schema applied.
Trog::SQLite caches it, so every call in a process gets the same one.

Returns DBI::db, the handle.

Dies when the database cannot be opened, or its schema cannot be applied.

    my $dbh = Trog::SQLite::TagIndex::dbh();

=cut

sub dbh {
    my $file   = 'schema/flatfile.schema';
    my $dbname = "data/posts.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

1;
