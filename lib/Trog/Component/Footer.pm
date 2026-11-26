package Trog::Component::Footer;

# ABSTRACT: The tail of an HTML page, which closes the body and html tags

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Component ();

=head1 Trog::Component::Footer

The tail of an HTML page -- the closing body and html tags.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render footer.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

Returns Str, the rendered body.

Dies, as Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::Footer::render();

=cut

sub render (%args) { return Trog::Component::render_template( 'footer.tx', \%args ) }

1;
