package Trog::Renderer::json;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use JSON::MaybeXS;

=head1 Trog::Renderer::json

Render JSON.  Rather than be templated, we just run the input thru the encoder.

=cut

sub render (%options) {
    my $code    = delete $options{code};
    my $headers = delete $options{headers};
    my $body    = encode_json(\%options);
    return [$code, [$headers], [$body]];
}

1;
