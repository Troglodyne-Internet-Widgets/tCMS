package Trog::Themes;

# ABSTRACT: Find the files, templates and URL paths of the active theme, or the stock ones

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;
use Path::Tiny();

use Trog::Vars;
use Trog::Config;

=head1 Trog::Themes

Utility functions for getting themed paths.

=cut

# The directory that the webserver serves at /.
our $docroot = 'www';

our $template_dir = "$docroot/templates";

=head2 routes() = %routes

The active theme's own routing table, from its routes.pm.

Themes can add routes of their own by shipping a routes.pm which populates
%Theme::routes.

Returns Hash, the pairs of %Theme::routes.  The list is empty when there is no
theme, or when the theme has no routes.pm.

Dies when there is a routes.pm and it does not load, as to serve a site with
half its routes missing is worse than not to start.

    my %routes = Trog::Themes::routes();

=cut

sub routes {
    my $rdir = get_dir();
    return () unless -f "$rdir/routes.pm";    ## no critic (ProhibitFiletest_f) -- theme ships routes, or it does not

    # get_dir() is relative to the tCMS root, which require only searches from '.'.
    local @INC = ( '.', @INC );
    local $@;
    eval { require "$rdir/routes.pm"; 1; } or do {    ## no critic (Modules::RequireBarewordIncludes) -- a theme ships a file, not a module
        die "Could not load Theme routing package: $@";
    };

    no warnings 'once';
    return %Theme::routes;
}

=head2 get_dir() = STRING $dir

The active theme's directory, relative to the tCMS root, e.g.
C<www/themes/mytheme>.  Empty string when no theme is configured, or when the
configured one doesn't exist on disk -- so it's safe to interpolate either way,
and truthiness is the test for "is there a theme".

Memoized for the life of the process: changing the theme goes through
/config/save, which signals the workers to restart.

Returns Str, the directory of the theme, or an empty string.

    my $theme = Trog::Themes::get_dir();

=cut

sub get_dir {
    state $tdir = '';
    return $tdir if $tdir;
    my $conf  = Trog::Config::get();
    my $theme = $conf->param('general.theme') || '';
    if ($theme) {
        my $themedir = "$docroot/themes/$theme";
        $tdir = $themedir if -d $themedir;
    }
    return $tdir;
}

=head2 td() = STRING $dir

The URL path of the active theme's directory, e.g. C</themes/mytheme>, for
templates to build asset links with.

Returns Str, the URL path, or an empty string when there is no theme.

    my $td = Trog::Themes::td();

=cut

sub td {
    my $dir = get_dir();
    return $dir ? url_path($dir) : '';
}

=head2 url_path($file) = STRING $path

The URL path at which the webserver serves $file, a path under the document
root such as C<www/themes/mytheme/img/a.png>.

=over 4

=item file - Str - a path under the document root

=back

Returns Str, the URL path, such as C</themes/mytheme/img/a.png>.

Dies when $file is not under the document root, as the webserver does not
serve it.

    my $href = Trog::Themes::url_path( Trog::Themes::themed($Theme::default_image) );

=cut

sub url_path ($file) {
    die "$file is not under $docroot/\n" unless CORE::index( $file, "$docroot/" ) == 0;
    return substr( $file, length $docroot );
}

# The theme's template dir and the stock one, in that order of preference.
# The theme entry is empty when no theme is configured, so callers can just
# grep for truth rather than repeating the "is there a theme" dance.
my sub _template_dirs ( $content_type, $is_component = 0 ) {
    my $ct    = $Trog::Vars::byct{$content_type};
    my $theme = get_dir();

    my ( $themed, $stock ) = ( $theme ? "$theme/templates/$ct" : '', "$template_dir/$ct" );
    if ($is_component) {
        $themed .= "/components" if $themed;
        $stock  .= "/components";
    }
    return ( $themed, $stock );
}

=head2 template_dirs($content_type, $is_component)

Every directory which could satisfy a template, most specific first.

Hand this to Text::Xslate as its C<path> and a theme gets to override
individual templates without having to fork every last one of them.

=over 4

