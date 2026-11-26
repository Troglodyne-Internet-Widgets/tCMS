package Trog::Auth;

# ABSTRACT: Users, passwords, sessions, TOTP and the audit log of tCMS, in SQLite

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;

use Ref::Util qw{is_arrayref};
use Digest::SHA 'sha256';
use Crypt::Argon2 qw{argon2id_pass argon2id_verify argon2_needs_rehash};
use Trog::TOTP;
use Imager::QRCode;
use Data::Validate::Domain ();

use Trog::Utils;
use Trog::Log qw{:all};
use Trog::Config;
use Trog::SQLite;
use Trog::Data;

# Ensure the db schema is OK, and give us a handle
my sub dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

=head1 Trog::Auth

An SQLite3 authdb.

=head1 Termination Conditions

Throws exceptions in the event the session database cannot be accessed.

=head1 FUNCTIONS

=head2 session2user($sessid)

Translate a session UUID into a username.

=over 4

=item sessid - Str - the UUID of the session, from the C<tcmslogin> cookie

=back

Returns Str, the name of the user, or an empty string when there is no such
session.

    my $active_user = Trog::Auth::session2user( $cookies->{tcmslogin}->value );

=cut

sub session2user ($sessid) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM sess_user WHERE session=?", { Slice => {} }, $sessid );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]->{name};
}

=head2 user_has_session($user)

Whether the user has an active session.  If the user has an active session,
things like password reset requests should fail when they do not come from
that session.

=over 4

=item user - Str - the name of the user

=back

Returns Bool, 1 when the user has a session, else 0.

    return $tpsgi->forbidden($query) if Trog::Auth::user_has_session($user);

=cut

sub user_has_session ($user) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT session FROM sess_user WHERE name=?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return 1;
}

=head2 user_exists($user)

Whether the user exists at all.

=over 4

=item user - Str - the name of the user

=back

Returns Bool, 1 when the user exists, else 0.

    return $tpsgi->forbidden($query) if !Trog::Auth::user_exists($user);

=cut

sub user_exists ($user) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM user WHERE name=?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return 1;
}

=head2 get_existing_user_data($user)

Fetch the existing settings of a user.  useradd() calls it to keep what the
caller does not pass.

=over 4

=item user - Str - the name of the user

=back

Returns a list of five: the password hash, the salt, the TOTP secret, the
display name and the contact email, each a Str.  When the user does not
exist, it returns a list of three undefs.

    my ( $hash, $salt, $totp_secret, $display_name, $email ) = Trog::Auth::get_existing_user_data($user);

=cut

sub get_existing_user_data ($user) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT hash, salt, totp_secret, display_name, contact_email FROM user WHERE name=?", { Slice => {} }, $user );
    return ( undef, undef, undef ) unless ref $rows eq 'ARRAY' && @$rows;
    return ( $rows->[0]{hash}, $rows->[0]{salt}, $rows->[0]{totp_secret}, $rows->[0]{display_name}, $rows->[0]{contact_email} );
}

=head2 email4user($user)

The contact email of the user.

=over 4

=item user - Str - the name of the user

=back

Returns Str, the contact email, or an empty string when the user does not
exist.

    my $email = Trog::Auth::email4user($user);

=cut

sub email4user ($user) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT contact_email FROM user WHERE name=?", { Slice => {} }, $user );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{contact_email};
}

=head2 display2username($display_name)

The name of the user who has a display name, for a route that names a user by
the display name.

=over 4

=item display_name - Str - the display name of the user

=back

Returns Str, the name of the user, or an empty string when no user has that
display name.

    my $username = Trog::Auth::display2username($display_name);

=cut

sub display2username ($display_name) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM user WHERE display_name=?", { Slice => {} }, $display_name );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{name};
}

=head2 username2display($name)

The display name of a user.

=over 4

=item name - Str - the name of the user

=back

