package Trog::Data;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

#It's just a factory

sub new( $class, $config ) {
    my $module = "Trog::Data::".$config->param('general.data_model');
    my $req = $module;
    $req =~ s/::/\//g;
    require "$req.pm";
    return $module->new($config);
}

1;
