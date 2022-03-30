package Trog::Authz::Base;

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

sub failed ($self, $failed = $self->{'failed'} ) {
    $self->{'failed'} = $failed if defined($failed);
    $self->{'failed'} //= -1;
    return $self->{'failed'};
}

sub headers ($self, @headers) {
    $self->{'headers'} = \@headers if @headers;
    return @{$self->{'headers'}};
}

sub handle_cookie ($self, $cookie) {
    if ($cookie) {
        # TODO secure / sameSite cookie to kill csrf, maybe do rememberme with Expires=~0
        my $secure = '';
        $secure = '; Secure' if $self->{'params'}->{scheme} eq 'https';
        $self->headers(
            "Set-Cookie" => "tcmslogin=$cookie; HttpOnly; SameSite=Strict$secure",
        );
        $self->failed(0);
    }
    return;
}

1;
