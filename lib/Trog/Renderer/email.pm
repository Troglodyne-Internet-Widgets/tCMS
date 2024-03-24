package Trog::Renderer::email;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent qw{Trog::Renderer::Base};

use Text::Xslate;
use Trog::Themes;
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
