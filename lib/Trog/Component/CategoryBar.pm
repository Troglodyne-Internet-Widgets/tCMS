package Trog::Component::CategoryBar;

# ABSTRACT: The list of series links in the top bar

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Component ();

=head1 Trog::Component::CategoryBar

The list of series links in the top bar.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render categories.tx.

Wants C<categories>, the series list the page was built with, and C<user>, which
decides whether the links point at /secure.

=over 4

=item categories - ArrayRef - the series list, an empty list by default

=item user - Str|Undef - the name of the user who is logged in, or undef

=back

Returns Str, the rendered body.

Dies, as Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::CategoryBar::render( categories => $categories, user => $user );

=cut

sub render (%args) {
    $args{categories} //= [];
    $args{user}       //= undef;
    return Trog::Component::render_template( 'categories.tx', \%args );
}

1;
