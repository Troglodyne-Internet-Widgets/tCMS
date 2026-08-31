package Trog::Routes::JSON;

use v5.36;
use re '/aa';

use Clone qw{clone};
use JSON::MaybeXS();

use Scalar::Util();

use Trog::Utils();
use Trog::Config();
use Trog::Auth();
use Trog::Routes::HTML();

use Trog::Log::Metrics();

my $conf = Trog::Config::get();

# TODO de-duplicate this, it's shared in html
my $theme_dir = '';
$theme_dir = "themes/" . $conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/" . $conf->param('general.theme');

our %routes = (
    '/text/zone' => {
        method     => 'GET',
        callback   => \&zone,
        parameters => {},
        admin      => 1,
    },
);

=head1 Trog::Routes::TXT

Routes which render as text/plain.

=head1 CAVEATS

This module is not wired up to anything.  TCMS.pm builds its routing table out
of Trog::Routes::HTML and Trog::Routes::JSON only, so nothing here is reachable
and /text/zone will 404.

Worse, the package statement in this file says Trog::Routes::JSON rather than
Trog::Routes::TXT, so loading it would quietly replace the JSON routing table
with this one.  Fix that before wiring it in.

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
