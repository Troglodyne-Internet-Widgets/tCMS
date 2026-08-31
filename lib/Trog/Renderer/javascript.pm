package Trog::Renderer::javascript;

use v5.36;
use re '/aa';

use parent qw{Trog::Renderer::Base};

use JavaScript::Minifier::XS;

=head1 Trog::Renderer::javascript

Render JS, and minify the output.

=cut

sub render (%options) {
    $options{post_processor} = \&_minify;
    Trog::Renderer::Base::render(%options);
}

sub _minify {
    return JavaScript::Minifier::XS::minify(shift);
}

1;
