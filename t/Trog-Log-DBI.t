#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal   qw{exception};
use Capture::Tiny qw{capture_stderr};
use File::Temp    qw{tempdir};
use FindBin;

use FindBin::libs;

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
    my $why = 'Could not record request r-2 in the metrics database: ';
    like( $stderr, qr/\Q$why\E\N*refused[ ]for[ ]the[ ]test/, 'and says why on stderr' );
};

subtest 'a message waits for the line of its request' => sub {
    is( $output->log_message( message => "2026-09-29T12:00:01Z [WARN]: RequestId r-3 From 192.0.2.1 |nobody| a thing went sideways\n" ), 1, 'the message is buffered' );
    my ($early) = $dbh->selectrow_array("SELECT count(*) FROM messages WHERE uuid='r-3'");
    is( $early, 0, 'and not written before its request' );

    ok( $output->log_message( message => $line =~ s/r-1/r-3/r ), 'the request line is written' );
    my $messages = $dbh->selectcol_arrayref("SELECT message FROM messages WHERE uuid='r-3'");
    is_deeply( $messages, ['a thing went sideways'], 'and the message with it' );
};

subtest 'a line that names no request is dropped' => sub {
    is( $output->log_message( message => "not a log line at all\n" ), undef, 'text that is not a log line' );
    is( $output->log_message( message => $line =~ s/r-1/r|4/r ),                  undef, 'a request id with a pipe in it' );
    is( $output->log_message( message => $line =~ s/192\.0\.2\.1/192.0.2.1|x/r ), undef, 'an address with a pipe in it' );
    my ($count) = $dbh->selectrow_array("SELECT count(*) FROM all_requests WHERE uuid LIKE 'r|%' OR ip_address LIKE '%|%'");
    is( $count, 0, 'and none of them is a row' );
};

done_testing();
