package Trog::Autoreload;

use strict;
use warnings;

use feature qw{signatures};

use Linux::Perl::inotify;

use Trog::Utils;

sub watch_for_changes ( $dir, $interval=5 ) {
    my $inf = Linux::Perl::inotify->new([qw{NONBLOCK}]);
 
    my @dirs = ($dir);
    my @wds;
    foreach my $directory (@dirs) {
        # Recursive scan for directories and setting up inotifies
        push(@dirs, _readdir( $directory ));
        DEBUG("Watching $directory for changes");
        push(@wds, $inf->add( path => $directory, events => [qw{CREATE MODIFY}] ));
    }
    while (!$inf->read()) {
        sleep $interval;
    }
    INFO("Change in $dir detected");
    Trog::Utils::restart_parent();
    exit 0;
}

sub _readdir ( $dir ) {
    opendir(my $dh, $dir);
    my @dirs = grep { -d $_ && !m/^\.+$/ } readdir($dh);
    closedir($dh);
    return @dirs;
}
