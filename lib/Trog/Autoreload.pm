package Trog::Autoreload;

use strict;
use warnings;

no warnings qw{experimental};
use feature qw{signatures};

use Cwd qw{abs_path};
use Time::HiRes qw{usleep};
use Linux::Perl::inotify;

use Trog::Utils;

sub watch_for_changes ( $dir, $pid=undef ) {
    my @dirs = (abs_path($dir));
    my @wds;

    my $inf = Linux::Perl::inotify->new(flags => [qw{NONBLOCK}]);
    foreach my $directory (@dirs) {
        # Recursive scan for directories and setting up inotifies
        push(@dirs, _readdir( $directory ));
        print "Watching $directory for changes\n";
        push(@wds, $inf->add( path => $directory, events => [qw{CREATE MODIFY}] ));
    }
    my @result;
    CHECK: while (1) {
        @result = $inf->read();
        foreach my $res (@result) {
            last CHECK if $res->{name} =~ m/\.pm$/;
        }
        usleep 100000; #100ms oughtta be enough
        # If we know the pid, stop watching when it dies.
        if ($pid && !-d "/proc/$pid") {
            foreach my $wd (@wds) { $inf->remove($wd) }
            return 1;
        }
    }
    print "Relevant Change in $dir detected, reloading\n";
    Trog::Utils::restart_parent($pid);
    foreach my $wd (@wds) { $inf->remove($wd) }
    return 0;
}

sub _readdir ( $dir ) {
    opendir(my $dh, $dir);
    my @dirs = map { "$dir/$_" } grep { -d "$dir/$_" && !m/^\.+$/ } readdir($dh);
    closedir($dh);
    return @dirs;
}

sub monitor_pid {
    my $pf = 'run/monitor.pid';
    if (-f $pf) {
        open(my $pidfile, '<', $pf);
        read($pidfile, my $pid, 10000);
        close $pidfile;
        return $pid if -d "/proc/$pid";
    }
    return 0;
}

1;
