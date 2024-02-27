package Trog::Routes::JSON;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

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
