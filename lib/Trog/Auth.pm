package Trog::Auth;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use UUID::Tiny ':std';
use Digest::SHA 'sha256';
use Authen::TOTP;
use Imager::QRCode;

use Trog::Log qw{:all};
use Trog::Config;
use Trog::SQLite;

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

    my $uri = $totp->generate_otp(
        user   => "$user\@$domain",
        issuer => $domain,

        #XXX verifier apps will only do 30s :(
        period => 30,
        digits => 6,
        $secret ? ( secret => $secret ) : (),
    );

    my $qr = "$user\@$domain.bmp";
    if ( !$secret ) {
        # Liquidate the QR code if it's already there
        unlink "totp/$qr" if -f "totp/$qr";
        $secret = $totp->secret();
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
            darkcolor     => Imager::Color->new( 0,   0,   0 ),
        );

        my $img = $qrcode->plot($uri);
        $img->write( file => "totp/$qr", type => "bmp" ) or return ( undef, undef, 1, "Could not write totp/$qr: " . $img->errstr );
    }
    return ( $uri, $qr, $failure, $message );
}

sub _totp {
    state $totp;
    if ( !$totp ) {
        my $cfg           = Trog::Config->get();
        my $global_secret = $cfg->param('totp.secret');
        die "Global secret must be set in tCMS configuration totp section!" unless $global_secret;
        $totp = Authen::TOTP->new( secret => $global_secret );
        die "Cannot instantiate TOTP client!" unless $totp;
        $totp->{DEBUG} = 1 if is_debug();
    }
    return $totp;
}

=head2 expected_totp_code(totp, secret, when, digits)

Return the expected totp code at a given time with a given secret.

=cut

#XXX authen::totp does not expose this, sigh
sub expected_totp_code {
    my ( $self, $secret, $when, $digits ) = @_;
    $self //= _totp();
    $when   //= time;
    my $period  = 30;
    $digits //= 6;
    $self->{secret} = $secret;

    my $T  = sprintf( "%016x", int( $when / $period ) );
    my $Td = pack( 'H*', $T );

    my $hmac = $self->hmac($Td);

    # take the 4 least significant bits (1 hex char) from the encrypted string as an offset
    my $offset = hex( substr( $hmac, -1 ) );

    # take the 4 bytes (8 hex chars) at the offset (* 2 for hex), and drop the high bit
    my $encrypted = hex( substr( $hmac, $offset * 2, 8 ) ) & 0x7fffffff;

    return sprintf( "%0" . $digits . "d", ( $encrypted % ( 10**$digits ) ) );
}

=head2 clear_totp

Clear the totp codes for all users

=cut

sub clear_totp {
    my $dbh = _dbh();
    $dbh->do("UPDATE user SET totp_secret=null") or die "Could not clear user TOTP secrets";

    #TODO notify users this has happened
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
    if (!(ref $worked eq 'ARRAY' && @$worked)) {
        INFO("Failed login for user $user");
        return '';
    }
    my $uid    = $worked->[0]{name};
    my $secret = $worked->[0]{totp_secret};

    # Validate the 2FA Token.  If we have no secret, allow login so they can see their QR code, and subsequently re-auth.
    if ($secret) {
        return '' unless $token;
        DEBUG("TOTP Auth: Sent code $token, expect ".expected_totp_code($totp, $secret));
        #XXX we have to force the secret into compliance, otherwise it generates one on the fly, oof
        $totp->{secret} = $secret;
        my $rc = $totp->validate_otp( otp => $token, secret => $secret, tolerance => 3, period => 30, digits => 6 );
        INFO("TOTP Auth failed for user $user") unless $rc;
        return '' unless $rc;
    }

    # Issue cookie
    my $uuid = create_uuid_as_string( UUID_V1, UUID_NS_DNS );
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

=head2 useradd(user, pass) = BOOL

Adds a user identified by the provided password into the auth DB.

Returns True or False (likely false when user already exists).

=cut

sub useradd ( $user, $pass, $acls ) {
    my $dbh  = _dbh();
    my $salt = create_uuid();
    my $hash = sha256( $pass . $salt );
    my $res  = $dbh->do( "INSERT OR REPLACE INTO user (name,salt,hash) VALUES (?,?,?)", undef, $user, $salt, $hash );
    return unless $res && ref $acls eq 'ARRAY';

    #XXX this is clearly not normalized with an ACL mapping table, will be an issue with large number of users
    foreach my $acl (@$acls) {
        return unless $dbh->do( "INSERT OR REPLACE INTO user_acl (username,acl) VALUES (?,?)", undef, $user, $acl );
    }
    return 1;
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

1;
