package Trog::Routes::Common;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use Time::HiRes qw{gettimeofday};
use Ref::Util   qw{is_hashref};

use Trog::Routes::HTML;

=head1 Trog::Routes::Common

Themed HTTP error page handlers.

TPSGI's error methods (forbidden, notfound, error) call C<TCMS::generic_route>
via the C<$generic_handler> hook, but they don't forward the request query.
These subs accept a possibly-undef or partial C<$query> and normalise it before
handing off to C<Trog::Routes::HTML::index>, so the response is always rendered
with the active theme rather than TPSGI's bare text fallback.

=cut

sub _init_query ( $query, $code, $title, $template ) {
    $query = {} unless is_hashref($query);
    $query->{start}        //= [gettimeofday];
    $query->{code}           = $code;
    $query->{title}          = $title;
    $query->{template}       = $template;
    $query->{primary_post} //= {};
    $query->{social_meta}  //= 0;
    $query->{path}         //= $query->{route} // '';
    return $query;
}

=head2 not_found

Themed 404 response.

=cut

sub not_found ($query) {
    $query = _init_query( $query, 404, 'Not Found', '404.tx' );
    return Trog::Routes::HTML::index($query);
}

=head2 forbidden

Themed 403 response.

=cut

sub forbidden ($query) {
    $query = _init_query( $query, 403, 'Forbidden', '403.tx' );
    return Trog::Routes::HTML::index($query);
}

=head2 bad_request

Themed 400 response.

=cut

sub bad_request ($query) {
    $query = _init_query( $query, 400, 'Bad Request', '400.tx' );
    return Trog::Routes::HTML::index($query);
}

=head2 server_error

Themed 500 response.

=cut

sub server_error ($query) {
    $query = _init_query( $query, 500, 'Internal Server Error', '500.tx' );
    return Trog::Routes::HTML::index($query);
}

=head2 too_long

Themed 419 response (URI too long).

=cut

sub too_long ($query) {
    $query = _init_query( $query, 419, 'URI Too Long', '419.tx' );
    return Trog::Routes::HTML::index($query);
}

=head2 unavailable

Themed 503 response.

=cut

sub unavailable ($query) {
    $query = _init_query( $query, 503, 'Service Unavailable', '503.tx' );
    return Trog::Routes::HTML::index($query);
}

1;
