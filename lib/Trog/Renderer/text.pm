package Trog::Renderer::text;

use 5.040;
use re '/aasx';

use parent qw{Trog::Renderer::Base};

use Text::Xslate;

use Trog::Themes;

=head1 Trog::Renderer::text

Render plain text.  Can be used for email as well.

=cut

sub render (%options) {
    Trog::Renderer::Base::render(%options);
}

1;
