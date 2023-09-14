package Trog::Utils;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

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

1;
