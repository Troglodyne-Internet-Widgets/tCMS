package Trog::Renderer::Base;

use v5.36;
use re '/aa';

use Encode qw{encode_utf8};
use IO::Compress::Gzip;

use Text::Xslate;
use Trog::Themes;
use Trog::Config;
use Time::HiRes qw{tv_interval};

=head1 Trog::Renderer::Base

Basic rendering structure, subclass me.

Sets up the methods which must be present for all templates, e.g. render_it for rendering dynamic template strings coming from a post.

=cut

our %renderers;

=head2 render(%options)

Render a template and build the PSGI response around it.

Recognized options:

    template    => the template's filename, relative to the template dir.  Required.
    contenttype => what we're rendering, e.g. 'text/html'.  Picks the template dir.
    component   => render a component rather than a whole page.  Returns just the
                   body string, with no headers and no compression.
    data        => the variables handed to the template.
    code        => HTTP status for the response.
    headers     => extra headers, merged over the computed ones.
    deflate     => gzip the body and set Content-Encoding.
    post_processor => CODEREF run over the body before headers are computed, for
                   things like minifiers.
    child_processor / child_renderer => override how post bodies are rendered by
                   the render_it() template function.  Built for you if omitted.

Dies unless Xslate can resolve and render the template.  Returns the body
string for components, and a PSGI arrayref of [ code, headers, body ] otherwise.

=cut

sub render (%options) {
    die "Templated renders require a template to be passed" unless $options{template};

    # Xslate resolves includes against every dir in path, first match winning,
    # so handing it both lets a theme override individual templates without
    # having to fork the ones next to them.  With no theme configured this is
    # just the stock dir, exactly as it was.
    my @template_dirs = Trog::Themes::template_dirs( $options{contenttype}, $options{component} );

    #TODO make this work with posts all the time
    $options{child_processor} //= Text::Xslate->new( path => \@template_dirs );
    my $child_processor = $options{child_processor};
    $options{child_renderer} //= sub {
        my ( $template_string, $options ) = @_;

        # If it fails to render, it must be something else
        my $out = eval { $child_processor->render_string( $template_string, $options ) };
        return $out ? $out : $template_string;
    };

    # Keyed on the whole search path, not just the winning dir: two different
    # paths that happen to start with the same dir are not the same renderer.
    my $renderer_key = join( ':', @template_dirs );
    $renderers{$renderer_key} //= Text::Xslate->new(
        path     => \@template_dirs,
        function => {
            render_it => $options{child_renderer},
        },
    );

    my $code = $options{code};

    # Xslate resolves the template itself, against the same @template_dirs it
    # will actually use.  There used to be a pre-flight test here, and it was
    # wrong twice over: it resolved through template_dir(), which returns one
    # winning directory rather than the search path, so it could pass on a file
    # Xslate would not use and name a nonexistent stock path in its error while
    # a good theme template existed.  And the condition itself, -f $t || -s $t,
    # short-circuited on -f, so an empty file passed, while a *directory* passed
    # on -s returning its size.
    my $body = eval { encode_utf8( $renderers{$renderer_key}->render( $options{template}, $options{data} ) ) };
    die "Could not render template '$options{template}' (searched @template_dirs): $@" unless defined $body;

    # Users can supply a post_processor to futz with the output (such as with minifiers) if they wish.
    $body = $options{post_processor}->($body) if $options{post_processor} && ref $options{post_processor} eq 'CODE';

    # Users can supply custom headers as part of the data in options.
    my %headers = headers( \%options, $body );

    return $body if $options{component};
    return [ $code, [%headers], [$body] ] unless $options{deflate};

    $headers{"Content-Encoding"} = "gzip";
    my $dfh;
    IO::Compress::Gzip::gzip( \$body => \$dfh );
    print $IO::Compress::Gzip::GzipError if $IO::Compress::Gzip::GzipError;
    $headers{"Content-Length"} = length($dfh);

    return [ $code, [%headers], [$dfh] ];
}

=head2 headers($options, $body) = %headers

The response headers for a rendered body: content type and length, caching,
Server-Timing, and the security headers (CSP, X-Frame-Options, HSTS when we're
on https, nosniff).  Anything in $options->{headers} is merged over the top.

ETags are only set for logged in users, as everyone else is served out of the
static render cache.

=cut

sub headers ( $options, $body ) {
    my $query   = $options->{data};
    my $uh      = ref $options->{headers} eq 'HASH'      ? $options->{headers}        : {};
    my $ct      = $options->{contenttype} eq 'text/html' ? "text/html; charset=UTF-8" : "$options->{contenttype};";
    my %headers = (
        'Content-Type'           => $ct,
        'Content-Length'         => length($body),
        'Cache-Control'          => $query->{cachecontrol} // $Trog::Vars::cache_control{revalidate},
        'X-Content-Type-Options' => 'nosniff',
        'Vary'                   => 'Accept-Encoding',
        'Server-Timing'          => "render;dur=" . ( tv_interval( $query->{start} ) * 1000 ),
        %$uh,
    );

    #Disallow framing UNLESS we are in embed mode
    my $ancestor = $query->{domain} || 'none';
    $headers{"Content-Security-Policy"} = qq{frame-ancestors $ancestor} unless $query->{embed};

    $headers{'X-Frame-Options'} = 'DENY' unless $query->{embed};
    $headers{'Referrer-Policy'} = 'no-referrer-when-downgrade';

    #CSP. Yet another layer of 'no mixed content' plus whitelisted execution of remote resources.
    # Component renders (posts.tx, the bars) get a data hash built by the route
    # rather than the request, and it carries no scheme.
    my $scheme = ( $query->{scheme} // '' ) eq 'https' ? "$query->{scheme}:" : '';

    my $conf  = Trog::Config::get();
    my $sites = $conf->param('security.allow_embeds_from') // '';
    $headers{'Content-Security-Policy'} .= ";default-src $scheme 'self' data: 'unsafe-eval' 'unsafe-inline' $sites";
    $headers{'Content-Security-Policy'} .= ";object-src 'none'";

    # Force https if we are https
    $headers{'Strict-Transport-Security'} = 'max-age=63072000' if ( $query->{scheme} // '' ) eq 'https';

    # We only set etags when users are logged in, cause we don't use statics
    $headers{'ETag'} = $query->{etag} if $query->{etag} && $query->{user};

    return %headers;
}

1;
