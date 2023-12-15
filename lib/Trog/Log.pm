package Trog::Log;

use strict;
use warnings;

use POSIX qw{strftime};
use Log::Dispatch;
use Log::Dispatch::DBI;
use Log::Dispatch::Screen;
use Log::Dispatch::FileRotate;

use Trog::SQLite;
use Trog::Log::DBI;

use Exporter 'import';
our @EXPORT_OK   = qw{is_debug INFO DEBUG WARN FATAL};
our %EXPORT_TAGS = ( 'all' => \@EXPORT_OK );

my $LOGNAME = -d '/var/log' ? '/var/log/www/tcms.log' : '~/.tcms/tcms.log';
$LOGNAME = $ENV{CUSTOM_LOG} if $ENV{CUSTOM_LOG};

my $LEVEL = $ENV{WWW_VERBOSE} ? 'debug' : 'info';

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
    name => 'dbi',
    min_level => $LEVEL,
    dbh  => _dbh(),
);

our $log = Log::Dispatch->new();
$log->add($rotate);
$log->add($screen);
$log->add($dblog);

uuid("INIT");
DEBUG("If you see this message, you are running in DEBUG mode.  Turn off WWW_VERBOSE env var if you are running in production.");
uuid("BEGIN");

#memoize
my $rq;

sub _dbh {
	return Trog::SQLite::dbh( 'schema/log.schema', "data/log.db" );
}

sub is_debug {
    return $LEVEL eq 'debug';
}

sub uuid {
    my $requestid = shift;
    $rq = $requestid if $requestid;
    $requestid //= return $rq;
}

#XXX make perl -c quit whining
BEGIN {
    our $user;
    $Trog::Log::user = 'nobody';
    $Trog::Log::ip   = '0.0.0.0';
}

sub _log {
    my ( $msg, $level ) = @_;

    $msg //= "No message passed.  This is almost certainly a bug. ";

    #XXX Log lines must start as an ISO8601 date, anything else breaks fail2ban's beautiful mind
    my $tstamp = strftime "%Y-%m-%dT%H:%M:%SZ", gmtime;
    my $uuid   = uuid();

    return "$tstamp [$level]: RequestId $uuid From $Trog::Log::ip |$Trog::Log::user| $msg\n";
}

sub DEBUG {
    $log->debug( _log( shift, 'DEBUG' ) );
}

sub INFO {
    $log->info( _log( shift, 'INFO' ) );
}

sub WARN {
    $log->warning( _log( shift, 'WARN' ) );
}

sub FATAL {
    $log->log_and_die( level => 'error', message => _log( shift, 'FATAL' ) );
}

1;
