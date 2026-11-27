package Trog::Renderer;

# ABSTRACT: Render a template, or data, with the renderer of its content type

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Vars;
use Trog::Log qw{:all};

use Trog::Renderer::text;
use Trog::Renderer::html;
use Trog::Renderer::json;
use Trog::Renderer::blob;
use Trog::Renderer::css;
use Trog::Renderer::email;

=head1 Trog::Renderer

Idea here is to have a renderer per known/supported content-type we need to output that is also theme-aware.

We have an abstraction here, render() which you feed everything to.

=cut

our %renderers = (
    text  => \&Trog::Renderer::text::render,
    html  => \&Trog::Renderer::html::render,
    json  => \&Trog::Renderer::json::render,
    blob  => \&Trog::Renderer::blob::render,
    xsl   => \&Trog::Renderer::text::render,
    xml   => \&Trog::Renderer::text::render,
    rss   => \&Trog::Renderer::html::render,
    css   => \&Trog::Renderer::css::render,
    email => \&Trog::Renderer::email::render,
);

my sub yeet ( $renderer, $error, %options ) {
    WARN($error);

    # All-else fails error page
    my $ret;
    local $@;
    eval {
        $ret = $renderer->(
            code        => 500,
            template    => '500.tx',
            contenttype => 'text/html',
            data        => { %options, content => "<h1>500 Internal Server Error</h1>$error" },
        );
        1;
    } or do {
        my $msg = $error;
        $msg .= " and subsequently during render of error template, $@" if $renderer;

        #XXX bytes is probably not correct here
        INFO( ( $options{data}{method} // '?' ) . ' 500 ' . length($msg) . ' ' . ( $options{data}{route} // '?' ) );
        FATAL($msg);
    };
    return $ret;
}

=head2 Trog::Renderer->render(%options)

Picks the renderer in C<%renderers> by C<contenttype>, through
C<%Trog::Vars::byct>, and hands it %options.  When a request can be served from
the static render cache later, it has tPSGI save the render after the response.
When the options are not valid, or the render dies, it renders the 500 page
instead, with the error in it.

It takes the options of render() in Trog::Renderer::Base.  These it checks
itself:

=over 4

=item contenttype - Str - the content type, which %Trog::Vars::byct must know.  Required.

=item code - Int - the HTTP status.  Required unless C<component> is true.

=item component - Bool - true to get the body of a component rather than a response

=item template - Str - the file name of the template.  Required.

=item data - HashRef - the variables of the template.  Required.

=item nocache - Bool - true to never save the render as a static file

=back

Returns ArrayRef|Str|HashRef: either the 3-arg arrayref suitable to emit at the end of a PSGI session, or a response body if the component field of options is truthy.
The renderer of C<multipart/related>, Trog::Renderer::email, gives a HashRef of the text and HTML parts.
The idea is that components will be concatenated to other rendered templates until we finish having everything ready.

Dies when the 500 page does not render either, or when the content type is
missing or unknown, as then there is no renderer to render the 500 page.

    my $out = Trog::Renderer->render(
        contenttype => 'text/plain',
        template    => 'robots.tx',
        data        => { banned => \@banned, %$query },
        code        => 200,
    );

=cut

sub render ( $, %options ) {
    local $@;
    my $renderer;
    return yeet( $renderer, "Renderer requires a valid content type to be passed", %options ) unless $options{contenttype};
    my $rendertype = $Trog::Vars::byct{ $options{contenttype} };
    return yeet( $renderer, "Renderer requires a known content type (used $options{contenttype}) to be passed", %options ) unless $rendertype;
    $renderer = $renderers{$rendertype};
    return yeet( $renderer, "Renderer for $rendertype is not defined!", %options ) unless $renderer;
    return yeet( $renderer, "Status code not provided",                 %options ) if !$options{code} && !$options{component};
    return yeet( $renderer, "Template data not provided",               %options ) unless $options{data};
    return yeet( $renderer, "Template not provided",                    %options ) unless $options{template};

    #TODO future - save the components too and then compose them?
    my $data = $options{data};

    # $data->{nocache} as well as $options{nocache}: TCMS::build_routes puts a
    # route's nocache flag on the query, and exactly one caller (login) has ever
    # forwarded it here as an option.  Every other nocache route was relying on
    # being auth-gated, so that the $data->{user} test below caught it -- which
    # says nothing about a route that is nocache and public, and there is now
    # one: a datasource whose posts go stale asks for it this way.
    my $skip_save =
         $options{component}
      || $options{nocache}
      || $data->{nocache}
      || !$data->{route}
      || $data->{has_query}
      || $data->{user}
      || ( $options{code} // 0 ) != 200
      || Trog::Log::is_debug();

    my $ret;
    local $@;
    eval {
        $ret = $renderer->(%options);
        if ( exists $data->{tpsgi} && !$skip_save ) {
            $data->{tpsgi}->add_post_close_callback(
                sub {
                    # We invalidate these in the individual routes themselves.
                    $data->{tpsgi}->save_render( $data->{route}, $rendertype, $ret->[2][0] );
                }
            );
        }
        1;
    } or do {
        return yeet( $renderer, $@, %options );
    };
    return $ret;
}

1;
