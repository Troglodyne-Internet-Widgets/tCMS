package Trog::Component::CategoryBar;

use v5.36;
use re '/aa';

use Trog::Component ();

=head1 Trog::Component::CategoryBar

The list of series links in the top bar.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render categories.tx.

Wants C<categories>, the series list the page was built with, and C<user>, which
decides whether the links point at /secure.

=cut

sub render (%args) {
    $args{categories} //= [];
    return Trog::Component::render_template( 'categories.tx', \%args );
}

1;
