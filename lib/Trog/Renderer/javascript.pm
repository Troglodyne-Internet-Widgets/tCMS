package Trog::Renderer::javascript;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use parent qw{Trog::Renderer::Base};

use JavaScript::Minifier::XS;

=head1 Trog::Renderer::javascript

Render JS, and minify the output.

=cut

sub render (%options) {
    $options{post_processor} = \&_minify;
    return Trog::Renderer::Base::render(%options);
}

sub _minify {
    return JavaScript::Minifier::XS::minify(shift);
}

1;