Returns Str, the display name, or an empty string when the user does not
exist.

    my $display_name = Trog::Auth::username2display( $post->{user} );

=cut

sub username2display ($name) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT display_name FROM user WHERE name=?", { Slice => {} }, $name );
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{display_name};
}

=head2 username2classname($name)

A CSS class name for a user, made from the id of the user's post, the post
tagged C<about> whose C<user> is that user.  The first call reads those posts
and keeps them for the life of the process, so a user whose post is made
later gets no id until the process restarts.

=over 4

=item name - Str - the name of the user

=back

Returns Str, C<a_> and the id of the post, with each dash turned into an
underscore.  It is C<a_> alone when the user has no such post.

    my $user_class = Trog::Auth::username2classname( $post->{user} );

=cut

sub username2classname ($name) {

    # Just return the user's post UUID.
    state $data;
    state $conf;
    $conf //= Trog::Config::get();
    $data //= Trog::Data->new($conf);

    state @userposts = $data->get( tags => ['about'], acls => [qw{admin}] );

    # Users are always self-authored, you see

    my $user_obj  = List::Util::first { ( $_->{user} || '' ) eq $name } @userposts;
    my $classname = $user_obj->{id} || '';
    $classname =~ tr/-/_/;
    return "a_$classname";
}

=head2 acls4user($username)

The ACLs of the user.  An ACL lets you access content that is tagged
'private' and also tagged with the name of the ACL.

The 'admin' ACL is the only special one, as it allows for authoring posts,
configuring tCMS, adding series (ACLs) and more.

=over 4

=item username - Str - the name of the user

=back

Returns ArrayRef[Str], the names of the ACLs.  Returns an empty list (undef
in scalar context) when the user has none, so callers write
C<// []>.

    my $acls = Trog::Auth::acls4user($username) // [];

=cut

sub acls4user ($username) {
    my $dbh     = dbh();
    my $records = $dbh->selectall_arrayref( "SELECT acl FROM user_acl WHERE username = ?", { Slice => {} }, $username );

    return () unless ref $records eq 'ARRAY' && @$records;
    my @acls = map { $_->{acl} } @$records;
    return \@acls;
}

my sub _totp {
    state $totp;
    if ( !$totp ) {
        $totp = Trog::TOTP->new();
        die "Cannot instantiate TOTP client!" unless $totp;
        $totp->{DEBUG} = 1 if is_debug();
    }
    return $totp;
}

=head2 totp($user, $domain)

Enable TOTP 2fa for the specified user, or, if it is already enabled, return
the existing enrollment.  It writes the QR code for authenticator apps to
F<totp/E<lt>userE<gt>@E<lt>domainE<gt>.bmp>.

Refuses a user or domain that would not be safe as a filename, as the QR code
is written to that path.

=over 4

=item user - Str - the name of the user

=item domain - Str - the host name of the site, which is the issuer of the
code

=back

Returns a list of five: Str, the C<otpauth:> URI; Str, the file name of the QR
code under F<totp/>; Int, 0 when it made a new secret, -1 when the user already
had one, and 1 on failure; Str, a message; and Trog::TOTP, the client.  On
failure the URI and the file name are undef, the message says why, and there
is no client.  It fails for an unsafe user or domain, when it cannot store a
new secret, and when it cannot write the QR code.

Dies when Trog::TOTP cannot be instantiated.

    my ( $uri, $qr, $failure, $message, $totp ) = Trog::Auth::totp( $active_user, $domain );

=cut

