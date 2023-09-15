package Trog::Themes;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Trog::Vars;
use Trog::Config;

=head1 Trog::Themes

Utility functions for getting themed paths.

=cut

my $conf         = Trog::Config::get();
our $template_dir = 'www/templates';
our $theme_dir    = '';
$theme_dir = "www/themes/" . $conf->param('general.theme') if $conf->param('general.theme') && -d "www/themes/" . $conf->param('general.theme');
our $td = $theme_dir ? "/$theme_dir" : '';

sub template_dir ($template, $content_type, $is_component=0, $is_dir=0) {
    my $ct = $Trog::Vars::byct{$content_type};
    my ($mtd, $mtemp) = ("$theme_dir/templates/$ct", "$template_dir/$ct");
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
    return $theme_dir && -f "$theme_dir/$resource" ? $theme_dir : '';
}

sub themed ($resource) {
    return _dir_for_resource("$resource") . "/$resource";
}

sub themed_style ($resource) {
    return _dir_for_resource("styles/$resource") . "/styles/$resource";
}

sub themed_script ($resource) {
    return _dir_for_resource("scripts/$resource") . "/scripts/$resource";
}

sub themed_template ($resource) {
    return _dir_for_resource("templates/$resource") . "/templates/$resource";
}

sub templates_in_dir ($path, $ct, $is_component=0) {
    $path = template_dir($path, $ct, $is_component, 1)."/$path";
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
