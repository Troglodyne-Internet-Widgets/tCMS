package Trog::Log::DBI;

use strict;
use warnings;

use parent qw{Log::Dispatch::DBI};

sub create_statement {
    my $self = shift;

    # This is a writable view.  Consult schema for its behavior.
    my $sql = "INSERT INTO all_requests (uuid, date, ip_address, user, method, route, code) VALUES (?,?,?,?,?,?,?)";

    my $sql2 = "INSERT INTO messages (uuid, message) VALUES (?,?)";
    $self->{sth2} = $self->{dbh}->prepare($sql2);

    return $self->{dbh}->prepare($sql);
}

sub log_message {
    my ($self, %params) = @_;

    # Rip apart the message.  If it's got any extended info, lets grab that too.
    my $msg = $params{message};
    my $message;
    my ($date, $uuid, $ip, $user, $method, $code, $route) = $msg =~ m!^([\w|\-|:]+) \[INFO\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (\w+) (\d+) (.+)!;

    # Otherwise, let's mark it down in the "messages" table.
    if (!$date) {
        ($date, $uuid, $ip, $user, $message) = $msg =~ m!^([\w|\-|:]+) \[\w+\]: RequestId ([\w|\-]+) From ([\w|\.|:]+) \|(\w+)\| (.+)!;
        # Dummy up the method, code and route, as otherwise we summon complexity demon due to lack of FULL OUTER JOIN.
        $method = "UNKNOWN";
        $code   = 100;
        $route  = "bogus";
    }

    # If this is a mangled log, forget it.
    return unless $date;

    my $res = $self->{sth}->execute($uuid, $date, $ip, $user, $method, $route, $code);
    $self->{sth2}->execute($uuid, $message) if $message;
    return $res;
}

1;
