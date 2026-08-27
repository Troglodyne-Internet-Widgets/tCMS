package Trog::Enrich::Invoice;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use List::Util();

=head1 Trog::Enrich::Invoice

The part of an invoice which has to be computed rather than merely fetched.

Its payee and payor are ordinary relations, declared in invoice.json and
resolved by Trog::Routes::HTML::_enrich_post like any other type's.  The
running total is not -- it is read out of the line items themselves.

=head2 enrich($post, $query) = %extra

Sum the line items into a total.  Each page of a multi-page invoice post is one
line item, and a line beginning 'Price:' is what carries its cost; the
denomination is taken from the first one that has any.

=cut

sub enrich ( $post, $query ) {
    return () unless ref $post->{data} eq 'ARRAY';

    my $denomination;
    my @prices = map {
        my $price = 0;
        ( $denomination, $price ) = m/^Price:\s*(\D)(\d+)/mix;
        $price;
    } @{ $post->{data} };

    $denomination //= '$';
    return ( total => $denomination . ( List::Util::sum(@prices) // 0 ) );
}

1;
