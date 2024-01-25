package Trog::Auth;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use FindBin::libs;

use Ref::Util qw{is_arrayref};
use Digest::SHA 'sha256';
use Trog::TOTP;
use Imager::QRCode;

use Trog::Utils;
use Trog::Log qw{:all};
use Trog::Config;
use Trog::SQLite;
use Trog::Data;

=head1 Trog::Auth

An SQLite3 authdb.

=head1 Termination Conditions

Throws exceptions in the event the session database cannot be accessed.

=head1 FUNCTIONS

=head2 session2user(STRING sessid) = STRING

Translate a session UUID into a username.

Returns empty string on no active session.

=cut

sub session2user ($sessid) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM sess_user WHERE session=?", { Slice => {} }, $sessid );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]->{name};
}

=head2 user_has_session

Return whether the user has an active session.
If the user has an active session, things like password reset requests should fail when not coming from said session.

=cut

sub user_has_session ($user) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT session FROM sess_user WHERE name=?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return 1;
}

=head2 user_exists

Return whether the user exists at all.

=cut

sub user_exists ($user) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM user WHERE name=?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return 1;
}

=head2 get_existing_user_data

Fetch existing settings for a user.

=cut

sub get_existing_user_data ($user) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT hash, salt, totp_secret, display_name, contact_email FROM user WHERE name=?", { Slice => {} }, $user );
    return ( undef, undef, undef ) unless ref $rows eq 'ARRAY' && @$rows;
    return ( $rows->[0]{hash}, $rows->[0]{salt}, $rows->[0]{totp_secret}, $rows->[0]{display_name}, $rows->[0]{contact_email} );
}

=head2 email4user(STRING username) = STRING

Return the associated contact email for the user.

=cut

sub email4user ($user) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT contact_email FROM user WHERE name=?", { Slice => {} }, $user );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{contact_email};
}

sub display2username ($display_name) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM user WHERE display_name=?", { Slice => {} }, $display_name );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{name};
}

sub username2display ($name) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT display_name FROM user WHERE name=?", { Slice => {} }, $name );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{display_name};
}

sub username2classname ($name) {
    # Just return the user's post UUID.
    state $data;
    state $conf;
    $conf //= Trog::Config::get();
    $data //= Trog::Data->new($conf);

    state @userposts = $data->get( tags => ['about'], acls => [qw{admin}] );
    # Users are always self-authored, you see

    my $user_obj  = List::Util::first { ( $_->{user} || '' ) eq $name } @userposts;
    my $NNname = $user_obj->{id} || '';
    $NNname =~ tr/-/_/;
    return "a_$NNname";
}
=head2 acls4user(STRING username) = ARRAYREF

Return the list of ACLs belonging to the user.
The function of ACLs are to allow you to access content tagged 'private' which are also tagged with the ACL name.

The 'admin' ACL is the only special one, as it allows for authoring posts, configuring tCMS, adding series (ACLs) and more.

=cut

sub acls4user ($username) {
    my $dbh     = _dbh();
    my $records = $dbh->selectall_arrayref( "SELECT acl FROM user_acl WHERE username = ?", { Slice => {} }, $username );

    return () unless ref $records eq 'ARRAY' && @$records;
    my @acls = map { $_->{acl} } @$records;
    return \@acls;
}

=head2 totp(user, domain)

Enable TOTP 2fa for the specified user, or if already enabled return the existing info.
Returns a QR code and URI for pasting into authenticator apps.

=cut

sub totp ( $user, $domain ) {
    my $totp = _totp();
    my $dbh  = _dbh();

    my $failure = 0;
    my $message = "TOTP Secret generated successfully.";

    # Make sure we re-generate the same one in case the user forgot.
    my $secret;
    my $worked = $dbh->selectall_arrayref( "SELECT totp_secret FROM user WHERE name = ?", { Slice => {} }, $user );
    if ( ref $worked eq 'ARRAY' && @$worked ) {
        $secret = $worked->[0]{totp_secret};
    }
    $failure = -1 if $secret;

    # Generate a new secret if needed
    my $secret_is_generated = 0;
    if ( !$secret ) {
        $secret_is_generated = 1;
        $totp->_valid_secret();
        $secret = $totp->secret();
    }

    my $uri = $totp->generate_otp(
        user   => "$user\@$domain",
        issuer => $domain,

        #XXX verifier apps will only do 30s :(
        period => 30,
        digits => 6,
        secret => $secret,
    );

    my $qr = "$user\@$domain.bmp";
    if ($secret_is_generated) {

        # Liquidate the QR code if it's already there
        unlink "totp/$qr" if -f "totp/$qr";

        $dbh->do( "UPDATE user SET totp_secret=? WHERE name=?", undef, $secret, $user ) or return ( undef, undef, 1, "Failed to store TOTP secret." );
    }

    # This is subsequently served via authenticated _serve() in TCMS.pm
    if ( !-f "totp/$qr" ) {
        my $qrcode = Imager::QRCode->new(
            size          => 4,
            margin        => 3,
            level         => 'L',
            casesensitive => 1,
            lightcolor    => Imager::Color->new( 255, 255, 255 ),
            darkcolor     => Imager::Color->new( 0, 0, 0 ),
        );

        my $img = $qrcode->plot($uri);
        $img->write( file => "totp/$qr", type => "bmp" ) or return ( undef, undef, 1, "Could not write totp/$qr: " . $img->errstr );
    }
    return ( $uri, $qr, $failure, $message, $totp );
}

sub _totp {
    state $totp;
    if ( !$totp ) {
        $totp = Trog::TOTP->new();
        die "Cannot instantiate TOTP client!" unless $totp;
        $totp->{DEBUG} = 1 if is_debug();
    }
    return $totp;
}

