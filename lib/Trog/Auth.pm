package Trog::Auth;

use v5.36;
use re '/aa';

use FindBin::libs;

use Ref::Util qw{is_arrayref};
use Digest::SHA 'sha256';
use Crypt::Argon2 qw{argon2id_pass argon2id_verify argon2_needs_rehash};
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

=head2 primary_user

Returns the oldest user with the admin ACL.

=cut

sub primary_user {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT username FROM user_acl WHERE acl='admin' LIMIT 1", { Slice => {} } );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{username};
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

    my $user_obj = List::Util::first { ( $_->{user} || '' ) eq $name } @userposts;
    my $NNname   = $user_obj->{id} || '';
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

Refuses a user or domain that would not be safe as a filename, as the QR code
is written to totp/<user>@<domain>.bmp.

=cut

sub totp ( $user, $domain ) {

    # The QR is written to totp/$user@$domain.bmp, so both halves end up in a
    # path.  Nothing constrains a username -- tcms-useradd will take whatever
    # it is given -- so one containing a slash or .. would otherwise write
    # outside totp/ entirely.  Same whitelist Trog::DataSource::Virt uses for
    # guest names.
    my ($safe_user)   = ( $user   // '' ) =~ m/^([A-Za-z0-9._-]+)$/;
    my ($safe_domain) = ( $domain // '' ) =~ m/^([A-Za-z0-9._-]+)$/;
    return ( undef, undef, 1, "Refusing to build a TOTP QR for unsafe username '" . ( $user // '' ) . "'." ) unless $safe_user;
    return ( undef, undef, 1, "Refusing to build a TOTP QR for unsafe domain '" . ( $domain // '' ) . "'." ) unless $safe_domain;

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

    my $qr = "$safe_user\@$safe_domain.bmp";
    if ($secret_is_generated) {

        # Liquidate the QR code if it's already there.  Unconditional: unlink
        # returns 0 for a file that was never there, it does not warn or die.
        unlink "totp/$qr";

        $dbh->do( "UPDATE user SET totp_secret=? WHERE name=?", undef, $secret, $user ) or return ( undef, undef, 1, "Failed to store TOTP secret." );
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

sub _totp {
    state $totp;
    if ( !$totp ) {
        $totp = Trog::TOTP->new();
        die "Cannot instantiate TOTP client!" unless $totp;
        $totp->{DEBUG} = 1 if is_debug();
    }
    return $totp;
}

=head2 has_totp(user) = BOOL

Whether this user has enrolled in TOTP yet.

Everybody has to, so this is the question the dispatcher asks on the way to
every page a login can reach: a user who has not is sent to /totp and can go
nowhere else until they have.

There is no way to turn it back off.  Losing an authenticator is not a reason to
stop having a second factor, and the answer to it is bin/totp, which re-reads a
user their enrolment out of band -- the secret is still in the database, so it
is the same enrolment rather than a new one.

=cut

sub has_totp ($user) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT totp_secret FROM user WHERE name=?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]{totp_secret} ? 1 : 0;
}

=head2 spend_totp(user, code) = ($ok, $why)

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

=cut

our $totp_tolerance = 1;
our $totp_period    = 30;
our $totp_digits    = 6;

sub spend_totp ( $user, $code ) {
    return ( 0, 'no code given' ) unless defined $code && $code =~ m/^[0-9]{$totp_digits}$/;

    my $dbh    = _dbh();
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

    $dbh->do( "INSERT OR REPLACE INTO totp_spent (username, step) VALUES (?,?)", undef, $user, $matched )
      or return ( 0, 'could not record the code as used, so it is refused' );

    return ( 1, '' );
}

=head2 check_password(user, pass) = BOOL

Whether this is the user's password, upgrading how it is stored if it is.

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

sub check_password ( $user, $pass ) {
    return 0 unless defined $pass && length($pass);

    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref( "SELECT hash, salt FROM user WHERE name = ?", { Slice => {} }, $user );
    return 0 unless ref $rows eq 'ARRAY' && @$rows;

    my ( $hash, $salt ) = ( $rows->[0]{hash}, $rows->[0]{salt} );
    return 0 unless defined $hash && length($hash);

    if ( index( $hash, '$argon2' ) == 0 ) {
        return 0 unless eval { argon2id_verify( $hash, $pass ) };

        # Cheap, and it is the only time we hold the password, so it is the only
        # time the cost of a stronger hash can be paid.
        _store_password( $user, $pass )
          if argon2_needs_rehash( $hash, 'argon2id', $argon2_time, $argon2_memory, $argon2_lanes, $argon2_tag, $argon2_saltlen );
        return 1;
    }

    return 0 unless sha256( $pass . ( $salt // '' ) ) eq $hash;
    INFO("Upgrading the stored password for $user from sha256 to argon2id");
    _store_password( $user, $pass );
    return 1;
}

# The hash and the salt that goes with it.  Argon2 carries the salt in its own
# encoding as well; the column keeps it because the rows which have not been
# upgraded yet are still using it for what it was for.
sub _hash_password ($pass) {
    my $salt = Trog::Utils::uuid();
    $salt = substr( $salt, 0, $argon2_saltlen );
    return ( argon2id_pass( $pass, $salt, $argon2_time, $argon2_memory, $argon2_lanes, $argon2_tag ), $salt );
}

sub _store_password ( $user, $pass ) {
    my ( $hash, $salt ) = _hash_password($pass);
    my $dbh = _dbh();
    return $dbh->do( "UPDATE user SET hash=?, salt=? WHERE name=?", undef, $hash, $salt, $user ) ? 1 : 0;
}

=head2 mksession(user, pass, token) = STRING

Create a session for the user and waste all other sessions.

Returns a session ID, or blank string in the event the user does not exist or incorrect auth was passed.

=cut

sub mksession ( $user, $pass, $token, $ip_addr = '' ) {
    my $dbh = _dbh();

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
    $dbh->do( "INSERT OR REPLACE INTO session (id,username) VALUES (?,?)", undef, $uuid, $uid ) or return '';
    log_event( 'login_success', $user, $ip_addr, $uuid );
    return $uuid;
}

=head2 killsession(user) = BOOL

Delete the provided user's session from the auth db.

=cut

sub killsession ( $user, $ip_addr = '' ) {
    my $dbh = _dbh();
    $dbh->do( "DELETE FROM session WHERE username=?", undef, $user );
    log_event( 'logout', $user, $ip_addr );
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
    die "ACLs must be array"             unless is_arrayref($acls);
    die "No contact email set for user!" unless $contactemail;

    my $dbh = _dbh();
    ( $hash, $salt ) = _hash_password($pass) if $pass;
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
    );
    my $res = $dispatch{$type}->( $user, $secret );
    $dbh->do( "UPDATE change_request SET processed=1 WHERE token=?", undef, $token ) or do {
        FATAL("Could not set job with token $token to completed!");
    };
    return $res;
}

=head2 audit_log(%opts) = ARRAYREF

Return recent authentication events.
Supports filtering by C<username>, C<event_type>, and C<limit> (default 100).

=cut

sub audit_log (%opts) {
    my $dbh   = _dbh();
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

=cut

sub log_event ( $event_type, $username, $ip_addr = '', $session_id = undef ) {
    eval {
        my $dbh = _dbh();
        $dbh->do(
            "INSERT INTO audit_log (event_time, username, session_id, ip_addr, event_type) VALUES (?,?,?,?,?)",
            undef, time(), $username, $session_id, $ip_addr, $event_type
        );
    };
    WARN("audit_log insert failed: $@") if $@;
    return;
}

=head2 users_with_emails() = ARRAYREF

Return all users and their contact emails, for use in libravatar lookups.

=cut

#XXX it may be worth using the sqlite extension to do SHA hashing here to speed up lookups.
sub users_with_emails {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref(
        "SELECT name, contact_email FROM user WHERE contact_email IS NOT NULL AND contact_email != ''",
        { Slice => {} }
    );
    return ref $rows eq 'ARRAY' ? $rows : [];
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

1;
