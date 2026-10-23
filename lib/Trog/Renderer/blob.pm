package Trog::Renderer::blob;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

=head1 Trog::Renderer::blob

Render blobs, such as files stored in a DB.

=cut

# TODO stream large blobs, as TPSGI::serve streams files.
sub render (%options) {
    my $code    = delete $options{code};
    my $headers = delete $options{headers};
    my $body    = $options{body};
    return [ $code, [$headers], [$body] ];
}

1;
