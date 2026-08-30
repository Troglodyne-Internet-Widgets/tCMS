use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal qw{exception};
use FindBin;

use lib "$FindBin::Bin/../lib";

# --- Stub heavy or absent dependencies before loading the SUT ---
# Order matters: stubs must be in %INC before any require triggers them.
BEGIN {
    $INC{'HTTP/Tiny/UNIX.pm'}           = 1;
    $INC{'File/LibMagic.pm'}            = 1;
    $INC{'Config/Simple.pm'}            = 1;
    $INC{'Log/Dispatch.pm'}             = 1;
    $INC{'Log/Dispatch/DBI.pm'}         = 1;
    $INC{'Log/Dispatch/Screen.pm'}      = 1;
    $INC{'Log/Dispatch/FileRotate.pm'}  = 1;
    $INC{'Trog/Log/DBI.pm'}             = 1;
    $INC{'FindBin/libs.pm'}             = 1;
    $INC{'Imager/QRCode.pm'}            = 1;
    $INC{'Trog/TOTP.pm'}                = 1;
    $INC{'Trog/Auth.pm'}                = 1;
    $INC{'Trog/Config.pm'}              = 1;
    $INC{'Trog/Data.pm'}                = 1;
}

{
    package Config::Simple;
    sub new   { bless {}, shift }
    sub vars  { return {} }
    sub param { return undef }
}
{
    package Trog::Config;
    sub get { return Config::Simple->new() }
}
{
    package Trog::Auth;
    sub username2display   { return $_[0] }
    sub username2classname { return 'user' }
}
{
    package Trog::Data;
    sub new { bless {}, shift }
}
{
    package Trog::Log;
    use Exporter 'import';
    our @EXPORT_OK   = qw{WARN ERROR FATAL INFO DEBUG};
    our %EXPORT_TAGS = ( all => \@EXPORT_OK );
    sub WARN  { }
    sub ERROR { }
    sub FATAL { }
    sub INFO  { }
    sub DEBUG { }
}

require_ok('Trog::Data::SQLite') or BAIL_OUT("Can't load Trog::Data::SQLite");

# Build a minimal fake DBI/DBH/STH chain for tests that don't need real SQLite.
my ( $last_sql, @last_params, @rows_to_return );

{
    package FakeSTH;
    sub execute { my $self = shift; push @last_params, @_; return 1 }
}

{
    package FakeDBH;
    sub do {
        my ( $self, $sql, $attr, @p ) = @_;
        $last_sql = $sql;
        push @last_params, @p;
        return 1;
    }
    sub prepare      { my ( $self, $sql ) = @_; $last_sql = $sql; return bless {}, 'FakeSTH' }
    sub selectcol_arrayref {
        my ( $self, $sql, $opts, @p ) = @_;
        $last_sql = $sql;
        push @last_params, @p;
        return [map { $_->{uuid} } @rows_to_return];
    }
    sub selectall_arrayref {
        my ( $self, $sql, $opts, @p ) = @_;
        $last_sql = $sql;
        push @last_params, @p;
        return [@rows_to_return];
    }
    sub selectrow_array {
        my ( $self, $sql ) = @_;
        $last_sql = $sql;
        return ( scalar @rows_to_return );
    }
}

my $fake_dbh = bless {}, 'FakeDBH';
my $sqlite_mock = Test::MockModule->new('Trog::SQLite');
$sqlite_mock->redefine( dbh => sub { $fake_dbh } );

# Helper: fake Config::Simple-ish object
sub fake_cfg { bless {}, 'Config::Simple' }

# ----------------------------------------------------------------
subtest 'new — inherits from Trog::DataModule' => sub {
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    isa_ok( $obj, 'Trog::Data::SQLite' );
    isa_ok( $obj, 'Trog::DataModule' );
};

subtest 'lang and help return strings' => sub {
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    like( $obj->lang, qr/sql/i, 'lang mentions SQL' );
    like( $obj->help, qr/http/i, 'help is a URL' );
};

# ----------------------------------------------------------------
subtest 'count — delegates to SQL' => sub {
    @rows_to_return = ( { uuid => 'u1' }, { uuid => 'u2' } );
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    my $n   = $obj->count();
    is( $n, 2, 'count equals number of fake rows' );
    like( $last_sql, qr/COUNT/i, 'count() issues a COUNT query' );
};

subtest 'count — returns 0 when no posts' => sub {
    @rows_to_return = ();
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    is( $obj->count(), 0, 'count is 0 for empty store' );
};

# ----------------------------------------------------------------
subtest 'tags — returns list from DB' => sub {
    @rows_to_return = ( { uuid => 'public' }, { uuid => 'news' } );
    my $obj  = Trog::Data::SQLite->new( fake_cfg() );
    my @tags = $obj->tags();
    is( scalar @tags, 2, 'tags returns expected count' );
    like( $last_sql, qr/post_tags/i, 'tags() queries post_tags' );
};

subtest 'tags — empty when no tags' => sub {
    @rows_to_return = ();
    my $obj  = Trog::Data::SQLite->new( fake_cfg() );
    my @tags = $obj->tags();
    is( scalar @tags, 0, 'empty list when no tags' );
};

# ----------------------------------------------------------------
subtest 'routes — returns hash from DB' => sub {
    @rows_to_return = (
        { id => 1, route => '/foo', method => 'GET', callback => 'Trog::Routes::HTML::posts' },
        { id => 2, route => '/bar', method => 'GET', callback => 'Trog::Routes::HTML::posts' },
    );
    my $obj    = Trog::Data::SQLite->new( fake_cfg() );
    my %routes = $obj->routes();
    is( scalar keys %routes, 2, 'routes() returns two entries' );
    ok( exists $routes{'/foo'}, 'route /foo present' );
};

