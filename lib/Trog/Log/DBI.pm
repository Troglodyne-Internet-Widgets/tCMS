package Trog::Log::DBI;

use strict;
use warnings;

use parent qw{Log::Dispatch::DBI};

use Ref::Util     qw{is_arrayref};
use Capture::Tiny qw{capture_merged};

use POSIX           qw{mktime};
use POSIX::strptime qw{strptime};

our ( $referer, $ua, $urchin );

=head1 Trog::Log::DBI

A Log::Dispatch::DBI subclass which files tCMS's request log into SQLite, so
that Trog::Log::Metrics has something to compute time series out of.

Rather than storing log lines verbatim, log_message() picks apart the format
Trog::Log emits and stores the pieces in columns.  Lines which don't match the
request format are treated as free text belonging to whichever request was in
flight, and are buffered until that request's own line shows up to hang them
off of.

Anything too mangled to identify a request is dropped -- a metrics database is
not the place to go looking for them, the log file has them either way.

=head1 VARIABLES

=over 4

=item $referer, $ua, $urchin

Per-request context which isn't in the log line itself.  The routes set these
before responding; they only exist for metrics, which is why they aren't in the
text logs.  $urchin is a hashref of utm_* parameters, and is only recorded when
it has a utm_source.

=back

=head1 METHODS

=head2 create_statement() = DBI::st

Called by Log::Dispatch::DBI at construction.  Prepares, and returns, the
statement for the requests view, and prepares the two extra statements
log_message() needs for messages and urchin data.

=cut

sub create_statement {
    my $self = shift;

    # This is a writable view.  Consult schema for its behavior.
    my $sql = "INSERT INTO all_requests (uuid, date, ip_address, user, method, route, referer, ua, code) VALUES (?,?,?,?,?,?,?,?,?)";

    my $sql2 = "INSERT INTO messages (uuid, message) VALUES (?,?)";
    $self->{sth2} = $self->{dbh}->prepare($sql2);

    my $sql3 = "INSERT INTO urchin_requests (request_uuid, utm_source, utm_medium, utm_campaign, utm_term, utm_content) VALUES (?,?,?,?,?,?)";
    $self->{sth3} = $self->{dbh}->prepare($sql3);

    return $self->{dbh}->prepare($sql);
}

my %buffer;

=head2 log_message(HASH params) = MIXED

Record one log line.

Returns the request insert's result for a request line, 1 for a message that
got buffered, and undef for a line we couldn't make sense of.

=cut

sub log_message {
    my ( $self, %params ) = @_;

    # Rip apart the message.  If it's got any extended info, lets grab that too.
    my $msg = $params{message};
    my $message;
    my ( $date, $uuid, $ip, $user, $method, $code, $bytes, $route ) = $msg =~ m!^([\w|\-|:]+) \[INFO\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (\w+) (\d+) (\d+) (.+)!;

    # Otherwise, let's mark it down in the "messages" table.  This will be deferred until the final write.
    if ( !$date ) {
        ( $date, $uuid, $ip, $user, $message ) = $msg =~ m!^([\w|\-|:]+) \[\w+\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (.+)!;

        # If we can't figure out its request, ignore the message
        if(length $uuid) {
            $buffer{$uuid} //= [];
            push(@{$buffer{$uuid}}, $message);
        }
        return 1;
    }

    # If this is a mangled log, forget it.
    return unless $date && $uuid;

    # 2024-01-20T22:37:41Z
    # Transform the date into an epoch so we can do math on it
    my $fmt     = "%Y-%m-%dT%H:%M:%SZ";
    my @cracked = strptime( $date, $fmt );

    #XXX get a dumb warning otherwise
    pop @cracked;
    my $epoch = mktime(@cracked);

    # Allow callers to set quasi-tracking parameters.
    # We only care about this in DB context, as it's only for metrics, which are irrelevant in text logs/debugging.
    $referer //= 'none';
    $ua      //= 'none';
    $urchin  //= {};

    # TODO track bytes in the DB
    my $res = $self->{sth}->execute( $uuid, $epoch, $ip, $user, $method, $route, $referer, $ua, $code );

    # Dump in the accumulated messages
    if ( is_arrayref( $buffer{$uuid} ) && @{ $buffer{$uuid} } ) {
        $self->{sth2}->bind_param_array( 1, $uuid );
        $self->{sth2}->bind_param_array( 2, $buffer{$uuid} );
        $self->{sth2}->execute_array( {} );
        delete $buffer{$uuid};

    }

    # Record urchin data if there is any.
    if ( %$urchin && $urchin->{utm_source} ) {
        $self->{sth3}->execute( $uuid, $urchin->{utm_source}, $urchin->{utm_medium}, $urchin->{utm_campaign}, $urchin->{utm_term}, $urchin->{utm_content} );
    }

    return $res;
}

1;
