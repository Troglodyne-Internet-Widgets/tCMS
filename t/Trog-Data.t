use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule;
use Config::Simple ();
use File::Temp     ();
use Path::Tiny     ();

use FindBin::libs;

use_ok('Trog::Data') or BAIL_OUT("Can't find SUT");

# Ahead of the tests, which point its database somewhere else: model() requires
# it, and a first load would put the real path back.
use Trog::Data::SQLite ();

no warnings qw{once};

sub config_for {
    my ($model) = @_;
    my $conf = Config::Simple->new( syntax => 'ini' );
    $conf->param( 'general.data_model', $model );
    return $conf;
}

subtest 'model' => sub {
    my $dir = Path::Tiny->new( File::Temp::tempdir( CLEANUP => 1 ) );
    local $Trog::Data::flatfile_store = "$dir/files";
    local $Trog::Data::SQLite::dbname = "$dir/posts.sqlite";

    my @warned;
    my $mock = Test::MockModule->new('Trog::Data');
    $mock->redefine( WARN => sub { push( @warned, @_ ) } );

    is( Trog::Data::model( config_for('FlatFile') ), 'FlatFile', 'FlatFile is served as configured' );
    is( Trog::Data::model( config_for('SQLite') ),   'SQLite',   'a new site with no flat file store gets SQLite' );

    $dir->child('files')->mkpath;
    is( Trog::Data::model( config_for('SQLite') ), 'SQLite', 'and so does one whose store is empty' );
    is( scalar(@warned),                           0,        'neither of which is worth a warning' );

    $dir->child( 'files', 'a-post' )->spew('{}');
    $dir->child( 'files', 'another' )->spew('{}');
    is( Trog::Data::model( config_for('SQLite') ), 'FlatFile', 'a site with flat file posts and no database keeps serving its posts' );
    is( scalar(@warned),                           1,          'with a warning' );
    like( $warned[0] // '', qr{holds[ ]2[ ]post\(s\)\N*bin/migrate\.pl}, 'saying how many, and how to move them' );

    $dir->child('posts.sqlite')->touch;
    @warned = ();
    is( Trog::Data::model( config_for('SQLite') ), 'SQLite', 'once the migration has written the database, it is served' );
    is( scalar(@warned),                           0,        'without a warning' );

    is( Trog::Data::model( config_for('FlatFile') ), 'FlatFile', 'and a site configured for FlatFile is never moved' );
};

done_testing();
