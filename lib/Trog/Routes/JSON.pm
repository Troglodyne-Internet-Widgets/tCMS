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

1;
