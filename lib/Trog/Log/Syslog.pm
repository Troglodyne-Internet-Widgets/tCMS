package Trog::Log::Syslog;

use v5.36;
use re '/aa';

use parent qw{Log::Dispatch::Output};

use Log::Syslog::Fast qw{:protos :formats};

=head1 Trog::Log::Syslog

A Log::Dispatch output which hands each line to the syslog of the machine, over
its unix socket.  From there journald and rsyslog have it, and whatever they
forward it to.

Name it in the C<loggers> of tpsgi.ini:

    loggers = Trog::Log::Syslog

tPSGI then adds it to its own logger, and TCMS passes the same list to
log_init(), so both write here as well as to the rotated file.

Lines go out as C<daemon>, tagged C<tcms>, at the severity of their level.
Each keeps the timestamp that Trog::Log puts at its front, so a line on a log
collector reads the same as the line in the file.

=head1 Termination Conditions

new() dies when it cannot connect to the socket.  A line that cannot be sent
later is dropped without a word: the file output has it, and a request that
fails because its log line did not arrive is worse than a line that did not
arrive.

=head1 METHODS

=head2 new(%options) = Trog::Log::Syslog

Takes what tPSGI hands every logger, C<min_level> and C<log_dir>, and ignores
C<log_dir>.  C<socket> is where to send, F</dev/log> unless a test says
otherwise.  C<ident> is the tag, C<tcms> unless given.

=cut

# LOG_DAEMON, from sys/syslog.h.
my $DAEMON = 3;

sub new ( $class, %p ) {
    my $self = bless( {}, $class );
    $self->_basic_init( map { exists $p{$_} ? ( $_ => $p{$_} ) : () } qw{name min_level max_level} );

    my $socket = $p{socket} // '/dev/log';
    my $ident  = $p{ident}  // 'tcms';

    # The sender is left out of the format, as syslog(3) leaves it out when it
    # writes to this socket, because the receiver is this machine.
    $self->{syslog} = Log::Syslog::Fast->new( LOG_UNIX, $socket, 0, $DAEMON, 6, '', $ident );
    $self->{syslog}->set_format(LOG_RFC3164_LOCAL);

    return $self;
}

=head2 log_message(%p)

Called by Log::Dispatch for each line at or above C<min_level>.

=cut

sub log_message ( $self, %p ) {

    # Log::Dispatch numbers its levels from debug at 0 to emergency at 7, and
    # syslog numbers its severities the other way round.
    my $severity = 7 - $self->_level_as_number( $p{level} );

    # Trog::Log ends every line with a newline, which a syslog message does
    # not carry.
    chomp( my $message = $p{message} );

    local $@;
    eval {
        $self->{syslog}->set_severity($severity);
        $self->{syslog}->send( $message, time );
        1;
    };
    return;
}

1;
