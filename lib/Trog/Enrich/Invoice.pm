package Trog::Enrich::Invoice;

# ABSTRACT: Compute the total of an invoice post from its line items

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use List::Util();

=head1 Trog::Enrich::Invoice

The part of an invoice which has to be computed rather than merely fetched.

Its payee and payor are ordinary relations, declared in invoice.json and
resolved by Trog::Routes::HTML::enrich_post like any other type's.  The
running total is not -- it is read out of the line items themselves.

=head2 enrich($post, $query)

Sum the line items into a total.  Each page of a multi-page invoice post is one
line item, and a line that begins with 'Price:' carries its cost.  The
denomination is the single character before the digits.  It comes from the
last line item: when that item has no price, it is C<$>, whatever the others
say.  Only the
whole units count: C<Price: $12.50> adds 12.

Trog::Routes::HTML::enrich_post calls it, because invoice.json names it as the
C<enrich> sub of the invoice type.

=over 4

=item post - HashRef - the invoice post.  Its C<data> is an ArrayRef of the
pages.

=item query - HashRef - the query of the request.  It is not used.

=back

Returns a list of the extra keys of the post: C<total>, a Str such as C<$120>.
Returns an empty list when the C<data> of the post is not an ArrayRef.

    my %extra = Trog::Enrich::Invoice::enrich( $post, $query );

=cut

sub enrich ( $post, $ ) {
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
