package Trog::Renderer::blob;

use v5.36;
use re '/aa';

=head1 Trog::Renderer::blob

Render blobs, such as files stored in a DB.

=cut

# TODO use the streaming code from Trog::FileHandler, etc.
sub render (%options) {
    my $code    = delete $options{code};
    my $headers = delete $options{headers};
    my $body    = $options{body};
    return [ $code, [$headers], [$body] ];
}

1;
