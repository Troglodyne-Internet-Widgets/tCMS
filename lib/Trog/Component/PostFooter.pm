package Trog::Component::PostFooter;

use v5.36;
use re '/aa';

use Trog::Component ();
use Trog::Themes;

=head1 Trog::Component::PostFooter

The per-post footer a series can name in its metadata, drawn from the footers/
directory of the stock templates or the theme's.

=head1 FUNCTIONS

=head2 render(%args) = STRING

Render footers/$args{name}.

The name comes out of post data, so it is checked against the footers/ listing
before it becomes a path -- see available().  Returns the empty string when no
name is given, so that the caller can ask unconditionally.

Beyond the name, the template gets the post it belongs to and the route it is
being shown at, plus theme_dir for building asset paths.  That is narrower than
the whole request hash these used to be rendered with; a theme whose footer
wants something else should be handed it at the call site in posts.tx.

=cut

sub render (%args) {
    my $name = delete $args{name};
    return '' unless defined $name && length $name;

    die "No such footer '$name'\n" unless grep { $_ eq $name } @{ available() };

    $args{theme_dir} //= Trog::Themes::td();
    return Trog::Component::render_template( "footers/$name", \%args );
}

=head2 available() = ARRAYREF

The footers a post may name: every .tx in footers/, the theme's and the stock ones
both.  This is the same list the series edit form offers, so anything the form
can pick renders, and nothing else does.

=cut

sub available () {
    return Trog::Themes::themed_templates_in_dir( 'footers', 'text/html', 1 );
}

1;
