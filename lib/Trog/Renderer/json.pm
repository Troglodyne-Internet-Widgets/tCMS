package Trog::Renderer::json;

use v5.36;
use re '/aa';

use JSON::MaybeXS;

=head1 Trog::Renderer::json

Render JSON.  Rather than be templated, we just run the input thru the encoder.

=cut

sub render (%options) {
    my $code    = delete $options{code}    // 200;
    my $headers = delete $options{headers} // {};

    my %h = (
        'Content-type' => "application/json",
        %$headers,
    );

    delete $options{contenttype};
    delete $options{template};

    my $body = encode_json( $options{data} );
    return [ $code, [%h], [$body] ];
}

1;
