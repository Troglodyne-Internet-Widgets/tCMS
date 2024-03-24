package Trog::Renderer;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Carp::Always;

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

=cut;

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

=head2 Trog::Renderer->render(%options)

Returns either the 3-arg arrayref suitable to emit at the end of a PSGI session or a response body if the component field of options is truthy.
The idea is that components will be concatenated to other rendered templates until we finish having everything ready.

=cut

sub render ( $class, %options ) {
    local $@;
    my $renderer;
    return _yeet( $renderer, "Renderer requires a valid content type to be passed", %options ) unless $options{contenttype};
    my $rendertype = $Trog::Vars::byct{ $options{contenttype} };
    return _yeet( $renderer, "Renderer requires a known content type (used $options{contenttype}) to be passed", %options ) unless $rendertype;
    $renderer = $renderers{$rendertype};
    return _yeet( $renderer, "Renderer for $rendertype is not defined!", %options ) unless $renderer;
    return _yeet( $renderer, "Status code not provided",                 %options ) if !$options{code} && !$options{component};
    return _yeet( $renderer, "Template data not provided",               %options ) unless $options{data};
    return _yeet( $renderer, "Template not provided",                    %options ) unless $options{template};

    #TODO future - save the components too and then compose them?
    my $skip_save = !$options{component} || !$options{data}{route} || $options{data}{has_query} || $options{data}{user} || ( $options{code} // 0 ) != 200 || Trog::Log::is_debug();

    my $ret;
    local $@;
    eval {
        $ret = $renderer->(%options);
        save_render( $options{data}, $ret->[2], %{ $ret->[1] } ) unless $skip_save;
        1;
    } or do {
        return _yeet( $renderer, $@, %options );
    };
    return $ret;
}

sub _yeet ( $renderer, $error, %options ) {
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
        INFO("$options{data}{method} 500 ".length($msg)." $options{data}{route}");
        FATAL($msg);
    };
    return $ret;
}

sub save_render ( $vars, $body, %headers ) {
    Path::Tiny::path( "www/statics/" . dirname( $vars->{route} ) )->mkpath;
    my $file = "www/statics/$vars->{route}";

    my $verb = -f $file ? 'Overwrite' : 'Write';
    DEBUG("$verb static for $vars->{route}");
    open( my $fh, '>', $file ) or die "Could not open $file for writing";
    print $fh "HTTP/1.1 $vars->{code} OK\n";
    foreach my $h ( keys(%headers) ) {
        print $fh "$h:$headers{$h}\n" if $headers{$h};
    }
    print $fh "\n";
    print $fh $body;
    close $fh;
}

1;
