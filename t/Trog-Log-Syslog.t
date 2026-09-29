use strict;
use warnings;

use Test::More;
use Test::NoWarnings;
use Test::Fatal qw{exception};
use File::Temp  qw{tempdir};
use IO::Socket::UNIX;
use Socket qw{SOCK_DGRAM};
use Log::Dispatch;
use FindBin;

use lib "$FindBin::Bin/../lib";

require_ok('Trog::Log::Syslog') or BAIL_OUT("Can't find SUT");

# A datagram socket in a temporary directory stands in for /dev/log, which is
# a datagram socket too.
my $dir  = tempdir( CLEANUP => 1 );
my $path = "$dir/log";
my $sink = IO::Socket::UNIX->new( Type => SOCK_DGRAM, Local => $path ) or die "Cannot listen on $path: $!";

sub received {
    my $got = '';
    $sink->recv( $got, 65536 );
    return $got;
}

# What tPSGI passes to every logger that its configuration names.
my $output = Trog::Log::Syslog->new( min_level => 'info', log_dir => $dir, socket => $path );
my $log    = Log::Dispatch->new();
$log->add($output);

subtest 'a line arrives as the syslog of this machine reads it' => sub {
    $log->info("2026-09-29T12:00:00Z [INFO]: RequestId x From 192.0.2.1 |nobody| Failed login for user\n");
    my $got = received();

    # daemon is facility 3 and info is severity 6, so the priority is 3*8+6.
    like( $got, qr/^<30>/,                                                                                            'as daemon.info' );
    like( $got, qr/\btcms\[$$\]: /,                                                                                   'tagged with the program name and the pid' );
    like( $got, qr/: 2026-09-29T12:00:00Z \[INFO\]: RequestId x From 192\.0\.2\.1 \|nobody\| Failed login for user$/, 'with the line that the file gets, and no newline' );
};

subtest 'each level keeps its severity' => sub {
    my %severity = ( info => 6, notice => 5, warning => 4, error => 3, critical => 2, alert => 1, emergency => 0 );
    foreach my $level ( sort keys %severity ) {
        $log->log( level => $level, message => "at $level" );
        my $priority = 3 * 8 + $severity{$level};
        like( received(), qr/^<$priority>.*: at $level$/, "$level is severity $severity{$level}" );
    }
};

subtest 'nothing below the level goes out' => sub {
    $log->debug('too quiet');
    $log->info('loud enough');
    like( received(), qr/loud enough$/, 'the debug line was not sent' );
};

subtest 'a syslog that went away does not take the application with it' => sub {
    close($sink);
    unlink($path);

    # The file output still has the line, and a request that fails because
    # its log line did not arrive is worse than a line that did not arrive.
    is( exception { $log->warning('into the void') }, undef, 'logging to a missing socket does not die' );
};

subtest 'log_init adds the loggers that tpsgi.ini names' => sub {
    require Trog::Log;

    # A stand-in, so that this test does not write to the syslog of the
    # machine that runs it.
    {

        package Test::Capture;
        use parent -norequire, qw{Log::Dispatch::Output};
        our ( @lines, %given );

        sub new {
            my ( $class, %p ) = @_;
            %given = %p;
            my $self = bless( {}, $class );
            $self->_basic_init( min_level => $p{min_level} );
            return $self;
        }
        sub log_message { my ( $self, %p ) = @_; push( @lines, $p{message} ); return }
    }
    local $INC{'Test/Capture.pm'} = __FILE__;

    Trog::Log::log_init( "$dir/tcms.log", 'info', ['Test::Capture'] );
    Trog::Log::INFO('through every output');

    no warnings 'once';
    is( $Test::Capture::given{log_dir}, $dir, 'handed the log directory, as tPSGI hands it' );
    like( $Test::Capture::lines[-1], qr/through every output/, 'and given the lines' );

    like( exception { Trog::Log::log_init( "$dir/tcms.log", 'info', ['../../etc/passwd'] ) }, qr/not a module name/, 'a logger that is not a module name is refused' );
};

Test::NoWarnings::had_no_warnings();

done_testing();
