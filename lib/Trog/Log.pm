package Trog::Log;

# ABSTRACT: Logging for tCMS, to a rotated file, the screen and the log database

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use POSIX qw{strftime};
use Module::Runtime();
use Log::Dispatch;
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
by design, that being the point of it.  The level subroutines do not need
log_init() to have run: before it, they write to stderr.  The server calls
log_init() for each request, and CLI tools have to call it for themselves.

=head1 VARIABLES

=over 4

=item $Trog::Log::user

Who the current request belongs to.  Interpolated into every log line, so that
the request log can be grepped by user.  Defaults to 'nobody'.

=item $Trog::Log::ip

Where the current request came from, same deal.  Defaults to '0.0.0.0'.

=back

=head1 FUNCTIONS

=head2 log_init($logname, $level, $loggers) = BOOL

Build the logger.  Must be called before anything tries to log.

$logname is the path to the log file; its directory is also where the metrics
database gets put.  $level is a Log::Dispatch level, generally 'info' or
'debug'.

$loggers names more Log::Dispatch outputs to add, by class, and each gets
C<min_level> and C<log_dir> as tPSGI gives them.  The server passes the
C<loggers> of tpsgi.ini, so that one setting sends the lines of tPSGI and of
tCMS to the same places.  See Trog::Log::Syslog.

It also sets the request ID to C<INIT>; see uuid().

=over 4

=item logname - Str - the path of the log file

=item level - Str - a Log::Dispatch level, such as C<info> or C<debug>

=item loggers - ArrayRef[Str]|undef - the classes of more outputs; optional

=back

Returns 1.

Dies when $logname or $level is false.  It also dies when a class in $loggers
does not load, or when the log database cannot be opened.

    log_init( "$tpsgi->{log_dir}/tpsgi.log", $tpsgi->{verbose} ? 'debug' : 'info', $tpsgi->{loggers} );

=cut

sub log_init {
    my ( $LOGNAME, $level, $loggers ) = @_;

    die "Cannot initialize logs without log name and log level" unless $LOGNAME && $level;

    $LEVEL  = $level;
    $LOGDIR = dirname($LOGNAME);

    # By default only log requests & warnings.
    # Otherwise emit debug messages.
    my $rotate = Log::Dispatch::FileRotate->new(
        name      => 'tcms',
        filename  => $LOGNAME,
        min_level => $LEVEL,
        'mode'    => 'append',
        size      => 10_485_760,    # 10 MiB
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
        dbh       => dbh(),
    );

    $log = Log::Dispatch->new();
    $log->add($rotate);
    $log->add($screen);
    $log->add($dblog);

    foreach my $logger ( @{ $loggers // [] } ) {
        $log->add( Module::Runtime::use_module($logger)->new( min_level => $LEVEL, log_dir => $LOGDIR ) );
    }

    uuid("INIT");
    return 1;
}

#memoize
my $rq;

=head2 dbh() = DBI::db

The handle to the log database, under the log directory, with its schema
applied.  Trog::SQLite caches it, so every call gets the same one.

Returns DBI::db, the handle.

    my $rows = Trog::Log::dbh()->selectall_arrayref( $query, undef, @input );

=cut

sub dbh {
    return Trog::SQLite::dbh( 'schema/log.schema', "$LOGDIR/log.db" );
}

=head2 is_debug() = BOOL

Whether we were initialized at debug level.  Useful for skipping the
construction of an expensive message which would only be thrown away.

Returns Bool, true when the level is C<debug>.  Before log_init() has run, the
level is C<info>, so it returns false.

    $totp->{DEBUG} = 1 if is_debug();

=cut

sub is_debug {
    $LEVEL //= 'info';
    return $LEVEL eq 'debug';
}

=head2 uuid($requestid) = STRING

Get, or set, the request ID stamped onto every log line.

A request ID lets the lines that belong to one request be picked back out of an
interleaved log, and lets Trog::Log::DBI group a request's messages under the
request itself.  Nothing in tCMS sets one per request: log_init() sets it to
C<INIT>, and the server calls log_init() for each request.

=over 4

=item requestid - Str - the new request ID; optional.  A false value does not
change the stored ID.

=back

Returns Str|undef, $requestid when it is defined, else the stored ID.  The
stored ID is undef until something sets it.

    uuid($requestid);
    my $requestid = uuid();

=cut

sub uuid {
    my $requestid = shift;
    $rq = $requestid if $requestid;
    return $requestid // $rq;
}

my sub _log {
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

=head2 DEBUG($msg)

Log a message at the debug level.

Lines are formatted as an ISO8601 timestamp, the level, the request ID, the
originating IP and the user, followed by the message.  Don't change the leading
timestamp -- fail2ban parses these.

FATAL logs and then dies, so it never returns.

All four work before log_init() has run, falling back to stderr.  Logging is
the thing you reach for when something has already gone wrong, so a logger that
dies because it wasn't set up first turns a diagnostic into an outage -- and
plenty of callers legitimately run uninitialized, such as the scripts in bin/
and the test suite.

The same is true of INFO(), WARN() and FATAL().

=over 4

=item msg - Str|undef - the message.  When it is undef, the line says that no
message was passed.

=back

Returns 1 when it writes the line to stderr, and nothing when the logger has
the line.

    DEBUG("Skipping $name: it points outside $root");

=cut

# One path for every level so the uninitialized fallback only exists once.
my sub emit ( $level, $method, $msg ) {
    my $line = _log( $msg, $level );
    return $log->$method($line) if $log;

    warn $line;
    return 1;
}

sub DEBUG { return emit( 'DEBUG', 'debug', shift ) }

=head2 INFO($msg)

Log a message at the info level, as DEBUG() does.

=over 4

=item msg - Str|undef - the message

=back

Returns 1 when it writes the line to stderr, and nothing when the logger has
the line.

    INFO("Guest action '$action' on '$safe' requested by $user");

=cut

sub INFO { return emit( 'INFO', 'info', shift ) }

=head2 WARN($msg)

Log a message at the warning level, as DEBUG() does.

=over 4

=item msg - Str|undef - the message

=back

Returns 1 when it writes the line to stderr, and nothing when the logger has
the line.

    WARN("Datasource '$source' will not load: $@");

=cut

sub WARN { return emit( 'WARN', 'warning', shift ) }

=head2 FATAL($msg)

Log a message at the error level, and then die with the line.  It never
returns.  Before log_init() has run, it dies with the line and writes nothing
else.

=over 4

=item msg - Str|undef - the message

=back

Dies always, with the formatted line as the error.

    FATAL("Could not send email from $from to $email!");

=cut

sub FATAL {
    my $line = _log( shift, 'FATAL' );
    $log->log_and_die( level => 'error', message => $line ) if $log;

    # Still fatal with no logger, or the caller's error handling vanishes.
    die $line;
}

1;
