package Trog::Themes;

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
%Theme::routes.  Returns an empty list when there's no theme, or when the theme
hasn't got one.  Dies if there is a routes.pm and it won't load, as silently
serving a site with half its routes missing is worse than not starting.

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
templates to build asset links with.  Empty string when there's no theme.

=cut

sub td {
    my $dir = get_dir();
    return $dir ? url_path($dir) : '';
}

=head2 url_path($file) = STRING $path

The URL path at which the webserver serves $file, a path under the document
root such as C<www/themes/mytheme/img/a.png>.  Dies when $file is not under it,
as the webserver does not serve it.

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

=cut

sub themed ($resource) {
    return ( dir_for_resource($resource) || $docroot ) . "/$resource";
}

=head2 themed_style($resource) = @hrefs

Stylesheets are the exception to the "one or the other" rule: you get the URL
path of the stock sheet *and* the theme's, in that order, so a theme can
override a handful of rules without restating the whole thing.

=cut

sub themed_style ($resource) {
    my $theme = dir_for_resource("styles/$resource");
    return ( "/styles/$resource", $theme ? url_path("$theme/styles/$resource") : () );
}

=head2 themed_script($resource) = STRING $file

themed() for a script under scripts/.

=cut

sub themed_script ($resource) {
    return themed("scripts/$resource");
}

=head2 dir_for($path, $content_type, $is_component)

The single directory which owns a given component subdir: the theme's if it has
one, the stock one otherwise.  This is the right answer for I<writing> -- see
forms_dir() and the post type wizard.  For reading, you almost certainly want
themed_templates_in_dir() instead, which spans both.

=cut

sub dir_for ( $path, $ct, $is_component = 0 ) {
    return template_dir( $path, $ct, $is_component, 1 ) . "/$path";
}

=head2 forms_dir()

dir_for() the post type forms directory, which is where the post type wizard
writes new types and their schema sidecars.

=cut

sub forms_dir {
    return dir_for( 'forms', 'text/html', 1 );
}

=head2 themed_templates_in_dir($path, $content_type, $is_component)

The template names in an abstract template dir, from the theme and the stock
tree both: the theme's templates where the theme has them, plus the stock ones
it hasn't overridden.  dir_for() is winner-take-all, so a theme with a forms/
dir of its own would otherwise hide every core post type.

Returns bare filenames, deduped, theme first, and sorted within each dir.  Which
of the two files a given name resolves to is then up to whoever renders it --
see template_dirs().

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

=head2 themed_file_in_dir($path, $file, $content_type, $is_component)

The path to a single named file in an abstract template dir, preferring the
theme's copy.  Returns undef when neither has it.

=cut

sub themed_file_in_dir ( $path, $file, $ct, $is_component = 0 ) {
    foreach my $dir ( grep { $_ } _template_dirs( $ct, $is_component ) ) {
        return "$dir/$path/$file" if -f "$dir/$path/$file";    ## no critic (ProhibitFiletest_f) -- search path, first hit wins
    }
    return undef;
}

=head2 themed_component($file, $content_type)

The path to a file sitting directly in the components dir rather than in one of
its subdirectories, preferring the theme's copy.  Returns undef when neither has
it.

This is themed_file_in_dir() for the components which are not post types: the
canned editor blocks every form splices in, and the JSON sidecars beside them
which say what each one collects -- see Trog::DataModule::include_schema_for().

=cut

sub themed_component ( $file, $ct = 'text/html' ) {
    foreach my $dir ( template_dirs( $ct, 1 ) ) {
        return "$dir/$file" if -f "$dir/$file";    ## no critic (ProhibitFiletest_f) -- search path, first hit wins
    }
    return undef;
}

1;
