package Trog::Config;

use strict;
use warnings;
use feature qw{state};

use Config::Simple;
use FindBin;
use Cwd;
use File::Basename;
use File::Copy;

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get() = Config::Simple

Returns a configuration object that will be used by server.psgi, the data model and Routing modules.
Memoized, so you will need to HUP the children on config changes.

=cut

# Figure out where the heck we are.
our $home_cfg = "config/main.cfg";
our $home_dir = '';

sub _find_config {
    return if -f $home_cfg;
    $home_dir = Cwd::abs_path($FindBin::Bin);
    # The tCMS main dir will be a parent of this somewhere.
    while ($home_dir ne "/") {
        $home_dir = File::Basename::dirname($home_dir);
        my $default_cfg = "$home_dir/config/default.cfg";
        if (-f $default_cfg) {
            # Found it
            $home_cfg = "$home_dir/config/main.cfg";
            File::Copy::copy($default_cfg, $home_cfg) unless -f $home_cfg;
            return;
        }
    }
    die "Could not find config/default.cfg in any parent folder!";
}

sub home_dir {
    _find_config();
    return $home_dir;
}

sub get {
    # home_cfg will always exist after this.
    _find_config();
    state $cf;
    return $cf                           if $cf;
    $cf = Config::Simple->new($home_cfg);
    return $cf;
}

sub hostname {
    my ($conf, $hostname, $user) = @_;
    if ($hostname) {
        $conf->param('general.hostname', $hostname);
        $conf->save($home_cfg);
    }

    my $domain = $conf->param('general.hostname');
    die "Hostname not set in tCMS configuration.  Please set this first by passing the hostname to bin/tcms-hostname." unless $domain;

    # Transform the domain name into something maximally compatible with being a username.
    if ($user) {
        $domain = substr($domain, 0, 32);
        $domain =~ s/\./-/g;
    }
    return $domain;
}

1;
