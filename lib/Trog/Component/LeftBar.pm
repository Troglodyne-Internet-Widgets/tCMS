package Trog::Component::LeftBar;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::LeftBar

The left sidebar.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render leftbar.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'leftbar.tx', \%args ) }

1;
