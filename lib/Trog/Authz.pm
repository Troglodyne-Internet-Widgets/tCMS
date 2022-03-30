package Trog::Authz;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use constant 'valid_modules'   => [ 'Default', 'Matrix' ];

sub do_auth_for ($module, $params) {
    die "Invalid authorization class" if !grep { $module eq $_ } @{__PACKAGE__->valid_modules()};
    my $class = "Trog::Authz::$module";
    eval "require $class";
    die $@ if $@;
    return $class->new($params);
}

1;