=item content_type - Str - a content type that %Trog::Vars::byct knows, such as C<text/html>

=item is_component - Bool - true for the components directory under it, false by default

=back

Returns Array of Str, the directories that exist: the theme's, then the stock
one.

    my @dirs = Trog::Themes::template_dirs( 'text/html', 1 );

=cut

sub template_dirs ( $content_type, $is_component = 0 ) {
    return grep { $_ && -d $_ } _template_dirs( $content_type, $is_component );
}

=head2 template_dir($template, $content_type, $is_component, $is_dir)

The single directory which owns $template: the theme's if it has its own copy,
the stock one otherwise.  With $is_dir, $template names a subdirectory (forms,
headers, footers) rather than a file.

This answers "who owns this one thing", which is what you want when *writing*.
For reading a whole directory you almost always want themed_templates_in_dir()
instead, which spans both rather than making you pick.

=over 4

=item template - Str - the file name of the template, or the name of a subdirectory

=item content_type - Str - a content type that %Trog::Vars::byct knows, such as C<text/html>

=item is_component - Bool - true for the components directory, false by default

=item is_dir - Bool - true when $template names a subdirectory, false by default

=back

Returns Str, the directory of the theme when it has $template, else the stock
directory.

    my $dir = Trog::Themes::template_dir( 'forms', 'text/html', 1, 1 );

=cut

sub template_dir ( $template, $content_type, $is_component = 0, $is_dir = 0 ) {
    my ( $mtd, $mtemp ) = _template_dirs( $content_type, $is_component );
    if ($is_dir) {
        return $mtd && -d "$mtd/$template" ? $mtd : $mtemp;
    }
    return $mtd && -f "$mtd/$template" ? $mtd : $mtemp;    ## no critic (ProhibitFiletest_f) -- which dir owns the template
}

# Pick appropriate dir based on whether theme override exists
my sub dir_for_resource ($resource) {
    my $theme_dir = get_dir();
    return $theme_dir && -f "$theme_dir/$resource" ? $theme_dir : '';    ## no critic (ProhibitFiletest_f) -- theme override, else stock
}

=head2 themed($resource) = STRING $file

The file of $resource, a path relative to the document root, preferring the
theme's copy, e.g. C<www/themes/mytheme/img/a.png> or C<www/img/a.png>.  Hand
it to url_path() for its link.

=over 4

=item resource - Str - a path relative to the document root

=back

Returns Str, the path of the file, under the theme or the document root.

    my $tpath = Trog::Themes::themed( 'img/icon' . $path );

=cut

sub themed ($resource) {
    return ( dir_for_resource($resource) || $docroot ) . "/$resource";
}

=head2 themed_style($resource) = @hrefs

Stylesheets are the exception to the "one or the other" rule: you get the URL
path of the stock sheet *and* the theme's, in that order, so a theme can
override a handful of rules without restating the whole thing.

=over 4

=item resource - Str - the file name of a stylesheet under styles/

=back

Returns Array of Str, the URL path of the stock sheet, then that of the
theme's sheet when the theme has one.

    my @styles = Trog::Themes::themed_style('screen.css');

=cut

sub themed_style ($resource) {
    my $theme = dir_for_resource("styles/$resource");
    return ( "/styles/$resource", $theme ? url_path("$theme/styles/$resource") : () );
}

=head2 themed_script($resource) = STRING $file

themed() for a script under scripts/.

=over 4

=item resource - Str - the file name of a script under scripts/

=back

Returns Str, the path of the script, under the theme or the document root.

    my $file = Trog::Themes::themed_script('post.js');

=cut

sub themed_script ($resource) {
    return themed("scripts/$resource");
}

=head2 dir_for($path, $ct, $is_component)

The single directory which owns a given component subdir: the theme's if it has
one, the stock one otherwise.  This is the right answer for I<writing> -- see
forms_dir() and the post type wizard.  For reading, you almost certainly want
themed_templates_in_dir() instead, which spans both.

=over 4

=item path - Str - the name of the subdirectory, such as C<forms>

=item ct - Str - a content type that %Trog::Vars::byct knows, such as C<text/html>

