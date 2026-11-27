package Trog::Renderer::email;

# ABSTRACT: Render an email as a text part and an HTML part

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use parent qw{Trog::Renderer::Base};

use Trog::Renderer::html;

=head1 Trog::Renderer::email

Render emails with both HTML and email parts, and inline all CSS/JS/Images.

=head1 FUNCTIONS

=head2 render(%options)

Render the template twice: as C<text/plain> with Trog::Renderer::Base, and as
C<text/html> with Trog::Renderer::html.  It does not inline anything yet.  It
takes the options of render() in Trog::Renderer::Base, and sets
C<contenttype> itself.

Returns HashRef, with C<text> and C<html>, each what the render of that part
returns.

Dies, as render() of Trog::Renderer::Base does, when a part does not render.

    my $parts = Trog::Renderer::email::render( template => $template, data => $data, code => 200 );

=cut

# TODO inlining
sub render (%options) {
    my $text = Trog::Renderer::Base::render( %options, contenttype => 'text/plain' );
    my $html = Trog::Renderer::html::render( %options, contenttype => 'text/html' );
    return { text => $text, html => $html };
}

1;
