package Trog::Vault;

use v5.36;
use re '/aa';

use Crypt::AuthEnc::GCM  ();
use Crypt::KeyDerivation ();
use Crypt::Misc          ();
use Crypt::PRNG          ();
use Digest::SHA          ();
use File::Slurper        ();

use Trog::Auth;
use Trog::Log qw{WARN INFO};
use Trog::SQLite;

=head1 Trog::Vault

Things a user asked us to remember, kept where the database alone will not give
them up.

=head1 WHAT THIS IS FOR

Some of what tCMS does on a user's behalf needs a password that is not tCMS's:
the KeePass passphrase every provisioning recipe's secret: values are behind,
for one.  Asking for it every time works, and is what reprovisioning used to do,
but it means the person has to be holding it -- so it gets written down, and the
thing that was too dangerous to keep in a config file ends up in a text file
instead.

So we keep it, and ask for a TOTP code instead of the password when it is time
to use it.

=head1 WHAT A TOTP CODE IS AND IS NOT

It is not a key.  Six digits is twenty bits, it changes every thirty seconds,
and we have to know the secret to check it, so nothing can be encrypted with it
and stay encrypted.  What it is, is evidence that the person is at the keyboard
right now, which is exactly what you want to demand before handing a stored
password to a process.  See Trog::Auth::spend_totp: a code is worth one thing
rather than everything you can do inside its window.

The key is elsewhere.

=head1 WHERE THE KEY IS

An installation has one master key, and it is not in the database, so the
database on its own is ciphertext.  It is looked for in this order:

    TPSGI_VAULT_KEY             base64, in the environment
    $CREDENTIALS_DIRECTORY/tpsgi-vault
    config/secrets.key          base64, in a file

The first is how a real deployment does it, and the reason it is first is the
chroot: tPSGI runs the workers chrooted into the installation, and systemd's
credential store is a ramdisk at /run/credentials which is outside it.  So the
unit takes the credential, service/tpsgi.sh reads it before the chroot happens
and puts it in the environment, and the key never touches a disk anywhere.

It is named for tPSGI rather than for tCMS because tPSGI is what owns the unit
and runs whatever is in the directory, and tCMS is only one of the things that
can be.  One service, one key.

It is taken out of the environment at load, so nothing we fork afterwards
inherits it -- which matters, because one of the things we fork is a provisioner
that we are handing a decrypted password to on its stdin.  Read once, in the
parent, before there are any workers; the workers inherit the key as a variable
and an environment without it.

The second is for a service that is not chrooted.  The third is for a machine
that is not running systemd at all, and it is the weakest of the three: a file
next to the database it protects is a file that goes into the same backup.

No key means no vault.  Nothing is stored and nothing is offered, and the parts
of tCMS which would have used one ask for the password directly, as they did
before.  That is a feature being off, not a failure.

=head1 WHAT IS ACTUALLY DONE TO A SECRET

AES-256-GCM, under a key derived for that one row:

    salt        32 random bytes, fresh for every write
    key, iv     HKDF-SHA256(master, salt) -- 44 bytes, split 32 and 12
    aad         the username and the secret's name

The salt being fresh per write is what makes the derived key and iv fresh per
write, which is the thing GCM cares about.  The username and name go in as
associated data rather than being merely stored alongside, so a row cannot be
lifted into another user's account or renamed into being the answer to a
different question -- the tag stops checking out.

key_id is a fingerprint of the master key.  It is not needed to decrypt
anything; it is there so that a row written under a key you no longer have says
so, rather than presenting as corruption.

=head1 FUNCTIONS

=cut

# 32 raw bytes.  Read at load: see WHERE THE KEY IS -- this is the moment the
# environment is scrubbed, and it has to be before anything forks.
our $key_file       = 'config/secrets.key';
our $credential     = 'tpsgi-vault';
our $key_bytes      = 32;
our $master         = _from_env();
our $looked_further = 0;

sub _from_env {
    my $raw = delete $ENV{TPSGI_VAULT_KEY};
    return undef unless defined $raw && length($raw);
    return _decode( $raw, 'TPSGI_VAULT_KEY' );
}

