package Trog::Renderer::text;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

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
