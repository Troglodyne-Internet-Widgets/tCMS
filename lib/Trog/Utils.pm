package Trog::Utils;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use HTTP::Tiny::UNIX();
use Trog::Log qw{WARN};
use Trog::Config();

# Deal with Params which may or may not be arrays
sub coerce_array ($param) {
    my $p = $param || [];
    $p = [$param] if $param && ( ref $param ne 'ARRAY' );
    return $p;
}

sub strip_and_trunc ($s) {
    return unless $s;
    $s =~ s/<[^>]*>//g;
    return substr $s, 0, 280;
}

# Instruct the parent to restart.  Normally this is HUP, but nginx-unit decides to be special.
sub restart_parent ( $env ) {
    if ($env->{PSGI_ENGINE} && $env->{PSGI_ENGINE} eq 'nginx-unit') {
        my $conf = Trog::Config->get();
        my $nginx_socket = $conf->param('nginx-unit.socket');
        my $client = HTTP::Tiny::UNIX->new();
        my $res = $client->request('GET', "http:$nginx_socket//control/applications/tcms/restart" );
        WARN("could not reload application (got $res->{status} from nginx-unit)!") unless $res->{status} == 200;
        return 1;
    }
    my $parent = getppid;
    kill 'HUP', $parent;
}

1;
