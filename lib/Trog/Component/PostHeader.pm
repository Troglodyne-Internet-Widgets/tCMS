package Trog::Component::PostHeader;

# ABSTRACT: The header that a series names for each of its posts

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use List::Util();

use Trog::Component ();
use Trog::Themes;

=head1 Trog::Component::PostHeader

The per-post header a series can name in its metadata, drawn from the headers/
directory of the stock templates or the theme's.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render headers/$args{name}.

The name comes out of post data, so it is checked against the headers/ listing
before it becomes a path -- see available().

Beyond the name, the template gets the post it belongs to and the route it is
being shown at, plus theme_dir for building asset paths.  That is narrower than
the whole request hash these used to be rendered with; a theme whose header
wants something else should be handed it at the call site in posts.tx.

Returns Str, the rendered body, or the empty string when no name is given, so
that the caller can ask unconditionally.

Dies when the name is not in available(), and, as
Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::PostHeader::render( name => $name, post => $post, route => $route );

=cut

sub render (%args) {
    my $name = delete $args{name};
    return '' unless $name;

    die "No such header '$name'\n" unless List::Util::any { $_ eq $name } @{ available() };

    return Trog::Component::render_template( "headers/$name", \%args );
}

=head2 available() = ARRAYREF

The headers a post may name: every .tx in headers/, the theme's and the stock ones
both.  This is the same list the series edit form offers, so anything the form
can pick renders, and nothing else does.

Returns ArrayRef[Str], the file names of the templates.

    my $headers = Trog::Component::PostHeader::available();

=cut

sub available () {
    return Trog::Themes::themed_templates_in_dir( 'headers', 'text/html', 1 );
}

1;
