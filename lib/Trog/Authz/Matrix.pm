package Trog::Authz::Matrix;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent Trog::Authz::Base;

use constant 'required_params' => [ 'extAuthData' ];

sub do_auth ($self) {
    die "Please setup an admin user first" if !$self->{'params'}{'hasuers'};

    # TODO: Parse json from params->extAuthData, figure it out from there
    $self->{'failed'} = 1;
    return $self;
}

1;
