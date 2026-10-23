package Trog::Renderer::email;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use parent qw{Trog::Renderer::Base};

use Trog::Renderer::html;

=head1 Trog::Renderer::email

Render emails with both HTML and email parts, and inline all CSS/JS/Images.

=cut

# TODO inlining
sub render (%options) {
    my $text = Trog::Renderer::Base::render( %options, contenttype => 'text/plain' );
    my $html = Trog::Renderer::html::render( %options, contenttype => 'text/html' );
    return { text => $text, html => $html };
}

1;