=head2 clear_totp

Clear the totp codes for provided user

=cut

sub clear_totp ($user) {
    my $dbh = _dbh();
    my $res = $dbh->do( "UPDATE user SET totp_secret=null WHERE name=?", undef, $user ) or die "Could not clear user TOTP secrets";
    return !!$res;
}

=head2 mksession(user, pass, token) = STRING

Create a session for the user and waste all other sessions.

Returns a session ID, or blank string in the event the user does not exist or incorrect auth was passed.

=cut

sub mksession ( $user, $pass, $token ) {
    my $dbh  = _dbh();
    my $totp = _totp();

    # Check the password
    my $records = $dbh->selectall_arrayref( "SELECT salt FROM user WHERE name = ?", { Slice => {} }, $user );
    return '' unless ref $records eq 'ARRAY' && @$records;
    my $salt   = $records->[0]->{salt};
    my $hash   = sha256( $pass . $salt );
    my $worked = $dbh->selectall_arrayref( "SELECT name, totp_secret FROM user WHERE hash=? AND name = ?", { Slice => {} }, $hash, $user );
    if ( !( ref $worked eq 'ARRAY' && @$worked ) ) {
        INFO("Failed login for user $user");
        return '';
    }
    my $uid    = $worked->[0]{name};
    my $secret = $worked->[0]{totp_secret};

    # Validate the 2FA Token.  If we have no secret, allow login so they can see their QR code, and subsequently re-auth.
    if ($secret) {
        return '' unless $token;
        DEBUG( "TOTP Auth: Sent code $token, expect " . $totp->expected_totp_code(time) );

        #XXX we have to force the secret into compliance, otherwise it generates one on the fly, oof
        $totp->{secret} = $secret;
        my $rc = $totp->validate_otp( otp => $token, secret => $secret, tolerance => 3, period => 30, digits => 6 );
        INFO("TOTP Auth failed for user $user") unless $rc;
        return '' unless $rc;
    }

    # Issue cookie
    my $uuid = Trog::Utils::uuid();
    $dbh->do( "INSERT OR REPLACE INTO session (id,username) VALUES (?,?)", undef, $uuid, $uid ) or return '';
    return $uuid;
}

=head2 killsession(user) = BOOL

Delete the provided user's session from the auth db.

=cut

sub killsession ($user) {
    my $dbh = _dbh();
    $dbh->do( "DELETE FROM session WHERE username=?", undef, $user );
    return 1;
}

=head2 useradd(user, displayname, pass, acls, contactemail) = BOOL

Adds a user identified by the provided password into the auth DB.
Also used to alter users.

Returns True or False (likely false when user already exists).

=cut

sub useradd ( $user, $displayname, $pass, $acls, $contactemail ) {

    # See if the user exists already, keep pw if nothing's passed
    my ( $hash, $salt, $t_secret, $dn, $ce ) = get_existing_user_data($user);
    $displayname  //= $dn;
    $contactemail //= $ce;

    die "No username set!"     unless $user;
    die "No display name set!" unless $displayname;
    die "Username and display name cannot be the same" if $user eq $displayname;
    die "No password set for user!"                    if !$pass && !$hash;
    die "ACLs must be array" unless is_arrayref($acls);
    die "No contact email set for user!" unless $contactemail;

    my $dbh = _dbh();
    if ($pass) {
        $salt = Trog::Utils::uuid();
        $hash = sha256( $pass . $salt );
    }
    my $res = $dbh->do( "INSERT OR REPLACE INTO user (name, display_name, salt, hash, contact_email, totp_secret) VALUES (?,?,?,?,?,?)", undef, $user, $displayname, $salt, $hash, $contactemail, $t_secret );
    return unless $res && ref $acls eq 'ARRAY';

    #XXX this is clearly not normalized with an ACL mapping table, will be an issue with large number of users
    foreach my $acl (@$acls) {
        return unless $dbh->do( "INSERT OR REPLACE INTO user_acl (username,acl) VALUES (?,?)", undef, $user, $acl );
    }
    return 1;
}

sub add_change_request (%args) {
    my $dbh = _dbh();
    my $res = $dbh->do( "INSERT INTO change_request (username,token,type,secret) VALUES (?,?,?,?)", undef, $args{user}, $args{token}, $args{type}, $args{secret} );
    return !!$res;
}

sub process_change_request ($token) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT username, display_name, type, secret, contact_email FROM change_request_full WHERE processed=0 AND token=?", { Slice => {} }, $token );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;

    my $user         = $rows->[0]{username};
    my $display      = $rows->[0]{display_name};
    my $type         = $rows->[0]{type};
    my $secret       = $rows->[0]{secret};
    my $contactemail = $rows->[0]{contact_email};

    state %dispatch = (
        reset_pass => sub {
            my ( $user, $pass ) = @_;

            #XXX The fact that this is an INSERT OR REPLACE means all the entries in change_request for this user will get cascade wiped.  Which is good, as the secrets aren't salted.
            # This is also why we have to snag the user's ACLs or they will be wiped.
            my @acls = acls4user($user);
            useradd( $user, $display, $pass, \@acls, $contactemail ) or do {
                return '';
            };
            killsession($user);
            return "Password set to $pass for $user";
        },
        clear_totp => sub {
            my ($user) = @_;
            clear_totp($user) or do {
                return '';
            };
            killsession($user);
            return "TOTP auth turned off for $user";
        },
    );
    my $res = $dispatch{$type}->( $user, $secret );
    $dbh->do( "UPDATE change_request SET processed=1 WHERE token=?", undef, $token ) or do {
        FATAL("Could not set job with token $token to completed!");
    };
    return $res;
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

1;
