package Trog::Config;

use strict;
use warnings;

use Config::Simple;

our $home_cfg = "$ENV{HOME}/.tcms/main.cfg";

sub get {
    my $cf;
    $cf = Config::Simple->new($home_cfg) if -f $home_cfg;
    return $cf if $cf;
    $cf = Config::Simple->new('config/default.cfg');
    return $cf;
}

1;
