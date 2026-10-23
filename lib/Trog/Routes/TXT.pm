package Trog::Routes::TXT;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Renderer;

our %routes = (
    '/text/zone' => {
        method     => 'GET',
        callback   => \&zone,
        parameters => {},
        admin      => 1,
    },
);

my sub _render ( $code, $headers, %data ) {
    return Trog::Renderer->render(
        code        => $code,
        data        => \%data,
        template    => 'zone.tx',
        contenttype => 'text/plain',
        headers     => $headers,
    );
}

=head1 Trog::Routes::TXT

Routes which render as text/plain.

=head1 CAVEATS

This module is not wired up to anything.  TCMS.pm builds its routing table out
of Trog::Routes::HTML and Trog::Routes::JSON only, so nothing here is reachable
and /text/zone will 404.

=head1 VARIABLES

=over 4

=item %routes

The usual tCMS routing table -- path to method, callback, parameters and
whether the route requires admin.

=back

=head1 ROUTES

=head2 zone

Render zone.tx, this instance's DNS zone file.  Admin only.

Note that it passes the query through as-is; zone.tx wants $ip, $nameservers,
$subdomains and friends, so it needs a data gathering pass before it will
render anything.

=cut

sub zone ($query) {
    return _render( 200, {}, $query );
}

1;
