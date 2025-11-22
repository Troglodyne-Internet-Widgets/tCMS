package Trog::Themes;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use FindBin::libs;

use Trog::Vars;
use Trog::Config;
use Trog::Log;

=head1 Trog::Themes

Utility functions for getting themed paths.

=cut

our $template_dir = 'www/templates';

sub get_dir {
    state $tdir = '';
    return $tdir if $tdir;
    my $conf = Trog::Config::get();
    my $theme = $conf->param('general.theme') || '';
    if( $theme ) {
        my $themedir = "www/themes/$theme";
        $tdir = $themedir if -d $themedir;
    }
    Trog::Log::INFO("Loading Theme '$theme' from '$tdir'");
    return $tdir;
};

sub td {
    my $dir = get_dir();
    return $dir ? "/$dir" : '';
}

sub template_dir ( $template, $content_type, $is_component = 0, $is_dir = 0 ) {
    my $ct = $Trog::Vars::byct{$content_type};
    my ( $mtd, $mtemp ) = ( get_dir() . "/templates/$ct", "$template_dir/$ct" );
    if ($is_component) {
        $mtd   .= "/components";
        $mtemp .= "/components";
    }
    if ($is_dir) {
        return $mtd && -d "$mtd/$template" ? $mtd : $mtemp;
    }
    return $mtd && -f "$mtd/$template" ? $mtd : $mtemp;
}

# Pick appropriate dir based on whether theme override exists
sub _dir_for_resource ($resource) {
    my $theme_dir = get_dir();
    return $theme_dir && -f "$theme_dir/$resource" ? $theme_dir : '';
}

sub themed ($resource) {
    return _dir_for_resource("$resource") . "/$resource";
}

# For style we want to load *both* style files and have the override come later.
sub themed_style ($resource) {
    my @styles = ("/styles/$resource");
    my $styled = _dir_for_resource("styles/$resource");
    $styled =~ s/^www\///;
    push( @styles, "/$styled/styles/$resource" ) if $styled;
    return @styles;
}

sub themed_script ($resource) {
    return _dir_for_resource("scripts/$resource") . "/scripts/$resource";
}

sub themed_template ($resource) {
    return _dir_for_resource("templates/$resource") . "/templates/$resource";
}

sub templates_in_dir ( $path, $ct, $is_component = 0 ) {
    $path = template_dir( $path, $ct, $is_component, 1 ) . "/$path";
    my $forms = [];
    return $forms unless -d $path;
    opendir( my $dh, $path );
    while ( my $form = readdir($dh) ) {
        push( @$forms, $form ) if -f "$path/$form" && $form =~ m/.*\.tx$/;
    }
    close($dh);
    return $forms;
}

1;
