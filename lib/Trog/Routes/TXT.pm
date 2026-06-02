package Trog::Routes::TXT;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Trog::Config();
use Trog::Routes::HTML();
use Trog::Renderer;

our %routes = (
    '/text/zone' => {
        method     => 'GET',
        callback   => \&Trog::Routes::TXT::zone,
        parameters => {},
        admin      => 1,
    },
);

sub zone ($query) {
    return _render( 200, {}, $query );
}

sub _render ( $code, $headers, %data ) {
    return Trog::Renderer->render(
        code        => 200,
        data        => \%data,
        template    => 'zone.tx',
        contenttype => 'text/plain',
        headers     => $headers,
    );
}

1;
