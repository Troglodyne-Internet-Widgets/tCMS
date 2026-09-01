package Trog::Themes;

use v5.36;
use re '/aa';

use FindBin::libs;

use Trog::Vars;
use Trog::Config;

=head1 Trog::Themes

Utility functions for getting themed paths.

=cut

our $template_dir = 'www/templates';

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

    local $@;
    eval { require "$rdir/routes.pm"; 1; } or do {
        die "Could not load Theme routing package: $@";
    };

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
    my $conf = Trog::Config::get();
    my $theme = $conf->param('general.theme') || '';
    if( $theme ) {
        my $themedir = "www/themes/$theme";
        $tdir = $themedir if -d $themedir;
    }
    return $tdir;
};

=head2 td() = STRING $dir

get_dir() as a rooted URL path rather than a filesystem one, for templates to
build asset links with.  Empty string when there's no theme.

=cut

sub td {
    my $dir = get_dir();
    return $dir ? "/$dir" : '';
}

# The theme's template dir and the stock one, in that order of preference.
# The theme entry is empty when no theme is configured, so callers can just
# grep for truth rather than repeating the "is there a theme" dance.
sub _template_dirs ( $content_type, $is_component = 0 ) {
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
sub _dir_for_resource ($resource) {
    my $theme_dir = get_dir();
    return $theme_dir && -f "$theme_dir/$resource" ? $theme_dir : '';    ## no critic (ProhibitFiletest_f) -- theme override, else stock
}

=head2 themed($resource)

Path to a www/-relative resource, preferring the theme's copy.

=cut

sub themed ($resource) {
    return _dir_for_resource("$resource") . "/$resource";
}

=head2 themed_style($resource) = @hrefs

Stylesheets are the exception to the "one or the other" rule: you get the stock
sheet *and* the theme's, in that order, so a theme can override a handful of
rules without restating the whole thing.

=cut

# For style we want to load *both* style files and have the override come later.
sub themed_style ($resource) {
    my @styles = ("/styles/$resource");
    my $styled = _dir_for_resource("styles/$resource");
    $styled =~ s/^www\///;
    push( @styles, "/$styled/styles/$resource" ) if $styled;
    return @styles;
}

=head2 themed_script($resource)

Path to a script under www/scripts, preferring the theme's copy.

=cut

sub themed_script ($resource) {
    return _dir_for_resource("scripts/$resource") . "/scripts/$resource";
}

=head2 themed_template($resource)

Path to a template under www/templates, preferring the theme's copy.

=cut

sub themed_template ($resource) {
    return _dir_for_resource("templates/$resource") . "/templates/$resource";
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

=head2 files_in_dir($path, $content_type, $is_component, $ext)

Bare filenames with the given extension in whichever single directory dir_for()
picks.  See themed_templates_in_dir() for the version which spans both.

=cut

sub files_in_dir ( $path, $ct, $is_component = 0, $ext = 'tx' ) {
    return _read_dir( dir_for( $path, $ct, $is_component ), $ext );
}

sub _read_dir ( $dir, $ext ) {
    my $files = [];
    return $files unless -d $dir;
    opendir( my $dh, $dir ) or return $files;
    while ( my $file = readdir($dh) ) {
        push( @$files, $file ) if -f "$dir/$file" && $file =~ m/\.\Q$ext\E$/;    ## no critic (ProhibitFiletest_f) -- listing names, nothing is opened
    }
    closedir($dh);
    return $files;
}

=head2 templates_in_dir($path, $content_type, $is_component)

files_in_dir() restricted to templates.

Beware that this only ever reads one directory -- see themed_templates_in_dir()
for why that's usually not what you want.

=cut

sub templates_in_dir ( $path, $ct, $is_component = 0 ) {
    return files_in_dir( $path, $ct, $is_component, 'tx' );
}

=head2 themed_templates_in_dir($path, $content_type, $is_component)

Same calling convention as templates_in_dir(), but it doesn't make you pick a
side: you get the theme's templates where the theme has them, plus the stock
ones it hasn't overridden.

templates_in_dir() resolves through template_dir(), which is winner-take-all --
if a theme has a forms/ dir at all, its contents are the *only* post types the
site can see, and every core one vanishes.  That's rarely what a theme author
means by overriding a template.

Returns bare filenames, deduped, theme first.  Which of the two files a given
name resolves to is then up to whoever renders it -- see template_dirs().

=cut

sub themed_templates_in_dir ( $path, $ct, $is_component = 0 ) {
    my @dirs = grep { $_ } map { "$_/$path" } _template_dirs( $ct, $is_component );

    my ( @templates, %seen );
    foreach my $dir (@dirs) {
        foreach my $template ( @{ _read_dir( $dir, 'tx' ) } ) {

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

1;
