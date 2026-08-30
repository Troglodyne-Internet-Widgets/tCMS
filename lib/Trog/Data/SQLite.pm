package Trog::Data::SQLite;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use JSON::MaybeXS;
use URI::Escape;
use List::Util qw{uniq};

use Trog::SQLite;
use parent qw{Trog::DataModule};

=head1 Trog::Data::SQLite

A fully SQLite-backed data module for tCMS.

Posts are stored as JSON blobs in a single SQLite database file
(C<data/tcms_posts.db>).  SQLite STORED generated columns provide
indexed access to C<uuid>, C<version>, and C<created> without
redundant storage.  Tag filtering, route and alias lookups are
handled with proper SQL joins rather than Perl-level post-processing.

To use this module, set C<data_model=SQLite> in C<config/main.cfg>.

=cut

our $schema = 'schema/sqlite_data.schema';
our $dbname = 'data/tcms_posts.db';

my $parser = JSON::MaybeXS->new( utf8 => 1 );

sub lang { 'SQL LIKE with json_extract()' }
sub help { 'https://www.sqlite.org/json1.html' }

sub _dbh {
    return Trog::SQLite::dbh( $schema, $dbname );
}

=head2 read(\%query) = \@posts

Returns an arrayref of post hashrefs matching the query.  All versions of
each matching UUID are included so that the parent C<DataModule::filter()>
can deduplicate and compute C<version_max>/C<created>/C<author> correctly.

SQL-level optimisations applied:
- Direct UUID lookup via C<uuid = ?>
- Tag filtering via C<post_tags> join
- Time-range filtering via C<created>

ACL, C<like>, C<author>, and C<form> filtering remain in the parent
C<filter()> implementation (post-SQL step).

=cut

