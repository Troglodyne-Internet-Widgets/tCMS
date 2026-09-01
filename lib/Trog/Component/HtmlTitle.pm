package Trog::Component::HtmlTitle;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::HtmlTitle

The site title, shown at the left of the top bar.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render title.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'title.tx', \%args ) }

1;