=item is_component - Bool - true for the components directory, false by default

=back

Returns Str, the path of the subdirectory, under the theme or the stock tree.

    my $dir = Trog::Themes::dir_for( 'forms', 'text/html', 1 );

=cut

sub dir_for ( $path, $ct, $is_component = 0 ) {
    return template_dir( $path, $ct, $is_component, 1 ) . "/$path";
}

=head2 forms_dir()

dir_for() the post type forms directory, which is where the post type wizard
writes new types and their schema sidecars.

Returns Str, the path of the forms directory.

    my $forms = Trog::Themes::forms_dir();

=cut

sub forms_dir {
    return dir_for( 'forms', 'text/html', 1 );
}

=head2 themed_templates_in_dir($path, $ct, $is_component)

The template names in an abstract template dir, from the theme and the stock
tree both: the theme's templates where the theme has them, plus the stock ones
it hasn't overridden.  dir_for() is winner-take-all, so a theme with a forms/
dir of its own would otherwise hide every core post type.

=over 4

=item path - Str - the name of the subdirectory, such as C<headers>

=item ct - Str - a content type that %Trog::Vars::byct knows, such as C<text/html>

=item is_component - Bool - true for the components directory, false by default

=back

Returns ArrayRef[Str], the bare file names of the C<.tx> templates, deduped,
theme first, and sorted within each dir.  Which of the two files a given name
resolves to is then up to whoever renders it -- see template_dirs().

    my $headers = Trog::Themes::themed_templates_in_dir( 'headers', 'text/html', 1 );

=cut

sub themed_templates_in_dir ( $path, $ct, $is_component = 0 ) {
    my @dirs = grep { $_ } map { "$_/$path" } _template_dirs( $ct, $is_component );

    my ( @templates, %seen );
    foreach my $dir (@dirs) {
        next unless -d $dir;
        my @files = eval {
            grep { -f } Path::Tiny::path($dir)->children(qr/[.]tx\z/);    ## no critic (ProhibitFiletest_f) -- listing names, nothing is opened
        };
        foreach my $template ( sort map { local ($_) = $_; $_->basename } @files ) {

            # First one wins, and the theme's dir comes first.
            push( @templates, $template ) unless $seen{$template}++;
        }
    }
    return \@templates;
}

=head2 themed_file_in_dir($path, $file, $ct, $is_component)

The path to a single named file in an abstract template dir, preferring the
theme's copy.

=over 4

=item path - Str - the name of the subdirectory, such as C<forms>

=item file - Str - the name of the file

=item ct - Str - a content type that %Trog::Vars::byct knows, such as C<text/html>

=item is_component - Bool - true for the components directory, false by default

=back

Returns Str|Undef, the path of the file, or undef when neither directory has it.

    my $path = Trog::Themes::themed_file_in_dir( 'forms', "$type.json", 'text/html', 1 );

=cut

sub themed_file_in_dir ( $path, $file, $ct, $is_component = 0 ) {
    foreach my $dir ( grep { $_ } _template_dirs( $ct, $is_component ) ) {
        return "$dir/$path/$file" if -f "$dir/$path/$file";    ## no critic (ProhibitFiletest_f) -- search path, first hit wins
    }
    return undef;
}

=head2 themed_component($file, $ct)

The path to a file sitting directly in the components dir rather than in one of
its subdirectories, preferring the theme's copy.

This is themed_file_in_dir() for the components which are not post types: the
canned editor blocks every form splices in, and the JSON sidecars beside them
which say what each one collects -- see Trog::DataModule::include_schema_for().

=over 4

=item file - Str - the name of the file

=item ct - Str - a content type that %Trog::Vars::byct knows, C<text/html> by default

=back

Returns Str|Undef, the path of the file, or undef when neither directory has it.

    my $path = Trog::Themes::themed_component("$name.json");

=cut

sub themed_component ( $file, $ct = 'text/html' ) {
    foreach my $dir ( template_dirs( $ct, 1 ) ) {
        return "$dir/$file" if -f "$dir/$file";    ## no critic (ProhibitFiletest_f) -- search path, first hit wins
    }
    return undef;
}

1;
