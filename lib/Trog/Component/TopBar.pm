package Trog::Component::TopBar;

# ABSTRACT: The slot of the theme in the top bar, beside the search box

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Component ();

=head1 Trog::Component::TopBar

The top bar's theme slot, beside the search box.  Empty by default.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render topbar.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

Returns Str, the rendered body.

Dies, as Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::TopBar::render();

=cut

sub render (%args) { return Trog::Component::render_template( 'topbar.tx', \%args ) }

1;
