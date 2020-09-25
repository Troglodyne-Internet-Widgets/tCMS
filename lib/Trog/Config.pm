package Trog::Config;

use strict;
use warnings;

use Config::Simple;

sub get {
    my $cf;
    my $home_cfg = "$ENV{HOME}/.tcms/main.cfg"; #XXX probably should pass this in and sanitize ENV
    $cf = Config::Simple->new($home_cfg) if -f $home_cfg;
    return $cf if $cf;
    $cf = Config::Simple->new('config/default.cfg');
    return $cf;
}

1;
