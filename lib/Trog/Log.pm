package Trog::Log;

use strict;
use warnings;

use POSIX qw{strftime};
use Log::Dispatch;
use Log::Dispatch::Screen;
use Log::Dispatch::FileRotate;

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
our $log = Log::Dispatch->new();
$log->add($rotate);
$log->add($screen);

uuid("INIT");
DEBUG("If you see this message, you are running in DEBUG mode.  Turn off WWW_VERBOSE env var if you are running in production.");
uuid("BEGIN");

#memoize
my $rq;

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
}

sub _log {
    my ( $msg, $level ) = @_;

    my $tstamp = strftime "%a %b %d %T %Y", localtime;
    my $uuid   = uuid();

    return "[$level]: <$tstamp> {Request $uuid} |$Trog::Log::user| $msg\n";
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
