package Trog::Component::HtmlTitle;

# ABSTRACT: The site title, at the left of the top bar

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Component ();

=head1 Trog::Component::HtmlTitle

The site title, shown at the left of the top bar.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render title.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

Returns Str, the rendered body.

Dies, as Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::HtmlTitle::render();

=cut

sub render (%args) { return Trog::Component::render_template( 'title.tx', \%args ) }

1;
