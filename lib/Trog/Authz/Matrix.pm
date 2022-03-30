package Trog::Authz::Matrix;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use parent 'Trog::Authz::Base';

use Trog::Auth ();
use HTTP::Tiny ();

use constant 'required_params' => [ 'extAuthData' ];

sub do_auth ($self) {
    die "Please setup an admin user first" if !$self->{'params'}{'hasuers'};
    $self->failed(1);

    require JSON::XS;
    my $decoded;
    eval { $decoded = JSON::XS::decode_json($self->{'params'}{'extAuthData'}); };
    return $self if !$decoded;

    # XXX TODO potential security/DOS issue -- How does one prevent spoofing on this end?
    # For example, user POSTs the json blob with the right param names, etc. but no
    # actual auth gating -- Suddenly you have a user and session more or less out of
    # whole cloth with no auth ever done. Only thing I can think of to prevent this
    # is more or less "after the fact" via calling `isSignedIn()` as part of pageload
    # when you are a matrix user, invalidating the session if not.
    # I'm sure you can already tell the hole in this perfect plan -- "just disable js".
    # The only real way I can think of for now to prevent abuse here is to do a check
    # on the backend using the access token and user just to do some kind of ping check.
    # That said this still just makes it "harder" to pull off bullshit. Only way to be
    # 100% sure we are talking to a matrix server would be to do it all on the backend.
    # That said, this is probably "good enough" for now.
    my $ping_url = $decoded->{'well_known'}{'m.homeserver'}{'base_url'};
    $ping_url .= "/_matrix/client/r0/presence/$decoded->{'user_id'}/status";
    $ping_url .= "?access_token=$decoded->{'access_token'}";
    my $resp = HTTP::Tiny->new->get($ping_url);
    return $self unless $resp->{'success'};

    # I'm using ACLs here as a proxy for the user existing.
    # That may? be a bad assumption. If so I need to make another sub for getting this.
    my @acls = Trog::Auth::acls4user($decoded->{user_id});
    if(!@acls) {

        # Create the user XXX TODO -- Have a config param for "extra" ACLs the admin
        # can assign in the UI/Config in order to give them other "default" ACLs like
        # access to private content or ability to comment on articles, etc.
        my $cfg = Trog::Config::get();
        Trog::Auth::useradd(
            $decoded->{user_id},
            'Matrix', # Never used here, so just put in the ext auth provider name.
            [ 'extAuthUser' ], # This ACL is important, and should be non-removable.
        );
        my $dat = Trog::Data->new($cfg);
        $dat->add(
            {
                title      => $decoded->{user_id},
                data       => $decoded->{displayname},
                preview    => $decoded->{avatar_content},
                wallpaper  => '/img/sys/testpattern.jpg',
                tags       => ['about'],
                visibility => 'public',
                acls       => ['admin'],
                local_href => "/users/$decoded->{user_id}",
                callback   => "Trog::Routes::HTML::users",
                method     => 'GET',
                user       => $decoded->{user_id},
                form       => 'profile.tx',
                aliases    => [],
            },
        );

    }

    # Check if banned
    return $self if grep { $_ eq 'banned' } @acls;

    my $cookie = Trog::Auth::mksession( $decoded->{user_id}, 'Matrix' );
    $self->handle_cookie($cookie);

    $self->failed(0);
    return $self;
}

1;
