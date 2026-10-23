package Trog::Renderer::text;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use parent qw{Trog::Renderer::Base};

=head1 Trog::Renderer::text

Render plain text.  Can be used for email as well.

=cut

sub render (%options) {
    return Trog::Renderer::Base::render(%options);
}

1;
