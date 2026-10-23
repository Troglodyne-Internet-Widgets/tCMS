use 5.040;
use re '/aasx';
use warnings;

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stderr};
use File::Temp    qw{tempdir};
use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::SQLite;

require_ok('Trog::Log::DBI') or BAIL_OUT("Can't find SUT");

# The metrics database the way Trog::Log opens it, in a directory of its own.
my $dir    = tempdir( CLEANUP => 1 );
my $dbh    = Trog::SQLite::dbh( "$FindBin::Bin/../schema/log.schema", "$dir/log.db" );
my $output = Trog::Log::DBI->new( name => 'dbi', min_level => 'info', dbh => $dbh );

my $line = "2026-09-29T12:00:00Z [INFO]: RequestId r-1 From 192.0.2.1 |nobody| GET 200 512 /posts\n";

subtest 'a request line is a row' => sub {
    ok( $output->log_message( message => $line ), 'the write reports success' );
    my ($count) = $dbh->selectrow_array("SELECT count(*) FROM all_requests WHERE uuid='r-1'");
    is( $count, 1, 'and the request is in all_requests' );
};

# The handle raises on every error, and log_message runs inside every log
# call, so a refused write must not take the caller down with it.
subtest 'a write the database refuses is a warning, not a die' => sub {
    $dbh->do("CREATE TEMP TRIGGER refuse_request BEFORE INSERT ON requests BEGIN SELECT RAISE(ABORT, 'refused for the test'); END");

    my ( $res, $died );
    my $stderr = capture_stderr {
        $died = exception { $res = $output->log_message( message => $line =~ s/r-1/r-2/r ) };
    };
    $dbh->do("DROP TRIGGER temp.refuse_request");

    is( $died, undef, 'the caller of the log does not die' );
    is( $res,  undef, 'the write reports that it failed' );
    like( $stderr, qr/Could[ ]not[ ]record[ ]request[ ]r-2[ ]in[ ]the[ ]metrics[ ]database:[ ]\N*refused[ ]for[ ]the[ ]test/, 'and says why on stderr' );
};

done_testing();
