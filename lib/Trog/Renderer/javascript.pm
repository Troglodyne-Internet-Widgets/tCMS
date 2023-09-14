package Trog::Renderer::javascript;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

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
