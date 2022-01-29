package Trog::Authz::Default;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent Trog::Authz::Base;

use constant 'required_params' => [ 'username', 'password' ];

sub do_auth ($self) {
    if (!$self->{'hasusers'}) {
        # Make the first user
        Trog::Auth::useradd($self->{'params'}->{username}, $self->{'params'}->{password}, ['admin'] );
        # Add a stub user page and the initial series.
        my $dat = Trog::Data->new($conf);
        _setup_initial_db($dat,$self->{'params'}->{username});
        # Ensure we stop registering new users
        File::Touch::touch("config/has_users");
    }

    $self->{failed} = 1;
    my $cookie = Trog::Auth::mksession( 'Default', $self->{'params'}->{username}, $self->{'params'}->{password});
    if ($cookie) {
        # TODO secure / sameSite cookie to kill csrf, maybe do rememberme with Expires=~0
        my $secure = '';
        $secure = '; Secure' if $self->{'params'}->{scheme} eq 'https';
        @headers = (
            "Set-Cookie" => "tcmslogin=$cookie; HttpOnly; SameSite=Strict$secure",
        );
        $self->{failed} = 0;
    }
    return $self;
}

1;