sub _decode ( $raw, $whence ) {
    $raw =~ s/\s+//g;
    my $key = eval { Crypt::Misc::decode_b64($raw) };
    if ( !defined $key || length($key) != $key_bytes ) {
        WARN("The vault key in $whence is not $key_bytes base64 encoded bytes; ignoring it");
        return undef;
    }
    return $key;
}

# The two places worth looking that are not the environment.  Deferred rather
# than done at load, since both are files and this module is loaded by things
# which have no interest in a vault.
sub _look_further {
    $looked_further = 1;

    my $dir = $ENV{CREDENTIALS_DIRECTORY};
    if ($dir) {
        my $path = "$dir/$credential";
        my $raw  = eval { File::Slurper::read_binary($path) };
        return _decode( $raw, $path ) if defined $raw;
    }

    my $raw = eval { File::Slurper::read_binary($key_file) };
    return undef unless defined $raw;

    # A key file the group or the world can read is a key file that has already
    # been read.  Said rather than refused: the alternative is a site that
    # silently stops being able to open its own secrets.
    my @stat = stat($key_file);
    WARN("$key_file is readable by more than its owner; chmod 600 it") if @stat && ( $stat[2] & oct('077') );

    return _decode( $raw, $key_file );
}

=head2 key() = STRING or undef

The master key, or undef when this installation has none.

=head2 has_key() = BOOL

Whether there is a vault at all.  Ask this before offering a user anywhere to
put a secret, so that a site with no key says so rather than accepting one and
losing it.

=cut

sub key {
    $master //= _look_further() unless $looked_further;
    return $master;
}

sub has_key { return key() ? 1 : 0 }

=head2 key_id() = STRING

A fingerprint of the master key, stored on each row so that a row written under
a key which is no longer here can say which.

=cut

sub key_id {
    my $key = key() or return '';
    return substr( Digest::SHA::sha256_hex($key), 0, 16 );
}

# Bound into the ciphertext, so that moving a row between users or renaming it
# breaks the tag rather than working.
sub _aad ( $user, $name ) { return join( "\0", $user, $name ) }

sub _derive ($salt) {
    my $material = Crypt::KeyDerivation::hkdf( key(), $salt, 'SHA256', 44, 'tcms/user-secret' );
    return ( substr( $material, 0, 32 ), substr( $material, 32, 12 ) );
}

=head2 set($user, $name, $secret) = ($ok, $message)

Remember one thing for one user, replacing whatever was there under that name.

=cut

sub set ( $user, $name, $secret ) {
    return ( 0, 'this installation has no vault key, so there is nowhere to keep it' ) unless has_key();
    return ( 0, 'a secret needs a name' )                                              unless _safe_name($name);
    return ( 0, 'nothing to store' )                                                   unless defined $secret && length($secret);

    my $salt = Crypt::PRNG::random_bytes(32);
    my ( $key, $iv ) = _derive($salt);

    my $gcm = Crypt::AuthEnc::GCM->new( 'AES', $key, $iv );
    $gcm->adata_add( _aad( $user, $name ) );
    my $ciphertext = $gcm->encrypt_add($secret);
    my $tag        = $gcm->encrypt_done();

    my $dbh = _dbh();
    $dbh->do(
        "INSERT OR REPLACE INTO user_secret (username, name, key_id, salt, ciphertext, tag, created) VALUES (?,?,?,?,?,?,?)",
        undef, $user, $name, key_id(), $salt, $ciphertext, $tag, time()
    ) or return ( 0, 'could not store it' );

    Trog::Auth::log_event( 'secret_write', $user );
    return ( 1, "'$name' stored" );
}

=head2 get($user, $name) = STRING or undef

What was stored, or undef if there is nothing under that name, no key to open it
with, or a key which is not the one it was sealed under.

Every call is an audit_log row.  Reading a stored password is the interesting
event here, not writing one.

=cut

sub get ( $user, $name ) {
    my $secret = _stored( $user, $name );
    return undef unless defined $secret;

    my $dbh = _dbh();
    $dbh->do( "UPDATE user_secret SET last_used=? WHERE username=? AND name=?", undef, time(), $user, $name );
    Trog::Auth::log_event( 'secret_read', $user );
    return $secret;
}

