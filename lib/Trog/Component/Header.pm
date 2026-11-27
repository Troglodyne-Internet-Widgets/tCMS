package Trog::Component::Header;

# ABSTRACT: The head of an HTML page, from the doctype down to the opening body tag

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Component ();
use Trog::Themes    ();

=head1 Trog::Component::Header

Everything from the doctype down to the opening body tag: the title, the social
and icon metadata, and the stylesheet and script links.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render header.tx.

It takes these arguments, all optional, and dies on any other:

    title / route / lang / author         the page itself
    meta_desc / meta_tags / default_tags  social metadata, built by the route
    stylesheets / print_styles / scripts  resolved paths, built by finish_render
    embed                                 embedded view, which adds a base target
    no_doctype                            leave the doctype off, for the RSS
                                          stylesheet, which is XSL rather than HTML
    title_select                          in place of title, the XPath of the
                                          title, for that same stylesheet
    theme_dir                             as Trog::Component::render_template()
                                          gives it, when it is not passed

The template also gets icons, the URL path of each favicon by its file name,
from the theme where it has that icon and from the stock ones where it does
not.

The list arguments default to empty rather than to the stock sheets, so that a
caller which has none -- rss_style(), notably -- gets a header with none, as it
did when the route rendered this itself.

Returns Str, the rendered body.

Dies when it gets an argument that is not in the list above, and, as
Trog::Component::render_template() does, when the render fails.

    my $html = Trog::Component::Header::render( title => 'RSS', no_doctype => 1 );

=cut

my @arguments = qw{title route lang author meta_desc meta_tags default_tags stylesheets print_styles scripts embed no_doctype title_select theme_dir};
my %known     = map { $_ => 1 } @arguments;

sub render (%args) {
    my @unknown = grep { !$known{$_} } sort keys(%args);
    die "The Header component takes no argument named @unknown\n" if @unknown;
    $args{$_} //= undef for @arguments;

    $args{lang}         //= 'en-US';
    $args{title}        //= 'tCMS';
    $args{stylesheets}  //= [];
    $args{print_styles} //= [];
    $args{scripts}      //= [];

    $args{icons} = { map { $_ => Trog::Themes::url_path( Trog::Themes::themed("img/icon/$_") ) } qw{favicon.svg favicon-167.png favicon-180.png favicon-48.png favicon-192.png} };

    return Trog::Component::render_template( 'header.tx', \%args );
}

1;