subtest 'routes — empty when no rows' => sub {
    @rows_to_return = ();
    my $obj    = Trog::Data::SQLite->new( fake_cfg() );
    my %routes = $obj->routes();
    is( scalar keys %routes, 0, 'empty routes hash for empty store' );
};

# ----------------------------------------------------------------
subtest 'aliases — returns hash from DB' => sub {
    @rows_to_return = (
        { actual => '/posts/abc', alias => '/posts/my-post' },
    );
    my $obj     = Trog::Data::SQLite->new( fake_cfg() );
    my %aliases = $obj->aliases();
    is( $aliases{'/posts/my-post'}, '/posts/abc', 'alias maps to actual route' );
};

# ----------------------------------------------------------------
subtest 'read — empty when DB returns no UUIDs' => sub {
    @rows_to_return = ();
    my $obj   = Trog::Data::SQLite->new( fake_cfg() );
    my $posts = $obj->read( {} );
    is( ref $posts, 'ARRAY', 'returns arrayref' );
    is( scalar @$posts, 0, 'empty when no matching UUIDs' );
};

subtest 'read — id filter generates WHERE uuid = ?' => sub {
    @last_params    = ();
    @rows_to_return = ();
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    $obj->read( { id => 'test-uuid-123' } );
    like( $last_sql,         qr/uuid\s*=\s*\?/i, 'uuid filter in SQL' );
    is( $last_params[0], 'test-uuid-123', 'UUID passed as param' );
};

subtest 'read — tag filter generates IN subquery' => sub {
    @last_params    = ();
    @rows_to_return = ();
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    $obj->read( { tags => [qw{public news}] } );
    like( $last_sql, qr/post_tags/i, 'tag filter touches post_tags' );
};

subtest 'read — older/newer filters appended' => sub {
    @last_params    = ();
    @rows_to_return = ();
    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    $obj->read( { older => 9999999, newer => 1000000 } );
    like( $last_sql, qr/created\s*[<>]/i, 'time-range filter in SQL' );
};

subtest 'read — JSON decode error skips bad row' => sub {
    @rows_to_return = (
        { uuid => 'u1', data => '{"id":"u1","version":0,"created":1}' },
        { uuid => 'u1', data => 'not-valid-json}' },
    );
    # Patch selectcol_arrayref to return uuid list, selectall_arrayref to return rows
    no warnings 'redefine';
    local *FakeDBH::selectcol_arrayref = sub { return ['u1'] };
    local *FakeDBH::selectall_arrayref = sub { return \@rows_to_return };
    use warnings;

    my $obj   = Trog::Data::SQLite->new( fake_cfg() );
    my $posts = $obj->read( {} );
    is( scalar @$posts, 1, 'bad JSON row is skipped, good row returned' );
};

# ----------------------------------------------------------------
subtest 'write — issues expected SQL statements' => sub {
    my @sqls;
    no warnings 'redefine';
    local *FakeDBH::do = sub {
        my ( $self, $sql, $attr, @p ) = @_;
        push @sqls, $sql;
        return 1;
    };
    use warnings;

    my $obj  = Trog::Data::SQLite->new( fake_cfg() );
    my $post = {
        id         => 'post-uuid-001',
        version    => 0,
        created    => 1000000,
        title      => 'Test Post',
        data       => 'body',
        tags       => [qw{public news}],
        aliases    => ['/posts/post-uuid-001'],
        local_href => '/posts/test-post',
        method     => 'GET',
        callback   => 'Trog::Routes::HTML::posts',
        visibility => 'public',
        user       => 'testuser',
        href       => '',
    };

    $obj->write( [$post] );

    my %seen = map { $_ => 1 } @sqls;
    ok( grep { /INSERT OR REPLACE INTO posts/i } @sqls, 'posts INSERT OR REPLACE issued' );
    ok( grep { /INSERT OR IGNORE INTO post_uuids/i } @sqls, 'post_uuids INSERT OR IGNORE issued' );
    ok( grep { /DELETE FROM post_tags/i } @sqls, 'post_tags cleared before re-insert' );
    ok( grep { /INSERT OR IGNORE INTO post_tags/i } @sqls, 'tags re-inserted' );
    ok( grep { /DELETE FROM routes/i } @sqls, 'old route removed before re-insert' );
    ok( grep { /INSERT INTO routes/i } @sqls, 'route inserted' );
    ok( grep { /INSERT OR IGNORE INTO post_aliases/i } @sqls, 'aliases inserted' );
};

# ----------------------------------------------------------------
subtest 'delete — removes from post_uuids and posts' => sub {
    my @sqls;
    no warnings 'redefine';
    local *FakeDBH::do = sub {
        my ( $self, $sql, @rest ) = @_;
        push @sqls, $sql;
        return 1;
    };
    use warnings;

    my $obj = Trog::Data::SQLite->new( fake_cfg() );
    $obj->delete( { id => 'del-uuid-001' } );

    ok( grep { /DELETE FROM post_uuids/i } @sqls, 'deletes from post_uuids' );
    ok( grep { /DELETE FROM posts/i } @sqls, 'deletes from posts' );
};

subtest 'delete — returns 0 on success' => sub {
    my $obj    = Trog::Data::SQLite->new( fake_cfg() );
    my $result = $obj->delete( { id => 'any-uuid' } );
    is( $result, 0, 'delete returns 0' );
};

done_testing;
