package Trog::Component::Footer;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::Footer

The tail of an HTML page -- the closing body and html tags.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render footer.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'footer.tx', \%args ) }

1;
