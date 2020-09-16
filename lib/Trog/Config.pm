package Trog::Config;

use strict;
use warnings;

use Config::Simple;

sub get {
    my $cf = {};
    my $home_cfg = "$ENV{HOME}/.tcms/main.cfg"; #XXX probably should pass this in and sanitize ENV
    Config::Simple->import_from($home_cfg, $cf) if -f $home_cfg;
    return $cf if %$cf;
    Config::Simple->import_from('config/default.cfg', $cf);
    return $cf;
}

1;
