package Trog::Renderer::css;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent qw{Trog::Renderer::Base};

use CSS::Minifier::XS;

=head1 Trog::Renderer::css

Render CSS, and minify the output.

=cut

sub render (%options) {
    $options{post_processor} = \&_minify;
    Trog::Renderer::Base::render(%options);
}

sub _minify {
    return CSS::Minifier::XS::minify(shift);
}

1;
