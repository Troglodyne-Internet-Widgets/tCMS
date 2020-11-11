package Trog::Config;

use strict;
use warnings;

use Config::Simple;

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get() = Config::Simple

Returns a configuration object that will be used by server.psgi, the data model and Routing modules.

=cut

our $home_cfg = "$ENV{HOME}/.tcms/main.cfg";

sub get {
    my $cf;
    $cf = Config::Simple->new($home_cfg) if -f $home_cfg;
    return $cf if $cf;
    $cf = Config::Simple->new('config/default.cfg');
    return $cf;
}

1;
