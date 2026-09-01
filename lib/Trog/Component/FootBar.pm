package Trog::Component::FootBar;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::FootBar

The footer bar, below the content.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render footbar.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'footbar.tx', \%args ) }

1;
