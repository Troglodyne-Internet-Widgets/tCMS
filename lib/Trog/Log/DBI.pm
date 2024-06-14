package Trog::Log::DBI;

use strict;
use warnings;

use parent qw{Log::Dispatch::DBI};

use Ref::Util     qw{is_arrayref};
use Capture::Tiny qw{capture_merged};

use POSIX           qw{mktime};
use POSIX::strptime qw{strptime};

our ( $referer, $ua, $urchin );

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

sub log_message {
    my ( $self, %params ) = @_;

    # Rip apart the message.  If it's got any extended info, lets grab that too.
    my $msg = $params{message};
    my $message;
    my ( $date, $uuid, $ip, $user, $method, $code, $bytes, $route ) = $msg =~ m!^([\w|\-|:]+) \[INFO\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (\w+) (\d+) (\d+) (.+)!;

    # Otherwise, let's mark it down in the "messages" table.  This will be deferred until the final write.
    if ( !$date ) {
        ( $date, $uuid, $ip, $user, $message ) = $msg =~ m!^([\w|\-|:]+) \[\w+\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (.+)!;

        $buffer{$uuid} //= [];
        push( @{ $buffer{$uuid} }, $message );
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
