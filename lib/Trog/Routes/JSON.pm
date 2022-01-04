package Trog::Routes::JSON;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use JSON::MaybeXS();

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

sub catalog ($query, $input, $=) {
    my $enc = JSON::MaybeXS->new( utf8 => 1 );
    my %rcopy = %{\%routes};
    foreach my $r (keys(%rcopy)) {
        delete $rcopy{$r}{callback}
    }
    return [200,[$contenttype],[$enc->encode(\%rcopy)]];
}

sub webmanifest ($query, $input, $=) {
    my $enc = JSON::MaybeXS->new( utf8 => 1 );
    my %manifest = (
        "icons" => [
            { "src" => "$query->{theme_dir}/img/icon/favicon-192.png", "type" => "image/png", "sizes" => "192x192" },
            { "src" => "$query->{theme_dir}/img/icon/favicon-512.png", "type" => "image/png", "sizes" => "512x512" },
        ],
    );

    return [ 200, [$contenttype], [$enc->encode(\%manifest)] ];
}

1;
