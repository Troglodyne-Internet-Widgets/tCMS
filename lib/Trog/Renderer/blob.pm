package Trog::Renderer::blob;

# ABSTRACT: Render a blob, such as a file stored in a DB, as a PSGI response

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

=head1 Trog::Renderer::blob

Render blobs, such as files stored in a DB.

=head1 FUNCTIONS

=head2 render(%options)

Build the PSGI response for a blob, with no template.

=over 4

=item code - Int - the HTTP status

=item headers - Any - the one element of the header list of the response

=item body - Str - the blob

=back

Returns ArrayRef, the PSGI response [ code, [ headers ], [ body ] ].

    my $response = Trog::Renderer::blob::render( code => 200, headers => $headers, body => $blob );

=cut

# TODO stream large blobs, as TPSGI::serve streams files.
sub render (%options) {
    my $code    = delete $options{code};
    my $headers = delete $options{headers};
    my $body    = $options{body};
    return [ $code, [$headers], [$body] ];
}

1;
