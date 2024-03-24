package Trog::Config;

use strict;
use warnings;
use feature qw{state};

use Config::Simple;

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get() = Config::Simple

Returns a configuration object that will be used by server.psgi, the data model and Routing modules.
Memoized, so you will need to HUP the children on config changes.

=cut

our $home_cfg = "config/main.cfg";

sub get {
    state $cf;
    return $cf if $cf;
    $cf = Config::Simple->new($home_cfg) if -f $home_cfg;
    return $cf if $cf;
    $cf = Config::Simple->new('config/default.cfg');
    return $cf;
}

1;
