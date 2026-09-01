#!/usr/bin/env perl

# Trog::Data::SQLite answers get() with SQL where Trog::DataModule::filter()
# answers it with grep.  The interesting question is not whether the SQL runs,
# it is whether the two agree -- so most of this file writes one corpus into
# both models and asserts they return the same posts for the same query.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal      qw{exception};

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-datamodel-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    # Both models resolve their storage relative to cwd, and Text::Xslate reads
    # $HOME once at load time.  Both have to be settled before anything loads.
    $ENV{HOME} = $ROOT;
    File::Path::make_path("$ROOT/$_") for qw{config schema data/files logs};
    File::Copy::copy( "$REPO/schema/$_", "$ROOT/schema/$_" ) or die $! for qw{flatfile.schema sqlite.schema};
    File::Copy::copy( "$REPO/config/default.cfg", "$ROOT/config/default.cfg" ) or die $!;

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Data::SQLite')   or BAIL_OUT("Can't find SUT");
require_ok('Trog::Data::FlatFile') or BAIL_OUT("Can't find the model to compare against");
require Trog::Config;
require Trog::SQLite::TagIndex;

# _fixup() decorates every post with the author's display name and avatar class,
# which would otherwise drag the auth database in.  Not what is under test.
my $auth = Test::MockModule->new('Trog::Auth');
$auth->redefine( username2display   => sub { return "Display $_[0]" } );
$auth->redefine( username2classname => sub { return "class-$_[0]" } );

my $conf   = Trog::Config::get();
my $sqlite = Trog::Data::SQLite->new($conf);
my $flat   = Trog::Data::FlatFile->new($conf);

#--------------------------------------------------------------------------
# One corpus, written to both.
#--------------------------------------------------------------------------

my $t = 1700000000;

