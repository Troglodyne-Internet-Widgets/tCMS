package Trog::Renderer::Base;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

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

sub render (%options) {
    die "Templated renders require a template to be passed" unless $options{template};

    my $template_dir = Trog::Themes::template_dir( $options{template}, $options{contenttype}, $options{component} );
    my $t            = "$template_dir/$options{template}";
    die "Templated renders require an existing template to be passed, got $template_dir/$options{template}" unless -f $t || -s $t;

    #TODO make this work with posts all the time
    $options{child_processor} //= Text::Xslate->new( path => $template_dir );
    my $child_processor = $options{child_processor};
    $options{child_renderer} //= sub {
        my ( $template_string, $options ) = @_;

        # If it fails to render, it must be something else
        my $out = eval { $child_processor->render_string( $template_string, $options ) };
        return $out ? $out : $template_string;
    };

    $renderers{$template_dir} //= Text::Xslate->new(
        path     => $template_dir,
        function => {
            render_it => $options{child_renderer},
        },
    );

    my $code = $options{code};
    my $body = encode_utf8( $renderers{$template_dir}->render( $options{template}, $options{data} ) );

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

sub headers ( $options, $body ) {
    my $query   = $options->{data};
    my $uh      = ref $options->{headers} eq 'HASH' ? $options->{headers} : {};
    my $ct      = $options->{contenttype} eq 'text/html' ? "text/html; charset=UTF-8" : "$options->{contenttype};";
    my %headers = (
        'Content-Type'           => $ct,
        'Content-Length'         => length($body),
        'Cache-Control'          => $query->{cachecontrol} // $Trog::Vars::cache_control{revalidate},
        'X-Content-Type-Options' => 'nosniff',
        'Vary'                   => 'Accept-Encoding',
        'Server-Timing'          => "render;dur=".(tv_interval($query->{start}) * 1000),
        %$uh,
    );

    #Disallow framing UNLESS we are in embed mode
    my $ancestor = $query->{domain} || 'none';
    $headers{"Content-Security-Policy"} = qq{frame-ancestors '$ancestor'} unless $query->{embed};

    $headers{'X-Frame-Options'} = 'DENY' unless $query->{embed};
    $headers{'Referrer-Policy'} = 'no-referrer-when-downgrade';

    #CSP. Yet another layer of 'no mixed content' plus whitelisted execution of remote resources.
    my $scheme = $query->{scheme} ? "$query->{scheme}:" : '';

    my $conf  = Trog::Config::get();
    my $sites = $conf->param('security.allow_embeds_from') // '';
    $headers{'Content-Security-Policy'} .= ";default-src $scheme 'self' 'unsafe-eval' 'unsafe-inline' $sites";
    $headers{'Content-Security-Policy'} .= ";object-src 'none'";

    # Force https if we are https
    $headers{'Strict-Transport-Security'} = 'max-age=63072000' if ( $query->{scheme} // '' ) eq 'https';

    # We only set etags when users are logged in, cause we don't use statics
    $headers{'ETag'} = $query->{etag} if $query->{etag} && $query->{user};

    return %headers;
}

1;