sub read ( $self, $query = {} ) {
    my $dbh = _dbh();

    my @where_uuid;
    my @params_uuid;

    # Direct UUID lookup — returns all versions of that specific post.
    if ( $query->{id} ) {
        push @where_uuid, "uuid = ?";
        push @params_uuid, $query->{id};
    }
    elsif ( @{ $query->{tags} // [] } ) {
        my $ph = join( ',', map { '?' } @{ $query->{tags} } );
        push @where_uuid, "uuid IN (SELECT DISTINCT uuid FROM post_tags WHERE tag IN ($ph))";
        push @params_uuid, @{ $query->{tags} };
    }

    # Time-range filters
    if ( $query->{older} ) {
        ( my $older = $query->{older} ) =~ s/[^0-9]//g;
        push @where_uuid, "created < ?";
        push @params_uuid, $older;
    }
    if ( $query->{newer} ) {
        ( my $newer = $query->{newer} ) =~ s/[^0-9]//g;
        push @where_uuid, "created > ?";
        push @params_uuid, $newer;
    }

    my $where = @where_uuid ? "WHERE " . join( " AND ", @where_uuid ) : "";

    # Get the distinct UUIDs matching our filters, ordered by latest creation.
    my $uuids = $dbh->selectcol_arrayref(
        "SELECT DISTINCT uuid FROM posts $where ORDER BY created DESC",
        {}, @params_uuid
    );
    return [] unless $uuids && @$uuids;

    # Apply SQL LIMIT to UUID list — parent paginates over posts, not UUIDs,
    # but limiting the UUID set keeps memory bounded for large datasets.
    # limit=0 means "unlimited" in tCMS convention.
    if ( $query->{limit} && $query->{limit} != 0 ) {
        splice( @$uuids, $query->{limit} ) if @$uuids > $query->{limit};
    }

    # Fetch ALL versions for those UUIDs so parent _dedup_versions() has the
    # full history it needs to compute version_max, original created, etc.
    my $bind = join( ',', map { '?' } @$uuids );
    my $rows = $dbh->selectall_arrayref(
        "SELECT data FROM posts WHERE uuid IN ($bind) ORDER BY created DESC",
        { Slice => {} }, @$uuids
    );
    return [] unless $rows && @$rows;

    my @posts;
    for my $row (@$rows) {
        my $post = eval { $parser->decode( $row->{data} ) };
        if ($@) {
            warn "Trog::Data::SQLite: JSON decode error: $@";
            next;
        }
        push @posts, $post;
    }
    return \@posts;
}

=head2 write(\@posts)

Persists each post (all versions welcome) to the SQLite store and updates
the tag index, route, and alias tables.

=cut

sub write ( $self, $data ) {
    my $dbh = _dbh();

    for my $post (@$data) {
        my $json = $parser->encode($post);

        # Store the post version — replace if this uuid+version already exists.
        $dbh->do( "INSERT OR REPLACE INTO posts (data) VALUES (?)", undef, $json )
            or die "Trog::Data::SQLite write failed: " . $dbh->errstr;

        # Ensure UUID is registered.
        $dbh->do( "INSERT OR IGNORE INTO post_uuids (uuid) VALUES (?)", undef, $post->{id} )
            or die "Trog::Data::SQLite uuid insert failed: " . $dbh->errstr;

        # Refresh tag index for this UUID (overwrite completely on each write).
        $dbh->do( "DELETE FROM post_tags WHERE uuid = ?", undef, $post->{id} );
        for my $tag ( uniq @{ $post->{tags} // [] } ) {
            $dbh->do(
                "INSERT OR IGNORE INTO post_tags (uuid, tag) VALUES (?, ?)",
                undef, $post->{id}, $tag
            );
        }

        # Upsert route — delete first so cascade clears old aliases.
        $dbh->do( "DELETE FROM routes WHERE uuid = ?", undef, $post->{id} );
        $dbh->do(
            "INSERT INTO routes (uuid, route, method, callback) VALUES (?,?,?,?)",
            undef, $post->{id},
            $post->{local_href},
            $post->{method}   // 'GET',
            $post->{callback} // 'Trog::Routes::HTML::posts'
        ) or die "Trog::Data::SQLite route insert failed: " . $dbh->errstr;

        # Re-insert aliases (post_aliases is cascade-deleted above via routes).
        for my $alias ( uniq @{ $post->{aliases} // [] } ) {
            $dbh->do(
                "INSERT OR IGNORE INTO post_aliases (route, alias) VALUES (?, ?)",
                undef, $post->{local_href}, $alias
            );
        }
    }
}

=head2 count() = INT

Returns the total number of distinct post UUIDs.

=cut

sub count ($self) {
    my $dbh = _dbh();
    my ($n) = $dbh->selectrow_array("SELECT COUNT(*) FROM post_uuids");
    return $n // 0;
}

=head2 tags() = @tags

Returns the sorted list of all tags in use.

=cut

sub tags ($self) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectcol_arrayref("SELECT DISTINCT tag FROM post_tags ORDER BY tag");
    return @{ $rows // [] };
}

=head2 delete(@posts)

Removes all versions of the listed posts and their associated tags,
routes, and aliases.

=cut

sub delete ( $self, @posts ) {
    my $dbh = _dbh();
    for my $post (@posts) {
        # Deleting from post_uuids cascades to post_tags and routes (→ aliases).
        $dbh->do( "DELETE FROM post_uuids WHERE uuid = ?", undef, $post->{id} );
        # posts table uuid column is generated — no FK, must delete explicitly.
        $dbh->do( "DELETE FROM posts WHERE uuid = ?",      undef, $post->{id} );
    }
    return 0;
}

=head2 routes() = %routes

Returns a hash of route → { id, route, method, callback } suitable for
use as a Plack routing table.

=cut

sub routes ($self) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref(
        "SELECT id, route, method, callback FROM routes",
        { Slice => {} }
    );
    return () unless $rows && @$rows;
    return map { URI::Escape::uri_unescape( $_->{route} ) => $_ } @$rows;
}

=head2 aliases() = %aliases

Returns a hash of alias → canonical_route.

=cut

sub aliases ($self) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref(
        "SELECT actual, alias FROM aliases",
        { Slice => {} }
    );
    return () unless $rows && @$rows;
    return map { $_->{alias} => $_->{actual} } @$rows;
}

1;
