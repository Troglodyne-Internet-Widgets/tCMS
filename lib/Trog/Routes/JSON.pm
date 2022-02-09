package Trog::Routes::JSON;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Digest::SHA();
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

my $headers = ['Content-type' => "application/json"];

sub catalog ($query) {
    my $enc = JSON::MaybeXS->new( utf8 => 1 );
    my %rcopy = %{\%routes};
    foreach my $r (keys(%rcopy)) {
        delete $rcopy{$r}{callback}
    }
    # Make the ETag the sha256 of the routes
    my $content = $enc->encode(\%rcopy);
    my $state = Digest::SHA->new(256);
    my $hash = $state->add($content);

    push(@$headers, ETag => $state->hexdigest);
    return [200,$headers,[$content]];
}

sub webmanifest ($query) {
    my $enc = JSON::MaybeXS->new( utf8 => 1 );
    my %manifest = (
        "icons" => [
            { "src" => "$theme_dir/img/icon/favicon-192.png", "type" => "image/png", "sizes" => "192x192" },
            { "src" => "$theme_dir/img/icon/favicon-512.png", "type" => "image/png", "sizes" => "512x512" },
        ],
    );
    # Make the ETag the sha256 of the routes
    my $content = $enc->encode(\%manifest);
    my $state = Digest::SHA->new(256);
    my $hash = $state->add($content);

    push(@$headers, ETag => $state->hexdigest);
    return [ 200, $headers, [$content] ];
}

1;