sub post {
    my (%o) = @_;
    return {
        title      => 'Untitled',
        data       => 'nothing in particular',
        user       => 'bob',
        author     => 'bob',
        visibility => 'public',
        created    => $t++,
        version    => 0,
        form       => 'blog.tx',
        %o,

        # _process() pushes visibility into tags, so the corpus does too.
        tags => [ @{ $o{tags} // ['blog'] }, $o{visibility} // 'public' ],
    };
}

my @corpus = (
    post( id => 'p-public',   title => 'The Quick Brown Fox', data => 'jumps over the lazy dog',                tags       => [qw{blog topbar}] ),
    post( id => 'p-private',  title => 'Secret Plans',        data => 'the mice will never know',               visibility => 'private' ),
    post( id => 'p-unlisted', title => 'Unlisted Thing',      data => 'findable but not listed',                visibility => 'unlisted' ),
    post( id => 'p-ann',      title => 'By Ann',              data => 'ann wrote this one',                     user       => 'ann', author => 'ann' ),
    post( id => 'p-micro',    title => 'A Microblog',         data => 'short and sweet',                        form       => 'microblog.tx' ),
    post( id => 'p-series',   title => 'A Series',            data => 'holds other posts',                      form       => 'series.tx', aclname => 'aseries', tags => [qw{series topbar}] ),
    post( id => 'p-slides',   title => 'A Deck',              data => [ 'slide one about foxes', 'slide two' ], form       => 'presentation.tx' ),

    # What _process() leaves behind for a private post with an acl: the acl is
    # folded into tags and the acls field is deleted outright.
    post( id => 'p-acl', title => 'Members Only', data => 'for the club', visibility => 'private', tags => [qw{blog aseries}] ),
);

# A second version of one post, so that version handling is exercised.
push( @corpus, post( id => 'p-public', title => 'The Quick Brown Fox (revised)', data => 'jumps over the lazy dog, again', tags => [qw{blog topbar}], version => 1, created => $t++ ) );

foreach my $p (@corpus) {

    # Separate copies: FlatFile's index build decorates what it is handed.
    $sqlite->write( [ { %$p, tags => [ @{ $p->{tags} } ] } ] );
    $flat->write( [ { %$p, tags => [ @{ $p->{tags} } ] } ] );
}

# FlatFile snapshots the tag list at load time and filters queries against it in
# place, so a tag it has not seen is deleted from the query rather than simply
# unmatched.  Refresh it, or the comparison measures that bug instead.
{
    no warnings qw{once};
    @Trog::Data::FlatFile::tags         = Trog::SQLite::TagIndex::tags();
    %Trog::Data::FlatFile::posts_by_tag = ();
}

sub ids_of {
    my (@posts) = @_;
    return [ sort map { "$_->{id}\@$_->{version}" } @posts ];
}

#--------------------------------------------------------------------------

subtest 'the two models answer the same questions the same way' => sub {
    my @queries = (
        [ 'everything an admin can see'  => { limit => 0, acls    => ['admin'] } ],
        [ 'everything a visitor can see' => { limit => 0, acls    => ['public'] } ],
        [ 'a visitor plus unlisted'      => { limit => 0, acls    => [qw{public unlisted}] } ],
        [ 'no acls at all'               => { limit => 0, acls    => [] } ],
        [ 'one tag'                      => { limit => 0, acls    => ['admin'], tags         => ['topbar'] } ],
        [ 'several tags'                 => { limit => 0, acls    => ['admin'], tags         => [qw{topbar series}] } ],
        [ 'a tag nothing has'            => { limit => 0, acls    => ['admin'], tags         => ['nonesuch'] } ],
        [ 'excluding a tag'              => { limit => 0, acls    => ['admin'], exclude_tags => ['topbar'] } ],
        [ 'tags and exclude together'    => { limit => 0, acls    => ['admin'], tags         => ['blog'], exclude_tags => ['topbar'] } ],
        [ 'by form'                      => { limit => 0, acls    => ['admin'], form         => 'microblog.tx' } ],
        [ 'by a form nothing has'        => { limit => 0, acls    => ['admin'], form         => 'nonesuch.tx' } ],
        [ 'by author'                    => { limit => 0, acls    => ['admin'], author       => 'ann' } ],
        [ 'by id'                        => { limit => 0, id      => 'p-series' } ],
        [ 'by an id nothing has'         => { limit => 0, id      => 'p-nonesuch' } ],
        [ 'by title'                     => { limit => 0, title   => 'A Deck' } ],
        [ 'by aclname'                   => { limit => 0, aclname => 'aseries' } ],
        [ 'by acl membership'            => { limit => 0, acls    => ['aseries'] } ],
        [ 'older than'                   => { limit => 0, acls    => ['admin'],  older   => $corpus[4]{created} } ],
        [ 'newer than'                   => { limit => 0, acls    => ['admin'],  newer   => $corpus[4]{created} } ],
        [ 'a specific version'           => { limit => 0, id      => 'p-public', version => 0 } ],
        [ 'the other version'            => { limit => 0, id      => 'p-public', version => 1 } ],
    );

    foreach my $case (@queries) {
        my ( $name, $query ) = @$case;
        my $want = ids_of( $flat->get(%$query) );
        my $got  = ids_of( $sqlite->get(%$query) );
        is_deeply( $got, $want, $name ) or diag("flatfile: @$want\nsqlite:   @$got");
    }
};

subtest 'the id query really does return one post' => sub {

    # Guards the comparison above: two empty lists are also "the same".
    my @found = $sqlite->get( limit => 0, id => 'p-series' );
    is( scalar(@found),  1,           'exactly one' );
    is( $found[0]{id},   'p-series',  'and the right one' );
    is( $found[0]{form}, 'series.tx', 'decoded whole, not just its id' );

    my @admin = $sqlite->get( limit => 0, acls => ['admin'] );
    is( scalar(@admin), 8, 'an admin sees every post, each at one version' );

    # public, ann, micro, series and slides.  Not the private one, not the
    # members-only one, and not the unlisted one -- unlisted is its own tag, and
    # a caller only holding 'public' does not hold it.
    my @public = $sqlite->get( limit => 0, acls => ['public'] );
    is( scalar(@public), 5, 'a visitor sees only what is tagged public' );

    my @plus = $sqlite->get( limit => 0, acls => [qw{public unlisted}] );
    is( scalar(@plus), 6, 'and the unlisted one once they hold that too' );
};

subtest 'versions' => sub {
    my ($latest) = $sqlite->get( limit => 0, id => 'p-public' );
    is( $latest->{version},     1,                               'the newest version is the one you get' );
    is( $latest->{title},       'The Quick Brown Fox (revised)', 'with its own content' );
    is( $latest->{version_max}, 1,                               'version_max is the newest' );
    is( $latest->{created},     $corpus[0]{created},             'created is the post birthday, not the revision' );
    is( $latest->{modified},    $corpus[-1]{created},            'modified is the revision' );

    my ($first) = $sqlite->get( limit => 0, id => 'p-public', version => 0 );
    is( $first->{title},       'The Quick Brown Fox', 'an older version can still be asked for' );
    is( $first->{version_max}, 1,                     'and knows a newer one exists' );

    # raw is the history as stored, which is what bin/migrate*.pl reads.
    my @raw = $sqlite->get( raw => 1, limit => 0 );
    is( scalar(@raw), 9, 'raw gets every version of everything' );
    ok( !exists $raw[0]{version_max}, 'and does not decorate them' );
};

subtest 'the like filter goes through FTS5' => sub {

    # The substring semantics filter() had, which is why the index is built with
    # the trigram tokenizer.
    my @cases = (
        [ 'quick'        => ['p-public'] ],
        [ 'QUICK'        => ['p-public'] ],     # case insensitive
        [ 'own fox'      => ['p-public'] ],     # matches inside words
        [ 'lazy dog'     => ['p-public'] ],
        [ 'Secret Plans' => ['p-private'] ],    # title as well as body
        [ 'foxes'        => ['p-slides'] ],     # data stored as an array
        [ 'nonesuch'     => [] ],
    );

    foreach my $case (@cases) {
        my ( $term, $want ) = @$case;
        my @got = map { $_->{id} } $sqlite->get( limit => 0, acls => ['admin'], like => $term );
        is_deeply( [ sort @got ], [ sort @$want ], "like '$term'" );
    }

    # FTS5 query syntax in the search box is text to search for, not syntax.
    foreach my $hostile ( 'AND', '"', 'foo OR bar', '*', 'NEAR(a b)', "it's" ) {
        is( exception { $sqlite->get( limit => 0, acls => ['admin'], like => $hostile ) }, undef, "'$hostile' is a search term, not a query" );
    }

    # Trigram cannot index below three characters, so those take the LIKE path.
    my @short = map { $_->{id} } $sqlite->get( limit => 0, acls => ['admin'], like => 'ox' );
    is_deeply( [ sort @short ], [ sort qw{p-public p-slides} ], 'a two character term still matches, via LIKE' );

    # And LIKE's own wildcards are literal there too.
    is_deeply( [ $sqlite->get( limit => 0, acls => ['admin'], like => '%' ) ], [], "'%' matches nothing rather than everything" );
};

subtest 'ordering and pagination' => sub {

    # By created, which after the version rollup is the post's birthday -- the
    # same field the caller gets back, and the same one older/newer filter on.
    my @all     = $sqlite->get( limit => 0, acls => ['admin'] );
    my @created = map { $_->{created} } @all;
    is_deeply( \@created, [ reverse sort { $a <=> $b } @created ], 'newest first' );

    my @page1 = $sqlite->get( limit => 3, page => 1, acls => ['admin'] );
    my @page2 = $sqlite->get( limit => 3, page => 2, acls => ['admin'] );
    is( scalar(@page1), 3, 'a page is a page long' );
    is( scalar(@page2), 3, 'and so is the next one' );

    my %seen = map { $_->{id} => 1 } @page1;
    is( scalar( grep { $seen{ $_->{id} } } @page2 ), 0, 'and they do not overlap' );

    my @limited = $sqlite->get( limit => 2, acls => ['admin'] );
    is( scalar(@limited), 2, 'a limit with no page still limits' );
};

subtest 'count, tags and delete' => sub {
    is( $sqlite->count(), 8, 'count counts posts, not versions' );

    my @tags = $sqlite->tags();
    ok( scalar( grep { $_ eq 'topbar' } @tags ),    'tags lists a tag in use' );
    ok( scalar( grep { $_ eq 'aseries' } @tags ),   'including an acl folded into tags' );
    ok( !scalar( grep { $_ eq 'nonesuch' } @tags ), 'and nothing else' );

    $sqlite->delete( { id => 'p-micro' } );
    is( $sqlite->count(), 7, 'delete removes the post' );

    # The version bookkeeping has to let go of it too, or the next post to
    # reuse that id inherits a pointer to a row that is gone.
    my $vdbh = Trog::SQLite::dbh( undef, 'data/posts.sqlite' );
    my ($stale) = $vdbh->selectrow_array(q{SELECT COUNT(*) FROM post_versions WHERE uuid = 'p-micro'});
    is( $stale, 0, 'and its version bookkeeping' );
    is_deeply( [ $sqlite->get( limit => 0, id => 'p-micro' ) ], [], 'and it cannot be fetched' );

    # The schema's triggers own this, not the Perl.
    my $dbh = Trog::SQLite::dbh( undef, 'data/posts.sqlite' );
    my ($orphans) = $dbh->selectrow_array('SELECT COUNT(*) FROM post_tags WHERE post_id NOT IN (SELECT id FROM posts)');
    is( $orphans, 0, 'the tag index went with it' );

    my ($ghosts) = $dbh->selectrow_array(q{SELECT COUNT(*) FROM posts_fts WHERE posts_fts MATCH '"short and sweet"'});
    is( $ghosts, 0, 'and so did the search index' );
};

subtest 'writing' => sub {
    my $before = $sqlite->count();

    $sqlite->write( [ post( id => 'p-new', title => 'Brand New' ) ] );
    is( $sqlite->count(), $before + 1, 'a new post lands' );

    # (uuid, version) is unique, which is what stops two workers writing the
    # same version rather than one of them silently winning.
    # DBI's PrintError would announce the constraint failure on stderr as well,
    # and we are provoking it on purpose.
    my $clash = do {
        local $SIG{__WARN__} = sub { };
        exception { $sqlite->write( [ post( id => 'p-new', title => 'Clashing' ) ] ) };
    };
    like( $clash, qr/Could not write post 'p-new'/, 'the same version twice is refused, loudly' );

    is( exception { $sqlite->write( [ post( id => 'p-new', title => 'Second Version', version => 1 ) ] ) }, undef, 'a new version is not' );
    my ($now) = $sqlite->get( limit => 0, id => 'p-new' );
    is( $now->{title}, 'Second Version', 'and wins' );

    like( exception { $sqlite->write( [ { title => 'No Id' } ] ) }, qr/no id/i, 'a post with no id is refused' );

    # These are computed per query out of the version history; storing them
    # would bake one query's answer into the post forever.
    my $dbh = Trog::SQLite::dbh( undef, 'data/posts.sqlite' );
    my ($blob) = $dbh->selectrow_array("SELECT post_data FROM posts WHERE uuid='p-new' AND version=1");
    unlike( $blob, qr/version_max|"modified"|display_name|user_class/, 'derived fields are not stored' );
};

subtest 'indexing a custom field' => sub {

    # index_fields() logs what it did, and with no logger configured that comes
    # out on stderr with a Carp::Always trace behind it.
    local $SIG{__WARN__} = sub { };

    my $dbh = Trog::SQLite::dbh( undef, 'data/posts.sqlite' );

    # xinfo, because table_info does not list generated columns.
    my $columns = sub {
        return { map { $_->{name} => 1 } @{ $dbh->selectall_arrayref( 'PRAGMA table_xinfo(posts)', { Slice => {} } ) } };
    };
    my $indexes = sub {
        return { map { $_->{name} => 1 } @{ $dbh->selectall_arrayref( "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='posts'", { Slice => {} } ) } };
    };

    ok( !$columns->()->{cook_time}, 'the field has no column to start with' );

    $sqlite->index_fields(qw{cook_time});
    ok( $columns->()->{cook_time},                'indexing a field gives it a column' );
    ok( $indexes->()->{'posts_custom_cook_time'}, 'and an index' );

    # The column is generated out of the blob, so it is populated for posts that
    # were written long before anybody asked for it.
    $sqlite->write( [ post( id => 'p-recipe', title => 'Soup', cook_time => '45 minutes' ) ] );
    my ($value) = $dbh->selectrow_array(q{SELECT cook_time FROM posts WHERE uuid = 'p-recipe'});
    is( $value, '45 minutes', 'and the column reads the value straight out of the post' );

    # And SQLite actually uses it, which is the entire point.
    my ($plan) = map { $_->{detail} } @{ $dbh->selectall_arrayref( q{EXPLAIN QUERY PLAN SELECT id FROM posts WHERE cook_time = '45 minutes'}, { Slice => {} } ) };
    like( $plan, qr/USING INDEX posts_custom_cook_time/, 'and searches it rather than every post' );

    is( exception { $sqlite->index_fields(qw{cook_time}) }, undef, 'asking twice is not an error' );

    # Reconciling against a set that no longer names it.
    $sqlite->index_fields(qw{serves});
    ok( !$indexes->()->{'posts_custom_cook_time'}, 'a field left out loses its index' );
    ok( $columns->()->{cook_time},                 'but keeps its column, which costs nothing' );
    ok( $indexes->()->{'posts_custom_serves'},     'and the newly named one gains an index' );

    # Only ever ours.
    $sqlite->index_fields();
    ok( $indexes->()->{posts_created}, "the schema's own indexes are left alone" );
    ok( $indexes->()->{posts_title},   'all of them' );

    # The name reaches SQLite as an identifier and a JSON path, neither of which
    # can be bound as a parameter, so it is checked here and not merely upstream.
    foreach my $hostile ( 'cook_time; DROP TABLE posts', "cook'time", 'Cook_Time', '1st_course', 'a' x 40, '', 'post_data' ) {
        is( exception { $sqlite->index_fields($hostile) }, undef, "'$hostile' is refused rather than run" );
    }
    ok( $indexes->()->{posts_created},             'and the table is still there afterwards' );
    ok( !$indexes->()->{'posts_custom_post_data'}, 'and a schema column did not pick up an index of its own' );
};

done_testing();