sub totp ( $user, $domain ) {

    # The QR is written to totp/$user@$domain.bmp, so both halves end up in a
    # path.  Nothing constrains a username -- tcms-useradd will take whatever
    # it is given -- so one containing a slash or .. would otherwise write
    # outside totp/ entirely.  Same whitelist Trog::DataSource::Virt uses for
    # guest names.  The domain is a host name, so it has to be one; that also
    # rules out an empty label, which would make a path of dots.
    my ($safe_user)   = ( $user // '' ) =~ m/^([\w.-]+)$/;
    my ($safe_domain) = ( Data::Validate::Domain::is_hostname( $domain // '' ) // '' ) =~ m/^(.+)$/;
    return ( undef, undef, 1, "Refusing to build a TOTP QR for unsafe username '" . ( $user // '' ) . "'." ) unless $safe_user;
    return ( undef, undef, 1, "Refusing to build a TOTP QR for unsafe domain '" . ( $domain // '' ) . "'." ) unless $safe_domain;

    my $totp = _totp();
    my $dbh  = dbh();

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

    my $qr = "$safe_user\@$safe_domain.bmp";
    if ($secret_is_generated) {

        # Liquidate the QR code if it's already there.  Unconditional: unlink
        # returns 0 for a file that was never there, it does not warn or die.
        unlink "totp/$qr";

        eval { $dbh->do( "UPDATE user SET totp_secret=? WHERE name=?", undef, $secret, $user ); 1 } or do {
            WARN("Could not store the TOTP secret of $user: $@");
            return ( undef, undef, 1, "Failed to store TOTP secret." );
        };
    }

    # This is subsequently served via authenticated _serve() in TCMS.pm.
    # Plotted every time rather than only when the file is missing: the QR is a
    # pure function of the secret, so rewriting it produces the same bytes, and
    # the file was just unlinked above whenever the secret changed.
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
    return ( $uri, $qr, $failure, $message, $totp );
}

=head2 has_totp($user)

Whether this user has enrolled in TOTP yet.

Everybody has to, so this is the question the dispatcher asks on the way to
every page a login can reach: a user who has not is sent to /totp and can go
nowhere else until they have.

There is no way to turn it back off.  Losing an authenticator is not a reason to
stop having a second factor, and the answer to it is bin/totp, which re-reads a
user their enrollment out of band -- the secret is still in the database, so it
is the same enrollment rather than a new one.

=over 4

=item user - Str - the name of the user

=back

Returns Bool, 1 when the user has a TOTP secret, else 0.

    $query->{to} = '/totp' unless Trog::Auth::has_totp($username);

=cut

sub has_totp ($user) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT totp_secret FROM user WHERE name=?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{totp_secret} ? 1 : 0;
}

=head2 spend_totp($user, $code)

Check a TOTP code and spend it.  A code that has been spent, or that is older
than one this user has already spent, is refused however valid the arithmetic
says it is.

This is the difference between a second factor at the door and a second factor
that authorizes a particular thing.  A code read over somebody's shoulder, or
left in a proxy log, is good for the rest of its window otherwise -- and what it
would be good for is releasing a stored password, which is not a window anybody
should be relaxed about.

The cost is that a code is worth one action.  Logging in and then immediately
asking for a secret means waiting for the next one, which is thirty seconds and
is the point.

Tolerance is one step either way, for clocks that disagree a little.  It used to
be three, which was ninety seconds of a code staying good, and there is no
reason for that once a code cannot be used twice anyway.

A wrong code and a spent code are each an audit_log row.

=over 4

=item user - Str - the name of the user

=item code - Str - the code, six digits

=back

Returns a list of two: Bool, 1 when the code is right and was not spent, else
0; and Str, why it was refused, or an empty string when it was not.  It
refuses a code that is not six digits, a user with no TOTP secret, a wrong
code, a spent code, and a code that it cannot record as spent.

Dies when Trog::TOTP cannot be instantiated.

    my ( $ok, $why ) = Trog::Auth::spend_totp( $user, $code );

=cut

our $totp_tolerance = 1;
our $totp_period    = 30;
our $totp_digits    = 6;

sub spend_totp ( $user, $code ) {
    return ( 0, 'no code given' ) unless defined $code && $code =~ m/^\d{$totp_digits}$/;

    my $dbh    = dbh();
    my $rows   = $dbh->selectall_arrayref( "SELECT totp_secret FROM user WHERE name=?", { Slice => {} }, $user );
    my $secret = ref $rows eq 'ARRAY' && @$rows ? $rows->[0]{totp_secret} : undef;
    return ( 0, 'this user has no second factor enrolled' ) unless $secret;

    # Forced in rather than passed: expected_totp_code reads the object, and
    # the object generates a secret of its own if it has not got one.
    my $totp = _totp();
    $totp->{secret} = $secret;
    $totp->{period} = $totp_period;
    $totp->{digits} = $totp_digits;

    my $now = time();
    my $matched;
    foreach my $offset ( -$totp_tolerance .. $totp_tolerance ) {
        my $when = $now + ( $offset * $totp_period );
        next unless $totp->expected_totp_code($when) eq $code;
        $matched = int( $when / $totp_period );
        last;
    }

    if ( !defined $matched ) {
        log_event( 'totp_failure', $user );
        return ( 0, 'that code is not right' );
    }

    my $spent = $dbh->selectall_arrayref( "SELECT step FROM totp_spent WHERE username=?", { Slice => {} }, $user );
    my $last  = ref $spent eq 'ARRAY' && @$spent ? $spent->[0]{step} : 0;
    if ( $matched <= $last ) {
        log_event( 'totp_replay', $user );
        return ( 0, 'that code has already been used; wait for the next one' );
    }

    eval { $dbh->do( "INSERT OR REPLACE INTO totp_spent (username, step) VALUES (?,?)", undef, $user, $matched ); 1 } or do {
        WARN("Could not record the TOTP step of $user as spent: $@");
        return ( 0, 'could not record the code as used, so it is refused' );
    };

    return ( 1, '' );
}

=head2 check_password($user, $pass)

Whether this is the password of the user, upgrading how it is stored if it is.

Passwords were kept as a single unstretched sha256 of the password and a salt,
which is a hash built to be fast over a thing built to be guessed: a commodity
GPU walks a list of them at billions a second.  They are Argon2id now, which is
built to be slow and to want memory, so the same list costs real hardware and
real time.

Both live in the same column.  An Argon2 hash says what it is in its first few
characters, so a row that does not is the old kind: it is checked the old way,
and then, having just been handed a correct password in plaintext for the only
moment anyone ever will be, rewritten as the new kind.  Nobody is logged out and
nobody has to be told, and the old hashes leave as their owners come back.

The same rewrite happens when the parameters here are raised, which is what
makes raising them later a one-line change rather than a migration.

=over 4

=item user - Str - the name of the user

=item pass - Str - the password to check, in plaintext

=back

Returns Bool, 1 when the password is right, else 0.  It is 0 for an empty
password and for a user who does not exist.

    my $ok = Trog::Auth::check_password( $user, $pass );

=cut

# OWASP's minimum acceptable Argon2id configuration.  Deliberately not their
# generous one: /auth takes a password from anybody who asks, so what is on the
# other side of it is a memory allocation an unauthenticated request can ask
# for, times however many workers are listening.
our $argon2_time    = 2;
our $argon2_memory  = '19456k';
our $argon2_lanes   = 1;
our $argon2_tag     = 32;
our $argon2_saltlen = 16;

# The hash and the salt that goes with it.  Argon2 carries the salt in its own
# encoding as well; the column keeps it because the rows which have not been
# upgraded yet are still using it for what it was for.
my sub hash_password ($pass) {
    my $salt = Trog::Utils::uuid();
    $salt = substr( $salt, 0, $argon2_saltlen );
    return ( argon2id_pass( $pass, $salt, $argon2_time, $argon2_memory, $argon2_lanes, $argon2_tag ), $salt );
}

my sub store_password ( $user, $pass ) {
    my ( $hash, $salt ) = hash_password($pass);
    my $dbh = dbh();
    $dbh->do( "UPDATE user SET hash=?, salt=? WHERE name=?", undef, $hash, $salt, $user );
    return 1;
}

sub check_password ( $user, $pass ) {
    return 0 unless $pass;

    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT hash, salt FROM user WHERE name = ?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;

    my ( $hash, $salt ) = ( $rows->[0]{hash}, $rows->[0]{salt} );
    return 0 unless $hash;

    if ( index( $hash, '$argon2' ) == 0 ) {
        return 0 unless eval { argon2id_verify( $hash, $pass ) };

        # Cheap, and it is the only time we hold the password, so it is the only
        # time the cost of a stronger hash can be paid.
        store_password( $user, $pass )
          if argon2_needs_rehash( $hash, 'argon2id', $argon2_time, $argon2_memory, $argon2_lanes, $argon2_tag, $argon2_saltlen );
        return 1;
    }

    return 0 unless sha256( $pass . ( $salt // '' ) ) eq $hash;
    INFO("Upgrading the stored password for $user from sha256 to argon2id");
    store_password( $user, $pass );
    return 1;
}

=head2 mksession($user, $pass, $token, $ip_addr)

Create a session for the user and waste all other sessions.  The TOTP code is
checked and spent only when the user has enrolled.  Each login and each
failure is an audit_log row.

=over 4

=item user - Str - the name of the user

=item pass - Str - the password, in plaintext

=item token - Str - the TOTP code

=item ip_addr - Str - where the login comes from, for the audit log.  The
default is an empty string.

=back

Returns Str, the new session ID, or an empty string when the user does not
exist, the password is wrong, or the TOTP code is refused.

    my $cookie = Trog::Auth::mksession( $username, $password, $token, $ip );

=cut

sub mksession ( $user, $pass, $token, $ip_addr = '' ) {
    my $dbh = dbh();

    my $records = $dbh->selectall_arrayref( "SELECT name, hash, salt, totp_secret FROM user WHERE name = ?", { Slice => {} }, $user );
    if ( !( ref $records eq 'ARRAY' && @$records ) || !check_password( $user, $pass ) ) {
        INFO("Failed login for user $user");
        log_event( 'login_failure', $user, $ip_addr );
        return '';
    }
    my $uid    = $records->[0]{name};
    my $secret = $records->[0]{totp_secret};

    # No secret means they have not enrolled yet, and letting them in is how
    # they get to -- the enrolment page is behind a login, since the QR on it is
    # the secret.  TCMS::needs_enrolment is what stops that being a way to have
    # an account with no second factor: it is the only page they can reach.
    if ($secret) {
        my ( $ok, $why ) = spend_totp( $user, $token );
        if ( !$ok ) {
            INFO("TOTP auth failed for user $user: $why");
            log_event( 'totp_failure', $user, $ip_addr );
            return '';
        }
    }

    # Issue cookie
    my $uuid = Trog::Utils::uuid();
    $dbh->do( "INSERT OR REPLACE INTO session (id,username) VALUES (?,?)", undef, $uuid, $uid );
    log_event( 'login_success', $user, $ip_addr, $uuid );
    return $uuid;
}

=head2 killsession($user, $ip_addr)

Delete the session of the user from the auth db.  The logout is an audit_log
row.

=over 4

=item user - Str - the name of the user

=item ip_addr - Str - where the logout comes from, for the audit log.  The
default is an empty string.

=back

Returns 1, also when the user had no session.

    Trog::Auth::killsession( $user, $ip );

=cut

sub killsession ( $user, $ip_addr = '' ) {
    my $dbh = dbh();
    $dbh->do( "DELETE FROM session WHERE username=?", undef, $user );
    log_event( 'logout', $user, $ip_addr );
    return 1;
}

=head2 useradd($user, $displayname, $pass, $acls, $contactemail)

Adds a user identified by the provided password into the auth DB.  Also used
to alter users.  An undef display name, password or contact email keeps the
one that the user has.

To alter a user, it replaces the row of the user.  That deletes everything in
the auth DB that refers to the user: the session, the change requests, the
ACLs, the secrets of Trog::Vault and the spent TOTP steps.  It writes the ACLs
in $acls back, and keeps the TOTP secret.

=over 4

=item user - Str - the name of the user

=item displayname - Str - the display name.  It must differ from the name
of the user.

=item pass - Str - the password, in plaintext

=item acls - ArrayRef[Str] - the names of the ACLs of the user

=item contactemail - Str - the contact email of the user

=back

Returns 1.

Dies when there is no name, no display name, or no contact email, when the
name and the display name are the same, when a new user has no password, when
$acls is not an ArrayRef, and when the user cannot be stored, as the rest of
this module does when the auth database fails.

    Trog::Auth::useradd( $username, $display_name, $password, ['admin'], $contact_email );

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
    die "ACLs must be array"             unless is_arrayref($acls);
    die "No contact email set for user!" unless $contactemail;

    my $dbh = dbh();
    ( $hash, $salt ) = hash_password($pass) if $pass;
    $dbh->do( "INSERT OR REPLACE INTO user (name, display_name, salt, hash, contact_email, totp_secret) VALUES (?,?,?,?,?,?)", undef, $user, $displayname, $salt, $hash, $contactemail, $t_secret );

    #XXX this is clearly not normalized with an ACL mapping table, will be an issue with large number of users
    foreach my $acl (@$acls) {
        $dbh->do( "INSERT OR REPLACE INTO user_acl (username,acl) VALUES (?,?)", undef, $user, $acl );
    }
    return 1;
}

=head2 reset_password($user, $pass)

Give an existing user a new password, and end their session.  The user keeps
their display name, contact address, ACLs and TOTP enrollment.  It calls
useradd(), so the change requests, the secrets of Trog::Vault and the spent
TOTP steps of the user are deleted too.

=over 4

=item user - Str - the name of the user

=item pass - Str - the new password, in plaintext

=back

Returns Bool, 1 when the password is changed.  Returns 0, and changes
nothing, if the user does not exist or the password is empty.

Dies when useradd() dies.

    my $ok = Trog::Auth::reset_password( $user, $password );

=cut

sub reset_password ( $user, $pass ) {
    return 0 unless user_exists($user) && $pass;

    # useradd() replaces the user row, which cascades to user_acl, so the ACLs go back in with it.
    useradd( $user, undef, $pass, acls4user($user) // [], undef );
    killsession($user);
    return 1;
}

=head2 add_change_request(%args)

Record a change that the owner of the token can make to the user later.  The
new password is not stored: process_change_request() takes it.

=over 4

=item user - Str - the name of the user

=item token - Str - the token that authorizes the change, a UUID

=item type - Str - the kind of change.  The one kind is C<reset_pass>.

=back

Returns 1.

    my $res = Trog::Auth::add_change_request( type => 'reset_pass', user => $user, token => $token );

=cut

sub add_change_request (%args) {
    my $dbh = dbh();
    $dbh->do( "INSERT INTO change_request (username,token,type) VALUES (?,?,?)", undef, $args{user}, $args{token}, $args{type} );
    return 1;
}

=head2 process_change_request($token, $secret)

Make the change that the token was issued for, with the secret as the new
password, and spend the token.

=over 4

=item token - Str - the token of the change request

=item secret - Str - the new password, in plaintext

=back

Returns Str, a message that names the user and not the secret.  Returns 0,
and leaves the token unspent, if there is no unspent request for the token,
or if the secret is empty.

Dies when the request is of a type other than C<reset_pass>, and when
reset_password() dies.

    my $done = Trog::Auth::process_change_request( $token, $password );

=cut

sub process_change_request ( $token, $secret ) {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT username, type FROM change_request WHERE processed=0 AND token=?", { Slice => {} }, $token );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;

    my ( $user, $type ) = @{ $rows->[0] }{qw{username type}};
    my %dispatch = ( reset_pass => sub ( $name, $pass ) { return reset_password( $name, $pass ) ? "Password changed for $name" : 0 } );

    my $res = $dispatch{$type}->( $user, $secret ) or return 0;

    # Usually a no-op: the useradd() inside reset_password() cascades every request of the user away.
    eval { $dbh->do( "UPDATE change_request SET processed=1 WHERE token=?", undef, $token ); 1 } or do {
        FATAL("Could not set job with token $token to completed: $@");
    };
    return $res;
}

=head2 audit_log(%opts)

Recent authentication events, newest first.

=over 4

=item username - Str - only the events of this user.  A false value does not
filter.

=item event_type - Str - only the events of this type, such as
C<login_failure>.  A false value does not filter.

=item limit - Int - the most events to return.  The default is 100.

=back

Returns ArrayRef[HashRef], one HashRef per event, with the keys C<id>,
C<event_time>, C<username>, C<session_id>, C<ip_addr> and C<event_type>.

    my $events = Trog::Auth::audit_log( limit => 50, username => $user );

=cut

sub audit_log (%opts) {
    my $dbh   = dbh();
    my $limit = int( $opts{limit} // 100 );
    my @where;
    my @bind;

    if ( $opts{username} ) {
        push @where, 'username = ?';
        push @bind,  $opts{username};
    }
    if ( $opts{event_type} ) {
        push @where, 'event_type = ?';
        push @bind,  $opts{event_type};
    }

    my $where = @where ? 'WHERE ' . join( ' AND ', @where ) : '';
    my $rows  = $dbh->selectall_arrayref(
        ## no critic(ValuesAndExpressions::PreventSQLInjection)
        "SELECT id, event_time, username, session_id, ip_addr, event_type FROM audit_log $where ORDER BY event_time DESC LIMIT ?",
        { Slice => {} }, @bind, $limit
    );
    return [] unless ref $rows eq 'ARRAY';
    return $rows;
}

=head2 log_event($event_type, $username, $ip_addr, $session_id)

Write one row to the audit log.

Public because the vault writes to it too: reading somebody's stored password is
the same kind of event as logging in as them, and it belongs in the same list.

Swallows its own errors.  A login that fails because the audit table is unhappy
would be a worse outcome than a login nobody wrote down.

=over 4

=item event_type - Str - what happened, such as C<login_success>

=item username - Str - the name of the user it happened to

=item ip_addr - Str - where it came from.  The default is an empty string.

=item session_id - Str - the session, if there is one.  The default is undef.

=back

Returns nothing.

    Trog::Auth::log_event( 'secret_read', $user );

=cut

sub log_event ( $event_type, $username, $ip_addr = '', $session_id = undef ) {
    eval {
        my $dbh = dbh();
        $dbh->do(
            "INSERT INTO audit_log (event_time, username, session_id, ip_addr, event_type) VALUES (?,?,?,?,?)",
            undef, time(), $username, $session_id, $ip_addr, $event_type
        );
        1;
    } or WARN("audit_log insert failed: $@");
    return;
}

=head2 users_with_emails()

All users who have a contact email, for use in libravatar lookups.

Returns ArrayRef[HashRef], one HashRef per user, with the keys C<name> and
C<contact_email>.

    my $users = Trog::Auth::users_with_emails();

=cut

#XXX it may be worth using the sqlite extension to do SHA hashing here to speed up lookups.
sub users_with_emails {
    my $dbh  = dbh();
    my $rows = $dbh->selectall_arrayref(
        "SELECT name, contact_email FROM user WHERE contact_email IS NOT NULL AND contact_email != ''",
        { Slice => {} }
    );
    return ref $rows eq 'ARRAY' ? $rows : [];
}

1;
