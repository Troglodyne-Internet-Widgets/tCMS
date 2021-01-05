package Trog::Utils;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

sub strip_and_trunc ($s) {
    return unless $s;
    $s =~ s/<[^>]*>//g;
    return substr $s, 0, 280;
}

1;
