package Trog::Routes::JSON;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use JSON::MaybeXS();
use Trog::Config();

my $conf = Trog::Config::get();

# TODO de-duplicate this, it's shared in html
my $theme_dir = '';
$theme_dir = "themes/".$conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/".$conf->param('general.theme');

our %routes = (
    '/api/catalog' => {
        method     => 'GET',
        callback   => \&catalog,
        parameters => [],
    },
    '/api/webmanifest' => {
        method         => 'GET',
        callback       => \&webmanifest,
        parameters     => [],
    },
);

my $contenttype = "Content-type:application/json;";

sub catalog ($query) {
    my $enc = JSON::MaybeXS->new( utf8 => 1 );
    my %rcopy = %{\%routes};
    foreach my $r (keys(%rcopy)) {
        delete $rcopy{$r}{callback}
    }
    return [200,[$contenttype],[$enc->encode(\%rcopy)]];
}

sub webmanifest ($query) {
    my $enc = JSON::MaybeXS->new( utf8 => 1 );
    my %manifest = (
        "icons" => [
            { "src" => "$theme_dir/img/icon/favicon-192.png", "type" => "image/png", "sizes" => "192x192" },
            { "src" => "$theme_dir/img/icon/favicon-512.png", "type" => "image/png", "sizes" => "512x512" },
        ],
    );

    return [ 200, [$contenttype], [$enc->encode(\%manifest)] ];
}

1;
