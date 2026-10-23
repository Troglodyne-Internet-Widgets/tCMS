use 5.040;
use re '/aasx';
use warnings;

use Test::More;
use Cwd        ();
use File::Copy ();
use File::Path ();
use File::Temp ();
use FindBin;

use lib "$FindBin::Bin/../lib";

use_ok('Trog::SQLite::TagIndex') or BAIL_OUT("Can't find SUT");

# The index opens schema/ and data/ relative to the cwd, so it gets a root of
# its own with the real schema in it.
my $oldcwd = Cwd::getcwd();
my $root   = File::Temp::tempdir( CLEANUP => 1 );
File::Path::make_path( "$root/schema", "$root/data" );
File::Copy::copy( "$FindBin::Bin/../schema/flatfile.schema", "$root/schema/flatfile.schema" ) or die "Could not copy the schema: $!";
chdir $root                                                                                   or die "Could not chdir to $root: $!";

# A data model holding whatever posts it is given, answering read() and get()
# the way build_index() and build_routes() ask.
package Fake::Data {
    sub new  { my ( $class, @posts ) = @_; return bless( { posts => \@posts }, $class ) }
    sub read { my ($self) = @_; return [ @{ $self->{posts} } ] }
    sub get  { my ($self) = @_; return @{ $self->{posts} } }
}

# One that gets as far as the index, then falls over before the routes.
package Broken::Data {
    our @ISA = ('Fake::Data');
    sub get { die "the data model fell over\n" }
}

sub post {
    my (%over) = @_;
    return {
        id         => 'p-one',
        tags       => [qw{blog public}],
        created    => 1700000000,
        local_href => '/posts/p-one',
        method     => 'GET',
        callback   => 'Trog::Routes::HTML::posts',
        aliases    => [],
        %over,
    };
}

sub index_rows {
    my $rows = Trog::SQLite::TagIndex::_dbh()->selectall_arrayref( 'SELECT id, tag FROM posts ORDER BY id, tag', { Slice => {} } );
    return [ map { "$_->{id}:$_->{tag}" } @$rows ];
}

subtest 'add_post' => sub {
    my $data = Fake::Data->new();

    Trog::SQLite::TagIndex::add_post( post(), $data );
    Trog::SQLite::TagIndex::add_post( post(), $data );
    is_deeply( index_rows(), [qw{p-one:blog p-one:public}], 'saving a post twice indexes its tags once' );

    Trog::SQLite::TagIndex::add_post( post( tags => ['public'] ), $data );
    is_deeply( index_rows(),                                       ['p-one:public'], 'and a tag the edit removed is gone' );
    is_deeply( [ Trog::SQLite::TagIndex::posts_for_tags('blog') ], [],               'so the post no longer turns up under it' );
};

subtest 'rebuild' => sub {
    my $dbh = Trog::SQLite::TagIndex::_dbh();

    # What an index looks like after something other than tCMS changed the
    # posts: a post that is gone, and a route to it.
    Trog::SQLite::TagIndex::add_post( post( id => 'p-gone', local_href => '/posts/p-gone', aliases => ['/gone'] ), Fake::Data->new() );
    $dbh->do('INSERT INTO posts_index (post_id, post_time, tag_id) SELECT post_id, post_time, tag_id FROM posts_index');

    my $data = Fake::Data->new( post( tags => [qw{blog public}] ), post( id => 'p-two', tags => ['public'], local_href => '/posts/p-two' ) );
    Trog::SQLite::TagIndex::rebuild($data);

    is_deeply( index_rows(), [qw{p-one:blog p-one:public p-two:public}], 'the index holds exactly the posts there are, once each' );

    my %routes = Trog::SQLite::TagIndex::routes();
    is_deeply( [ sort keys %routes ],                 [qw{/posts/p-one /posts/p-two}], 'and the routes of those posts only' );
    is_deeply( { Trog::SQLite::TagIndex::aliases() }, {},                              'with the gone post\'s alias gone too' );

    my ($methods) = $dbh->selectrow_array('SELECT COUNT(*) FROM methods');
    ok( $methods, 'the HTTP methods the schema fills are kept' );

    Trog::SQLite::TagIndex::rebuild($data);
    is_deeply( index_rows(), [qw{p-one:blog p-one:public p-two:public}], 'running it again changes nothing' );
};

subtest 'rebuild is one transaction' => sub {
    my $before = index_rows();

    my $broken = Broken::Data->new( post() );
    ok( !eval { Trog::SQLite::TagIndex::rebuild($broken); 1 }, 'a rebuild that fails part way dies' );
    like( $@, qr/fell[ ]over/, 'with the error that stopped it' );
    is_deeply( index_rows(), $before, 'and leaves the index as it was' );
};

chdir $oldcwd;
done_testing();
