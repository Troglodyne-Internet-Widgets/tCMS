package Trog::Renderer::css;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use parent qw{Trog::Renderer::Base};

use CSS::Minifier::XS;

=head1 Trog::Renderer::css

Render CSS, and minify the output.

=cut

sub render (%options) {
    $options{post_processor} = \&_minify;
    return Trog::Renderer::Base::render(%options);
}

sub _minify {
    return CSS::Minifier::XS::minify(shift);
}

1;
