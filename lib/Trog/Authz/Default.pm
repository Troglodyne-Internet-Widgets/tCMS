package Trog::Authz::Default;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent 'Trog::Authz::Base';

use File::Touch ();
use Trog::Auth  ();
use Trog::Data  ();

use constant 'required_params' => [ 'username', 'password' ];

sub do_auth ($self) {
    if (!$self->{'hasusers'}) {
        # Make the first user
        Trog::Auth::useradd( $self->{'params'}{username}, $self->{'params'}{password}, ['admin'] );
        # Add a stub user page and the initial series.
        _setup_initial_db($self->{'params'}{username});
        # Ensure we stop registering new users
        File::Touch::touch("config/has_users");
    }

    $self->failed(1);
    my @acls = Trog::Auth::acls4user($self->{'params'}{'username'});
    return $self if !@acls; # A user without ACLs can't really do anything, so why login?
    return if grep { $_ eq 'extAuthUser' } @acls; # Return if ext auth user yet on this path (shenanigans)

    my $cookie = Trog::Auth::mksession( $self->{'params'}{username}, $self->{'params'}{password} );
    $self->handle_cookie($cookie);
    return $self;
}

sub _setup_initial_db ($user) {
   my $dat = Trog::Data->new(Trog::Config::get());
   $dat->add(
        {
            "aclname"    => "series",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "Series",
            "href"       => "/series",
            "local_href" => "/series",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar}],
            visibility   => 'public',
            "title"      => "Series",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'series.tx',
            aliases      => [],
        },
        {
            "aclname"    => "about",
            "acls"       => [],
            "callback"   => "Trog::Routes::HTML::series",
            method       => 'GET',
            "data"       => "About",
            "href"       => "/about",
            "local_href" => "/about",
            "preview"    => "/img/sys/testpattern.jpg",
            "tags"       => [qw{series topbar public}],
            visibility   => 'public',
            "title"      => "About",
            user         => $user,
            form         => 'series.tx',
            child_form   => 'profile.tx',
            aliases      => [],
        },
        {
            "aclname"      => "config",
            acls           => [],
            "callback"     => "Trog::Routes::HTML::config",
            'method'       => 'GET',
            "content_type" => "text/html",
            "data"         => "Config",
            "href"         => "/config",
            "local_href"   => "/config",
            "preview"      => "/img/sys/testpattern.jpg",
            "tags"         => [qw{admin}],
            visibility     => 'private',
            "title"        => "Configure tCMS",
            user           => $user,
            aliases        => [],
        },
        {
            title      => $user,
            data       => 'Default user',
            preview    => '/img/avatar/humm.gif',
            wallpaper  => '/img/sys/testpattern.jpg',
            tags       => ['about'],
            visibility => 'public',
            acls       => ['admin'],
            local_href => "/users/$user",
            callback   => "Trog::Routes::HTML::users",
            method     => 'GET',
            user       => $user,
            form       => 'profile.tx',
            aliases    => [],
        },
    );
    return;
}

1;
