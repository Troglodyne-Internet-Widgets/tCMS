package Trog::Config;

use strict;
use warnings;
use feature qw{state};

use FindBin::libs;

use Config::Simple;

=head1 Trog::Config

A thin wrapper around Config::Simple which reads the configuration from the appropriate place.

=head2 Trog::Config::get() = Config::Simple

Returns a configuration object that will be used by server.psgi, the data model and Routing modules.
Memoized, so you will need to HUP the children on config changes.

Reads $home_cfg, falling back to $default when the instance has never saved a
configuration of its own.  Both are full paths relative to the tCMS root, so
that writers can use them too -- an earlier version had the 'config/' prefix
hardcoded here and nowhere else, which meant everything that *wrote* the
configuration put it somewhere get() would never look.

=cut

# Where an instance's own configuration lives, once it has saved one.
our $home_cfg = "config/main.cfg";

# Shipped defaults.  Tracked in git -- never write to this.
our $default = "config/default.cfg";

sub get {
    state $cf;
    return $cf if $cf;
    foreach my $cfg2try ($home_cfg, $default) {
        next unless -f $cfg2try;
        $cf = Config::Simple->new($cfg2try);
        last;
    }
    die "Could not find config file!" unless $cf;
    return $cf;
}

1;
