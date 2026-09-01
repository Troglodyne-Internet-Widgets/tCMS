package Trog::Component::TopBar;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::TopBar

The top bar's theme slot, beside the search box.  Empty by default.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render topbar.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'topbar.tx', \%args ) }

1;
