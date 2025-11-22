package Trog::Config;

use strict;
use warnings;
use feature qw{state};

use FindBin::libs;

use Config::Simple;
use Trog::Log ();

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get() = Config::Simple

Returns a configuration object that will be used by server.psgi, the data model and Routing modules.
Memoized, so you will need to HUP the children on config changes.

=cut

our $home_cfg = "main.cfg";
our $default  = "default.cfg";

sub get {
    state $cf;
    return $cf if $cf;
    foreach my $cfg2try ($home_cfg, $default) {
        next unless -f "config/$cfg2try";
        $cf = Config::Simple->new("config/$cfg2try");
        Trog::Log::INFO("Loaded config file: $home_cfg");
        last;
    }
    return $cf;
}

1;
