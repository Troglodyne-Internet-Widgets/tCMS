package Trog::Renderer::html;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent qw{Trog::Renderer::Base};

use Text::Xslate;

=head1 Trog::Renderer::html

Render HTML. TODO: support inlining everything like you would want when emailing a post.

=cut

sub render (%options) {
    state $child_processor = Text::Xslate->new(

        # Prevent a recursive descent.  If the renderer is hit again, just do nothing
        # XXX unfortunately if the post tries to include itself, it will die.
        function => {
            embed => sub {
                my ( $this_id, $style ) = @_;
                $style //= 'embed';

                # If instead the style is 'content', then we will only show the content w/ no formatting, and no title.
                return Text::Xslate::mark_raw(
                    Trog::Routes::HTML::posts(
                        { route => "/post/$this_id", style => $style },
                        sub { },
                        1
                    )
                );
            },
        }
    );
    state $child_renderer = sub {
        my ( $template_string, $options ) = @_;

        # If it fails to render, it must be something else
        my $out = eval { $child_processor->render_string( $template_string, $options ) };
        return $out ? $out : $template_string;
    };

    $options{child_processor} = $child_processor;
    $options{child_renderer}  = $child_renderer;

    return Trog::Renderer::Base::render(%options);
}

1;
