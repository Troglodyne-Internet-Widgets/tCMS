package Trog::Auth;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use UUID::Tiny ':std';
use Digest::SHA 'sha256';
use Authen::TOTP;
use Imager::QRCode;
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
    my $dbh = _dbh();
    my $rows = $dbh->selectall_arrayref("SELECT name FROM sess_user WHERE session=?",{ Slice => {} }, $sessid);
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]->{name};
}

=head2 acls4user(STRING username) = ARRAYREF

Return the list of ACLs belonging to the user.
The function of ACLs are to allow you to access content tagged 'private' which are also tagged with the ACL name.

The 'admin' ACL is the only special one, as it allows for authoring posts, configuring tCMS, adding series (ACLs) and more.

=cut

sub acls4user($username) {
    my $dbh = _dbh();
    my $records = $dbh->selectall_arrayref("SELECT acl FROM user_acl WHERE username = ?", { Slice => {} }, $username);
    return () unless ref $records eq 'ARRAY' && @$records;
    my @acls = map { $_->{acl} } @$records;
    return \@acls;
}

=head2 totp(user)

Enable TOTP 2fa for the specified user, or if already enabled return the existing info.
Returns a QR code and URI for pasting into authenticator apps.

=cut

sub totp($user, $domain) {
	my $totp = _totp();
	my $dbh  = _dbh();

	my $failure = 0;
	my $message = "TOTP Secret generated successfully.";

	# Make sure we re-generate the same one in case the user forgot.
	my $secret;
    my $worked = $dbh->selectall_arrayref("SELECT totp_secret FROM user WHERE name = ?", { Slice => {} }, $user);
    if ( ref $worked eq 'ARRAY' && @$worked) {
    	$secret = $worked->[0]{totp_secret};
	}
	$failure = -1 if $secret;

	my $uri = $totp->generate_otp(
		user   => "$user\@$domain",
		issuer => $domain,
		period => 60,
		$secret ? ( secret => $secret ) : (),
	);

	if (!$secret) {
		$secret = $totp->secret();
		$dbh->do("UPDATE user SET totp_secret=? WHERE name=?", undef, $secret, $user) or return (undef, undef, 1, "Failed to store TOTP secret.");
	}

	# This is subsequently served via authenticated _serve() in TCMS.pm
	my $qr = "$user\@$domain.bmp";
	if (!-f "totp/$qr") {
		my $qrcode = Imager::QRCode->new(
			  size          => 4,
			  margin        => 3,
			  level         => 'L',
			  casesensitive => 1,
			  lightcolor    => Imager::Color->new(255, 255, 255),
			  darkcolor     => Imager::Color->new(0, 0, 0),
		);

		my $img = $qrcode->plot($uri);
		$img->write(file => "totp/$qr", type => "bmp") or return(undef, undef, 1, "Could not write totp/$qr: ".$img->errstr);
	}
	return ($uri, $qr, $failure, $message);
}

sub _totp {
    state $totp;
    if (!$totp) {
        my $cfg = Trog::Config->get();
        my $global_secret = $cfg->param('totp.secret');
        die "Global secret must be set in tCMS configuration totp section!" unless $global_secret;
        $totp = Authen::TOTP->new( secret => $global_secret );
        die "Cannot instantiate TOTP client!" unless $totp;
    }
	return $totp;
}

sub clear_totp {
    my $dbh = _dbh();
    $dbh->do("UPDATE user SET totp_secret=null") or die "Could not clear user TOTP secrets";
    #TODO notify users this has happened
}

=head2 mksession(user, pass, token) = STRING

Create a session for the user and waste all other sessions.

Returns a session ID, or blank string in the event the user does not exist or incorrect auth was passed.

=cut

sub mksession ($user, $pass, $token) {
    my $dbh  = _dbh();
	my $totp = _totp();

    # Check the password
    my $records = $dbh->selectall_arrayref("SELECT salt FROM user WHERE name = ?", { Slice => {} }, $user);
    return '' unless ref $records eq 'ARRAY' && @$records;
    my $salt = $records->[0]->{salt};
    my $hash = sha256($pass.$salt);
    my $worked = $dbh->selectall_arrayref("SELECT name, totp_secret FROM user WHERE hash=? AND name = ?", { Slice => {} }, $hash, $user);
    return '' unless ref $worked eq 'ARRAY' && @$worked;
    my $uid = $worked->[0]{name};
    my $secret = $worked->[0]{totp_secret};

    # Validate the 2FA Token.  If we have no secret, allow login so they can see their QR code, and subsequently re-auth.
    if ($secret) {
        my $rc   = $totp->validate_otp(otp => $token, secret => $secret, tolerance => 1);
        return '' unless $rc;
    }

    # Issue cookie
    my $uuid = create_uuid_as_string(UUID_V1, UUID_NS_DNS);
    $dbh->do("INSERT OR REPLACE INTO session (id,username) VALUES (?,?)", undef, $uuid, $uid) or return '';
    return $uuid;
}

=head2 killsession(user) = BOOL

Delete the provided user's session from the auth db.

=cut

sub killsession ($user) {
    my $dbh = _dbh();
    $dbh->do("DELETE FROM session WHERE username=?",undef,$user);
    return 1;
}

=head2 useradd(user, pass) = BOOL

Adds a user identified by the provided password into the auth DB.

Returns True or False (likely false when user already exists).

=cut

sub useradd ($user, $pass, $acls) {
    my $dbh = _dbh();
    my $salt = create_uuid();
    my $hash = sha256($pass.$salt);
    my $res =  $dbh->do("INSERT OR REPLACE INTO user (name,salt,hash) VALUES (?,?,?)", undef, $user, $salt, $hash);
    return unless $res && ref $acls eq 'ARRAY';

    #XXX this is clearly not normalized with an ACL mapping table, will be an issue with large number of users
    foreach my $acl (@$acls) {
        return unless $dbh->do("INSERT OR REPLACE INTO user_acl (username,acl) VALUES (?,?)", undef, $user, $acl);
    }
    return 1;
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh($file,$dbname);
}

1;
