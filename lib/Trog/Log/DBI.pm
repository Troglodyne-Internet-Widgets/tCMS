package Trog::Log::DBI;

use strict;
use warnings;

use parent qw{Log::Dispatch::DBI};

use Ref::Util qw{is_arrayref};
use Capture::Tiny qw{capture_merged};

our ($referer, $ua);

sub create_statement {
    my $self = shift;

    # This is a writable view.  Consult schema for its behavior.
    my $sql = "INSERT INTO all_requests (uuid, date, ip_address, user, method, route, referer, ua, code) VALUES (?,?,?,?,?,?,?,?,?)";

    my $sql2 = "INSERT INTO messages (uuid, message) VALUES (?,?)";
    $self->{sth2} = $self->{dbh}->prepare($sql2);

    return $self->{dbh}->prepare($sql);
}

my %buffer;

sub log_message {
    my ($self, %params) = @_;

    # Rip apart the message.  If it's got any extended info, lets grab that too.
    my $msg = $params{message};
    my $message;
    my ($date, $uuid, $ip, $user, $method, $code, $route) = $msg =~ m!^([\w|\-|:]+) \[INFO\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (\w+) (\d+) (.+)!;

    # Otherwise, let's mark it down in the "messages" table.  This will be deferred until the final write.
    if (!$date) {
        ($date, $uuid, $ip, $user, $message) = $msg =~ m!^([\w|\-|:]+) \[\w+\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (.+)!;

        $buffer{$uuid} //= [];
        push(@{$buffer{$uuid}}, $message);
        return 1;
    }

    # If this is a mangled log, forget it.
    return unless $date && $uuid;

    # Allow callers to set referer.
    # We only care about this in DB context, as it's only for metrics, which are irrelevant in text logs/debugging.
    $referer //= 'none';
    $ua      //= 'none';

    my $res = $self->{sth}->execute($uuid, $date, $ip, $user, $method, $route, $referer, $ua, $code );

    if (is_arrayref($buffer{$uuid}) && @{$buffer{$uuid}}) {
        $self->{sth2}->bind_param_array(1, $uuid);
        $self->{sth2}->bind_param_array(2, $buffer{$uuid});
        $self->{sth2}->execute_array({});
        delete $buffer{$uuid};
    }

    return $res;
}

1;
