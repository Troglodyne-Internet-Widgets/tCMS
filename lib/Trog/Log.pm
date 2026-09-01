package Trog::Log;

use v5.36;
use re '/aa';

use POSIX qw{strftime};
use Log::Dispatch;
use Log::Dispatch::DBI;
use Log::Dispatch::Screen;
use Log::Dispatch::FileRotate;
use File::Basename qw{dirname};

use Trog::SQLite;
use Trog::Log::DBI;

use Exporter 'import';
our @EXPORT_OK   = qw{log_init is_debug INFO DEBUG WARN FATAL};
our %EXPORT_TAGS = ( 'all' => \@EXPORT_OK );

my ( $LEVEL, $LOGDIR );
our ( $log, $user );

$Trog::Log::user = 'nobody';
$Trog::Log::ip   = '0.0.0.0';

=head1 Trog::Log

Logging for tCMS.

Everything goes through one Log::Dispatch object with three outputs: a rotating
file for the operator, the screen for anything at error level or above (which
is what ends up in the webserver's own log), and Trog::Log::DBI, which is what
Trog::Log::Metrics later reads its time series out of.

Import the level subroutines you need, or C<:all>:

    use Trog::Log qw{:all};
    INFO("something happened");

=head1 Termination Conditions

log_init() dies if it isn't told where to log and at what level.  FATAL() dies
by design, that being the point of it.  Note that the level subroutines will
themselves die on an undefined $log, so log_init() has to have run first --
which the server does per-worker, and CLI tools have to do for themselves.

=head1 VARIABLES

=over 4

=item $Trog::Log::user

Who the current request belongs to.  Interpolated into every log line, so that
the request log can be grepped by user.  Defaults to 'nobody'.

=item $Trog::Log::ip

Where the current request came from, same deal.  Defaults to '0.0.0.0'.

=back

=head1 FUNCTIONS

=head2 log_init(STRING logname, STRING level) = BOOL

Build the logger.  Must be called before anything tries to log.

$logname is the path to the log file; its directory is also where the metrics
database gets put.  $level is a Log::Dispatch level, generally 'info' or
'debug'.

Returns 1.

=cut

sub log_init {
    my ( $LOGNAME, $LEVEL ) = @_;

    die "Cannot initialize logs without log name and log level" unless $LOGNAME && $LEVEL;

    $LOGNAME //= 'logs/tcms.log';
    $LEVEL   //= 'info';

    $LOGDIR = dirname($LOGNAME);

    # By default only log requests & warnings.
    # Otherwise emit debug messages.
    my $rotate = Log::Dispatch::FileRotate->new(
        name      => 'tcms',
        filename  => $LOGNAME,
        min_level => $LEVEL,
        'mode'    => 'append',
        size      => 10 * 1024 * 1024,
        max       => 6,
    );

    # Only send fatal events/errors to prod-web.log
    my $screen = Log::Dispatch::Screen->new(
        name      => 'screen',
        min_level => 'error',
    );

    # Send things like requests in to the stats log
    my $dblog = Trog::Log::DBI->new(
        name      => 'dbi',
        min_level => $LEVEL,
        dbh       => _dbh(),
    );

    $log = Log::Dispatch->new();
    $log->add($rotate);
    $log->add($screen);
    $log->add($dblog);

    uuid("INIT");
    return 1;
}

#memoize
my $rq;

sub _dbh {
    return Trog::SQLite::dbh( 'schema/log.schema', "$LOGDIR/log.db" );
}

=head2 is_debug() = BOOL

Whether we were initialized at debug level.  Useful for skipping the
construction of an expensive message which would only be thrown away.

=cut

sub is_debug {
    $LEVEL //= 'info';
    return $LEVEL eq 'debug';
}

=head2 uuid([STRING requestid]) = STRING

Get, or set, the request ID stamped onto every log line.

The server sets this once per request so that the lines belonging to it can be
picked back out of an interleaved log, and so that Trog::Log::DBI can group a
request's messages under the request itself.

=cut

sub uuid {
    my $requestid = shift;
    $rq = $requestid if $requestid;
    $requestid //= return $rq;
}

sub _log {
    my ( $msg, $level ) = @_;

    $msg //= "No message passed.  This is almost certainly a bug. ";

    #XXX Log lines must start as an ISO8601 date, anything else breaks fail2ban's beautiful mind
    my $tstamp = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;

    # Undef until the server stamps one, or log_init() sets INIT.  Anything
    # logged before that still deserves a line rather than an uninitialized
    # value warning glued into the middle of it.
    my $uuid = uuid() // 'NONE';

    return "$tstamp [$level]: RequestId $uuid From $Trog::Log::ip |$Trog::Log::user| $msg\n";
}

=head2 DEBUG(STRING msg), INFO(STRING msg), WARN(STRING msg), FATAL(STRING msg)

Log a message at the named level.

Lines are formatted as an ISO8601 timestamp, the level, the request ID, the
originating IP and the user, followed by the message.  Don't change the leading
timestamp -- fail2ban parses these.

FATAL logs and then dies, so it never returns.

All four work before log_init() has run, falling back to stderr.  Logging is
the thing you reach for when something has already gone wrong, so a logger that
dies because it wasn't set up first turns a diagnostic into an outage -- and
plenty of callers legitimately run uninitialized, such as the scripts in bin/
and the test suite.

=cut

# One path for every level so the uninitialized fallback only exists once.
sub _emit ( $level, $method, $msg ) {
    my $line = _log( $msg, $level );
    return $log->$method($line) if $log;

    warn $line;
    return 1;
}

sub DEBUG { return _emit( 'DEBUG', 'debug', shift ) }

sub INFO { return _emit( 'INFO', 'info', shift ) }

sub WARN { return _emit( 'WARN', 'warning', shift ) }

sub FATAL {
    my $line = _log( shift, 'FATAL' );
    $log->log_and_die( level => 'error', message => $line ) if $log;

    # Still fatal with no logger, or the caller's error handling vanishes.
    die $line;
}

1;
