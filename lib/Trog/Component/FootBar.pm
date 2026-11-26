package Trog::Component::FootBar;

# ABSTRACT: The footer bar of a page, below the content

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Component ();

=head1 Trog::Component::FootBar

The footer bar, below the content.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render footbar.tx.  Stock reads no variables; anything passed is handed to the
template, so a theme's override is free to want some.

Returns Str, the rendered body.

Dies, as Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::FootBar::render();

=cut

sub render (%args) { return Trog::Component::render_template( 'footbar.tx', \%args ) }

1;
