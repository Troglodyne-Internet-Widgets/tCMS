package Trog::Renderer::json;

# ABSTRACT: Render data as a JSON response, with no template

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use JSON::MaybeXS;

=head1 Trog::Renderer::json

Render JSON.  Rather than be templated, we just run the input thru the encoder.

=head1 FUNCTIONS

=head2 render(%options)

Encode the data as JSON, and build the PSGI response around it.  It ignores
C<contenttype> and C<template>.

=over 4

=item code - Int - the HTTP status, 200 by default

=item headers - HashRef - headers to merge over C<Content-type: application/json>

=item data - HashRef|ArrayRef - the data to encode

=back

Returns ArrayRef, the PSGI response [ code, headers, body ].

Dies, as encode_json() of JSON::MaybeXS does, when the data cannot be encoded.

    my $response = Trog::Renderer::json::render( code => 200, data => { ok => 1 } );

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
