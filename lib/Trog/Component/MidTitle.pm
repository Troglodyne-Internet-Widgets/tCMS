package Trog::Component::MidTitle;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::MidTitle

The middle slot of the top bar.  Empty by default.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render midtitle.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

=cut

sub render (%args) { return Trog::Component::render_template( 'midtitle.tx', \%args ) }

1;
