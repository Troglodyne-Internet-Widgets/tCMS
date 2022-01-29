package Trog::Authz;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use constant 'required_params' => [];

sub new ($class, $params) {
    return 0 if grep { !$params->{$_} } @{$class->required_params()};
    my $self = bless { 'params' => $params }, $class;
    return $self->do_auth();
}

sub do_auth {
    die "Implemented in subclass";
}

sub failed {
    $self->{'failed'} //= -1;
    return $self->{'failed'};
}

1;
