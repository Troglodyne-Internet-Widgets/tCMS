package Trog::Component::RightBar;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::RightBar

The right sidebar.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render rightbar.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'rightbar.tx', \%args ) }

1;