# What is in one row, or nothing.
#
# Every question anybody asks about a stored secret comes through here, get()
# and has() alike, and they all get the same answer -- which is the point.  A
# page that says a secret is there and a request that finds it will not open are
# a way to send somebody round a loop typing codes at a row that was never going
# to work.  Opening it is the only way to know, and it is microseconds.
#
# What get() adds is that reading a secret is an event: it moves last_used and
# writes to the audit log.  Asking whether one is usable is not an event, and
# does not.
sub _stored ( $user, $name ) {
    return undef unless has_key();

    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref(
        "SELECT key_id, salt, ciphertext, tag FROM user_secret WHERE username=? AND name=?",
        { Slice => {} }, $user, $name
    );
    return undef unless ref $rows eq 'ARRAY' && @$rows;

    return _open( $rows->[0], $user, $name );
}

# The plaintext, or undef with a reason in the log.  Never dies: a row that will
# not open is a thing to report to somebody who can store it again, not an
# exception halfway through drawing a page.
sub _open ( $row, $user, $name ) {
    if ( $row->{key_id} ne key_id() ) {
        WARN( "'$name' for $user was sealed under vault key $row->{key_id}, and this installation has " . key_id() );
        return undef;
    }

    my ( $key, $iv ) = _derive( $row->{salt} );
    my $gcm = Crypt::AuthEnc::GCM->new( 'AES', $key, $iv );
    $gcm->adata_add( _aad( $user, $name ) );
    my $secret = $gcm->decrypt_add( $row->{ciphertext} );

    # The tag is the whole point: it says this ciphertext, under this key, for
    # this user and this name, is the one that was written.
    if ( !$gcm->decrypt_done( $row->{tag} ) ) {
        WARN("'$name' for $user did not survive its own tag check; it has been tampered with or the database is damaged");
        return undef;
    }

    return $secret;
}

=head2 list($user) = ARRAYREF

What this user has stored, as names and dates.  Never values -- there is no
route, page or log line anywhere that shows one back to them, because a secret
you can read off a screen is one you did not need us to keep.

=cut

sub list ($user) {
    my $dbh  = _dbh();
    my $rows = $dbh->selectall_arrayref(
        "SELECT name, created, last_used, key_id, salt, ciphertext, tag FROM user_secret WHERE username=? ORDER BY name",
        { Slice => {} }, $user
    );
    return [] unless ref $rows eq 'ARRAY';

    # Opened rather than guessed at from the key fingerprint, so that a row this
    # page calls readable is one that will actually open when something asks for
    # it.  This is the page somebody comes to when a secret has stopped working,
    # and it is no use to them if it agrees that everything looks fine.
    foreach my $row (@$rows) {
        $row->{readable} = ( has_key() && defined _open( $row, $user, $row->{name} ) ) ? 1 : 0;
        delete $row->{$_} foreach qw{salt ciphertext tag};
    }
    return $rows;
}

=head2 has($user, $name) = BOOL

Whether there is something stored under that name that this installation can
actually open.

Not "is there a row": a row sealed under a key that is gone is a row that will
never open again, and answering yes to this would have somebody typing codes at
it.  The question this is really being asked is whether to draw a passphrase box
or a code box, and the honest answer to that is the one where the code works.

Separate from get() because reading a secret is an event and asking about one is
not.  This moves nothing and writes nothing to the audit log.

=cut

sub has ( $user, $name ) { return defined _stored( $user, $name ) ? 1 : 0 }

=head2 forget($user, $name) = BOOL

=cut

sub forget ( $user, $name ) {
    my $dbh = _dbh();
    my $res = $dbh->do( "DELETE FROM user_secret WHERE username=? AND name=?", undef, $user, $name );
    Trog::Auth::log_event( 'secret_delete', $user ) if $res && $res != 0;
    return $res && $res != 0 ? 1 : 0;
}

# A name is a label in a form and a key in a table, and it is half of what binds
# a row to its owner, so it is a short plain thing or it is nothing.
sub _safe_name ($name) {
    return 0 unless defined $name && length($name) && length($name) <= 64;
    return $name =~ m/^[A-Za-z0-9][A-Za-z0-9._-]*$/ ? 1 : 0;
}

# The same database the users are in, since a secret belongs to one.
sub _dbh { return Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' ) }

1;
