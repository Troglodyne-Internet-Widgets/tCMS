use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurper qw{read_text};
use DBI;

require_ok('Trog::SQLite')          or BAIL_OUT("Can't load Trog::SQLite");
require_ok('Trog::SQLite::TagIndex') or BAIL_OUT("Can't load Trog::SQLite::TagIndex");

# Build an in-memory database using the real flatfile schema.
sub _make_dbh {
    my $schema = read_text("$FindBin::Bin/../schema/flatfile.schema");
    my $dbh    = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '' );
    $dbh->{sqlite_allow_multiple_statements} = 1;
    $dbh->do($schema) or die "Could not apply schema: " . $dbh->errstr;
    $dbh->{sqlite_allow_multiple_statements} = 0;
    $dbh->do("PRAGMA foreign_keys = ON");
    return $dbh;
}

my $dbh;
my $sqlite_mock;

sub setup {
    $dbh         = _make_dbh();
    $sqlite_mock = Test::MockModule->new('Trog::SQLite');
    $sqlite_mock->redefine( 'dbh', sub { $dbh } );
}

setup();

subtest 'tags — empty database' => sub {
    my @tags = Trog::SQLite::TagIndex::tags();
    is( scalar @tags, 0, 'no tags in empty database' );
};

subtest 'routes — empty database' => sub {
    my %routes = Trog::SQLite::TagIndex::routes();
    is( scalar keys %routes, 0, 'no routes in empty database' );
};

subtest 'aliases — empty database' => sub {
    my %aliases = Trog::SQLite::TagIndex::aliases();
    is( scalar keys %aliases, 0, 'no aliases in empty database' );
};

subtest 'posts_for_tags — empty database' => sub {
    my @ids = Trog::SQLite::TagIndex::posts_for_tags('blog');
    is( scalar @ids, 0, 'no posts for nonexistent tag' );
};

# Populate database with test data.
sub _seed_db {
    # Insert a post
    $dbh->do("INSERT INTO post (uuid) VALUES ('uuid-1')");
    my $post_id = $dbh->last_insert_id;

    # Insert tags
    $dbh->do("INSERT INTO tag (name) VALUES ('blog')");
    my $tag_id = $dbh->last_insert_id;
    $dbh->do("INSERT INTO tag (name) VALUES ('news')");
    my $tag2_id = $dbh->last_insert_id;

    # Index the post under the tags
    $dbh->do( "INSERT INTO posts_index (post_id, post_time, tag_id) VALUES (?,?,?)",
        undef, $post_id, 1000000, $tag_id );
    $dbh->do( "INSERT INTO posts_index (post_id, post_time, tag_id) VALUES (?,?,?)",
        undef, $post_id, 1000000, $tag2_id );

    # Insert a callback and method so we can add a route
    $dbh->do("INSERT OR IGNORE INTO callbacks (callback) VALUES ('Trog::Routes::HTML::blog')");
    my $cb_id = $dbh->last_insert_id;
    my $m_row = $dbh->selectrow_hashref("SELECT id FROM methods WHERE method='GET'");
    my $m_id  = $m_row->{id};

    # Insert a route for the post
    $dbh->do( "INSERT INTO routes (post_id, route, method_id, callback_id) VALUES (?,?,?,?)",
        undef, $post_id, '/blog/post-1', $m_id, $cb_id );
    my $route_id = $dbh->last_insert_id;

    # Insert an alias for the route
    $dbh->do( "INSERT INTO post_aliases (route_id, alias) VALUES (?,?)",
        undef, $route_id, '/blog/old-name' );

    return {
        post_id  => $post_id,
        tag_id   => $tag_id,
        route_id => $route_id,
    };
}

my $data = _seed_db();

subtest 'tags — populated database' => sub {
    my @tags = sort( Trog::SQLite::TagIndex::tags() );
    is_deeply( \@tags, [qw{blog news}], 'all inserted tags returned' );
};

subtest 'posts_for_tags — exact tag match' => sub {
    my @ids = Trog::SQLite::TagIndex::posts_for_tags('blog');
    is( scalar @ids, 1,        'one post for tag blog' );
    is( $ids[0],     'uuid-1', 'correct post UUID returned' );
};

subtest 'posts_for_tags — no filter returns all posts' => sub {
    my @ids = Trog::SQLite::TagIndex::posts_for_tags();
    is( scalar @ids, 1, 'post returned when no tag filter applied' );
};

subtest 'posts_for_tags — missing tag returns empty' => sub {
    my @ids = Trog::SQLite::TagIndex::posts_for_tags('nonexistent');
    is( scalar @ids, 0, 'no posts for unknown tag' );
};

subtest 'routes — populated database' => sub {
    my %routes = Trog::SQLite::TagIndex::routes();
    ok( exists $routes{'/blog/post-1'}, 'route key exists' );
    is( $routes{'/blog/post-1'}{callback}, 'Trog::Routes::HTML::blog', 'callback correct' );
    is( $routes{'/blog/post-1'}{method},   'GET',                       'method correct' );
};

subtest 'aliases — populated database' => sub {
    my %aliases = Trog::SQLite::TagIndex::aliases();
    ok( exists $aliases{'/blog/old-name'}, 'alias key exists' );
    is( $aliases{'/blog/old-name'}, '/blog/post-1', 'alias resolves to actual route' );
};

done_testing;
