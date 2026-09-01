package Trog::Component::Header;

use v5.36;
use re '/aa';

use Trog::Component ();
use Trog::Themes;

=head1 Trog::Component::Header

Everything from the doctype down to the opening body tag: the title, the social
and icon metadata, and the stylesheet and script links.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render header.tx.

Recognized arguments, all optional:

    title / route / lang / author         the page itself
    meta_desc / meta_tags / default_tags  social metadata, built by the route
    stylesheets / print_styles / scripts  resolved paths, built by finish_render
    embed                                 embedded view, which adds a base target
    no_doctype                            leave the doctype off, for the RSS
                                          stylesheet, which is XSL rather than HTML

The list arguments default to empty rather than to the stock sheets, so that a
caller which has none -- rss_style(), notably -- gets a header with none, as it
did when the route rendered this itself.

theme_dir is worked out here rather than passed, as it is the same for every
page and the template only wants it to build asset paths.

=cut

sub render (%args) {
    $args{lang}         //= 'en-US';
    $args{title}        //= 'tCMS';
    $args{stylesheets}  //= [];
    $args{print_styles} //= [];
    $args{scripts}      //= [];

    # td() answers a rooted URL path, which for a themed site starts /www/ --
    # the template builds hrefs with it, and /www is not in the URL space.
    my $theme_dir = Trog::Themes::td();
    $theme_dir =~ s|^/www/||;
    $args{theme_dir} //= $theme_dir;

    return Trog::Component::render_template( 'header.tx', \%args );
}

1;
