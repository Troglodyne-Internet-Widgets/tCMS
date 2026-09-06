#!/usr/bin/env perl

# The vault, the code that authorizes opening it, and the hashing underneath
# both.  Nothing here needs a webserver: what is being tested is that a database
# on its own is not enough, and that a code is worth one thing.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::MockModule qw{strict};

our ( $REPO, $ROOT, $OLDCWD );

BEGIN {
    require Cwd;
    require File::Copy;
    require File::Path;
    require File::Temp;

    $REPO   = Cwd::abs_path("$FindBin::Bin/..");
    $OLDCWD = Cwd::getcwd();
    $ROOT   = File::Temp::tempdir( 'tcms-vault-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

    $ENV{HOME} = $ROOT;
    File::Path::make_path( map { "$ROOT/$_" } qw{config schema logs totp} );
    File::Copy::copy( "$REPO/schema/auth.schema", "$ROOT/schema/auth.schema" ) or die $!;

    open( my $fh, '>', "$ROOT/config/default.cfg" ) or die $!;
    print {$fh} "[general]\n    data_model=FlatFile\n    hostname=vault.example.com\n";
    close $fh;

    # The key the way a deployment hands one over: base64, in the environment,
    # put there by tpsgi.sh out of a systemd credential.  Trog::Vault takes it
    # out of %ENV as it loads, which is the behaviour tested below.
    require Crypt::PRNG;
    require Crypt::Misc;
    $ENV{TPSGI_VAULT_KEY} = Crypt::Misc::encode_b64( Crypt::PRNG::random_bytes(32) );

    chdir($ROOT) or die "could not chdir to the sandbox: $!";
}

END {
    chdir($OLDCWD) if $OLDCWD;
}

require_ok('Trog::Auth')  or BAIL_OUT("Can't find Trog::Auth");
require_ok('Trog::Vault') or BAIL_OUT("Can't find SUT");

Trog::Auth::useradd( 'bob', 'Bob Bobson', 'hunter2', ['admin'], 'bob@example.com' )
  or BAIL_OUT('could not make a user to test with');
Trog::Auth::useradd( 'eve', 'Eve Evilson', 'letmein', ['public'], 'eve@example.com' )
  or BAIL_OUT('could not make a second user');

subtest 'the key is taken out of the environment' => sub {
    ok( Trog::Vault::has_key(),        'the key was read' );
    ok( !exists $ENV{TPSGI_VAULT_KEY}, 'and is gone from the environment, so nothing we fork inherits it' );
    like( Trog::Vault::key_id(), qr/^[0-9a-f]{16}$/, 'and fingerprints to something a row can name' );
};

subtest 'what a secret looks like on disk' => sub {
    my ( $ok, $why ) = Trog::Vault::set( 'bob', 'keepass', 'correct horse battery staple' );
    is( $ok, 1, 'a secret can be stored' ) or diag($why);

    my $dbh  = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );
    my $rows = $dbh->selectall_arrayref( "SELECT * FROM user_secret WHERE username='bob'", { Slice => {} } );
    is( scalar(@$rows), 1, 'and lands in one row' );

    my $row = $rows->[0];
    unlike( $row->{ciphertext}, qr/correct horse/, 'which does not contain the secret' );
    is( length( $row->{salt} ), 32,                    'carries a fresh 32 byte salt' );
    is( length( $row->{tag} ),  16,                    'and a GCM tag' );
    is( $row->{key_id},         Trog::Vault::key_id(), 'naming the key it was sealed under' );

    is( Trog::Vault::get( 'bob', 'keepass' ), 'correct horse battery staple', 'and it comes back out' );
};

subtest 'a fresh salt every write' => sub {
    my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );

    Trog::Vault::set( 'bob', 'same', 'the very same secret' );
    my ($first) = $dbh->selectrow_array("SELECT hex(ciphertext) FROM user_secret WHERE username='bob' AND name='same'");
    Trog::Vault::set( 'bob', 'same', 'the very same secret' );
    my ($second) = $dbh->selectrow_array("SELECT hex(ciphertext) FROM user_secret WHERE username='bob' AND name='same'");

    # Same plaintext, same key, different ciphertext -- which is what a random
    # salt per write buys, and what GCM needs to stay safe.
    isnt( $first, $second, 'the same secret stored twice does not look the same twice' );
    is( Trog::Vault::get( 'bob', 'same' ), 'the very same secret', 'and still reads back' );
};

subtest 'a row cannot be moved or renamed' => sub {
    my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );

    # Exactly what somebody with write access to the database would try: take
    # the admin's sealed passphrase and make it their own.
    $dbh->do("INSERT OR REPLACE INTO user_secret (username, name, key_id, salt, ciphertext, tag, created) SELECT 'eve', name, key_id, salt, ciphertext, tag, created FROM user_secret WHERE username='bob' AND name='keepass'");
    is( Trog::Vault::get( 'eve', 'keepass' ), undef, 'a row lifted into another account does not open' );

    $dbh->do("INSERT OR REPLACE INTO user_secret (username, name, key_id, salt, ciphertext, tag, created) SELECT 'bob', 'renamed', key_id, salt, ciphertext, tag, created FROM user_secret WHERE username='bob' AND name='keepass'");
    is( Trog::Vault::get( 'bob', 'renamed' ), undef, 'nor does one renamed into being the answer to a different question' );

    is( Trog::Vault::get( 'bob', 'keepass' ), 'correct horse battery staple', 'while the row it was copied from is untouched' );
    $dbh->do("DELETE FROM user_secret WHERE name IN ('renamed') OR username='eve'");
};

subtest 'and not without the key it was sealed under' => sub {
    my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );

    # A different installation's key, which is what a stolen database meets.
    my $theirs = Trog::Vault::key();
    {
        no warnings qw{once};
        local $Trog::Vault::master = Crypt::PRNG::random_bytes(32);
        is( Trog::Vault::get( 'bob', 'keepass' ), undef, 'the wrong key opens nothing' );

        my $listed = Trog::Vault::list('bob');
        my ($keepass) = grep { $_->{name} eq 'keepass' } @$listed;
        is( $keepass->{readable}, 0, 'and the listing says so rather than pretending' );
    }
    is( Trog::Vault::get( 'bob', 'keepass' ), 'correct horse battery staple', 'the right one still does' );

    # Tampering, as opposed to the wrong key: the tag is what notices.
    $dbh->do("UPDATE user_secret SET ciphertext = ciphertext || X'00' WHERE username='bob' AND name='keepass'");
    is( Trog::Vault::get( 'bob', 'keepass' ), undef, 'a row somebody edited does not open either' );
    Trog::Vault::set( 'bob', 'keepass', 'correct horse battery staple' );
};

subtest 'the listing never shows a value' => sub {
    my $listed = Trog::Vault::list('bob');
    ok( scalar(@$listed) >= 2, 'lists what bob has' );
    foreach my $secret (@$listed) {
        ok( !exists $secret->{ciphertext}, "$secret->{name} is listed without its ciphertext" );
        ok( exists $secret->{created},     "$secret->{name} says when it was stored" );
    }
    is_deeply( Trog::Vault::list('eve'), [], 'and one user cannot see another\'s' );

    ok( Trog::Vault::forget( 'bob', 'same' ), 'a secret can be forgotten' );
    is( Trog::Vault::get( 'bob', 'same' ),    undef, 'after which it is gone' );
    is( Trog::Vault::forget( 'bob', 'same' ), 0,     'and forgetting it twice is not a thing that happened' );
};

subtest 'a name is a name' => sub {
    foreach my $bad ( '../../etc/passwd', 'has spaces', '', 'a' x 100, '.hidden' ) {
        my ( $ok, $why ) = Trog::Vault::set( 'bob', $bad, 'nope' );
        is( $ok, 0, "'$bad' is refused as a name" );
    }
    my ( $ok, $why ) = Trog::Vault::set( 'bob', 'fine', '' );
    is( $ok, 0, 'and an empty secret is not a secret' );
};

subtest 'no key, no vault' => sub {
    no warnings qw{once};
    local $Trog::Vault::master         = undef;
    local $Trog::Vault::looked_further = 1;

    ok( !Trog::Vault::has_key(), 'an installation with no key has no vault' );
    my ( $ok, $why ) = Trog::Vault::set( 'bob', 'nowhere', 'to put it' );
    is( $ok, 0, 'storing is refused' );
    like( $why, qr/no vault key/, 'saying why, since this is a thing to go and configure' );
    is( Trog::Vault::get( 'bob', 'keepass' ), undef, 'and nothing already stored is offered' );
};

subtest 'the other two places a key can be' => sub {
    no warnings qw{once};
    require Crypt::Misc;

    # A key file, for a machine not running systemd.  bin/tcms-vault-key --file
    # writes exactly this: base64 and a newline.
    my $on_disk = Crypt::Misc::encode_b64( Crypt::PRNG::random_bytes(32) );
    open( my $fh, '>', 'config/secrets.key' ) or die $!;
    print {$fh} "$on_disk\n";
    close $fh;
    chmod( oct('600'), 'config/secrets.key' );

    {
        local $Trog::Vault::master         = undef;
        local $Trog::Vault::looked_further = 0;
        is( Crypt::Misc::encode_b64( Trog::Vault::key() ), $on_disk, 'a key file is found, newline and all' );
    }

    # And systemd's credential store, which is where it should be: the directory
    # systemd hands over, for a service that is not chrooted away from it.
    my $in_store = Crypt::Misc::encode_b64( Crypt::PRNG::random_bytes(32) );
    File::Path::make_path('creds');
    open( $fh, '>', 'creds/tpsgi-vault' ) or die $!;
    print {$fh} $in_store;
    close $fh;

    {
        local $ENV{CREDENTIALS_DIRECTORY}  = 'creds';
        local $Trog::Vault::master         = undef;
        local $Trog::Vault::looked_further = 0;
        is( Crypt::Misc::encode_b64( Trog::Vault::key() ), $in_store, 'the credential store wins over the file beside the database' );
    }

    # Something that is not a key is not quietly used as one.
    open( $fh, '>', 'config/secrets.key' ) or die $!;
    print {$fh} "hunter2\n";
    close $fh;
    {
        local $Trog::Vault::master         = undef;
        local $Trog::Vault::looked_further = 0;
        is( Trog::Vault::key(), undef, 'a key that is not 32 bytes of base64 is refused' );
    }
    unlink('config/secrets.key');
};

subtest 'a code is worth one thing' => sub {
    my ( $uri, $qr, $failure, $message, $totp ) = Trog::Auth::totp( 'bob', 'vault.example.com' );
    ok( $uri, 'bob is enrolled' ) or diag($message);

    my $now  = time();
    my $code = $totp->expected_totp_code($now);

    my ( $ok, $why ) = Trog::Auth::spend_totp( 'bob', $code );
    is( $ok, 1, 'the code from their authenticator is accepted' ) or diag($why);

    ( $ok, $why ) = Trog::Auth::spend_totp( 'bob', $code );
    is( $ok, 0, 'and is not accepted a second time' );
    like( $why, qr/already been used/, 'saying so, since the answer is to wait thirty seconds' );

    # A code from before the one just spent is also spent, whatever the
    # arithmetic says: that is what walking the counter forward is for.
    my $previous = $totp->expected_totp_code( $now - 30 );
    ( $ok, $why ) = Trog::Auth::spend_totp( 'bob', $previous );
    is( $ok, 0, 'nor is an older code from inside the tolerance window' );

    ( $ok, $why ) = Trog::Auth::spend_totp( 'bob', '000000' );
    is( $ok, 0, 'a wrong code is refused' );
    ( $ok, $why ) = Trog::Auth::spend_totp( 'bob', 'notacode' );
    is( $ok, 0, 'and so is something that is not a code at all' );

    ( $ok, $why ) = Trog::Auth::spend_totp( 'eve', $totp->expected_totp_code( $now + 30 ) );
    is( $ok, 0, 'somebody who has not enrolled cannot spend anything' );
    like( $why, qr/no second factor/, 'and is told that rather than that their code was wrong' );

    # The next window is a new code and works, which is the whole cost of this.
    ( $ok, $why ) = Trog::Auth::spend_totp( 'bob', $totp->expected_totp_code( $now + 30 ) );
    is( $ok, 1, 'the next code works' ) or diag($why);
};

subtest 'passwords are argon2id, and become it' => sub {
    my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );

    my ($hash) = $dbh->selectrow_array("SELECT hash FROM user WHERE name='bob'");
    like( $hash, qr/^\$argon2id\$/, 'a user made today is stored as argon2id' );
    ok( Trog::Auth::check_password( 'bob',  'hunter2' ), 'and their password checks out' );
    ok( !Trog::Auth::check_password( 'bob', 'hunter3' ), 'while a wrong one does not' );
    ok( !Trog::Auth::check_password( 'bob', '' ),        'and neither does nothing at all' );

    # A row as it was before this change: one unstretched sha256 of the password
    # and the salt beside it.
    require Digest::SHA;
    $dbh->do( "UPDATE user SET hash=?, salt=? WHERE name=?", undef, Digest::SHA::sha256( 'letmein' . 'oldsalt' ), 'oldsalt', 'eve' );
    my ($legacy) = $dbh->selectrow_array("SELECT hash FROM user WHERE name='eve'");
    unlike( $legacy, qr/^\$argon2/, 'a row from before this reads as the old kind' );

    ok( !Trog::Auth::check_password( 'eve', 'wrong' ), 'which still refuses a wrong password' );
    ($legacy) = $dbh->selectrow_array("SELECT hash FROM user WHERE name='eve'");
    unlike( $legacy, qr/^\$argon2/, 'and is left alone when it does' );

    ok( Trog::Auth::check_password( 'eve', 'letmein' ), 'and accepts the right one' );
    my ($upgraded) = $dbh->selectrow_array("SELECT hash FROM user WHERE name='eve'");
    like( $upgraded, qr/^\$argon2id\$/, 'rewriting it as argon2id on the way past' );
    ok( Trog::Auth::check_password( 'eve', 'letmein' ), 'after which the same password still works' );

    # Raising the cost later is a one line change, not a migration, for the same
    # reason: the next correct password rewrites the row.
    {
        no warnings qw{once};
        local $Trog::Auth::argon2_time = $Trog::Auth::argon2_time + 1;
        ok( Trog::Auth::check_password( 'eve', 'letmein' ), 'a hash made under weaker parameters still verifies' );
        my ($rehashed) = $dbh->selectrow_array("SELECT hash FROM user WHERE name='eve'");
        isnt( $rehashed, $upgraded, 'and is rewritten under the stronger ones' );
    }
};

subtest 'logging in spends a code' => sub {
    my ( $uri, $qr, $failure, $message, $totp ) = Trog::Auth::totp( 'bob', 'vault.example.com' );

    # The subtest above spent the code for the window we are standing in, and
    # the counter only walks forwards.  Standing here for thirty seconds would
    # say the same thing and cost thirty seconds.
    my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );
    $dbh->do("DELETE FROM totp_spent WHERE username='bob'");

    my $now  = time();
    my $code = $totp->expected_totp_code($now);

    is( Trog::Auth::mksession( 'bob', 'hunter2', '' ),    '', 'an enrolled user cannot log in without a code' );
    is( Trog::Auth::mksession( 'bob', 'wrong',   $code ), '', 'nor with a wrong password' );

    # And a login that failed on the password did not spend the code on the way
    # past, or a wrong guess would cost the person their next thirty seconds.
    ok( Trog::Auth::mksession( 'bob', 'hunter2', $code ), 'the right password and a live code get a session' );
    is( Trog::Auth::mksession( 'bob', 'hunter2', $code ), '', 'and that code cannot be replayed into a second one' );
};

subtest 'when the key is gone' => sub {
    no warnings qw{once};
    require Trog::Routes::HTML;

    my $tpsgi = bless {}, 'FakeTPSGI2';
    {
        no warnings qw{once};
        *FakeTPSGI2::see_also = sub { return [ 303, [ Location => $_[1] ], [''] ] };
    }
    my $rendered;
    my $index = Test::MockModule->new('Trog::Routes::HTML');
    $index->redefine( index => sub { $rendered = $_[0]; return [ 200, [], [''] ] } );

    Trog::Vault::set( 'bob', 'keepass', 'correct horse battery staple' );

    # The machine was rebuilt and the credential went with it.  A key lives and
    # dies with its machine on purpose, so this is the ordinary case rather than
    # a disaster: everything sealed under the old one is gone, and the users
    # store theirs again.
    foreach my $gone (
        [ 'no key at all',   sub { $Trog::Vault::master = undef; $Trog::Vault::looked_further = 1 } ],
        [ 'a different key', sub { $Trog::Vault::master = Crypt::PRNG::random_bytes(32) } ],
    ) {
        my ( $what, $break ) = @$gone;
        local $Trog::Vault::master         = Trog::Vault::key();
        local $Trog::Vault::looked_further = 1;
        $break->();

        # Nothing explodes, and nothing claims a secret is usable.
        is( Trog::Vault::has( 'bob', 'keepass' ), 0,     "$what: nothing reads as usable" );
        is( Trog::Vault::get( 'bob', 'keepass' ), undef, "$what: and nothing opens" );

        Trog::Routes::HTML::secrets( { user => 'bob', user_acls => ['admin'], tpsgi => $tpsgi } );
        my ($listed) = grep { $_->{name} eq 'keepass' } @{ $rendered->{secrets} };
        ok( $listed, "$what: the row is still listed rather than vanishing" );
        is( $listed->{readable}, 0, "$what: marked as one that will not open" );

        # And a page which knows storing cannot work does not draw the form for
        # it -- has_vault is what the template hangs that on.
        is( $rendered->{has_vault}, ( $what eq 'no key at all' ? 0 : 1 ), "$what: the page knows whether there is a vault to store into" );

        my ( $stored, $why ) = Trog::Vault::set( 'bob', 'replacement', 'a new one' );
        if ( $what eq 'no key at all' ) {
            is( $stored, 0, "$what: storing is refused rather than silently lost" );
            like( $why, qr/no vault key/, "$what: saying why" );
        }
        else {
            is( $stored,                                  1,           "$what: a new key stores new secrets fine" );
            is( Trog::Vault::get( 'bob', 'replacement' ), 'a new one', "$what: and opens them" );
            Trog::Vault::forget( 'bob', 'replacement' );
        }
    }

    # The key came back: what was sealed under it was never damaged, only
    # unreadable while it was away.
    is( Trog::Vault::get( 'bob', 'keepass' ), 'correct horse battery staple', 'and the original key still opens the original row' );
};

subtest 'the page a user manages them from' => sub {
    require Trog::Routes::HTML;

    my $tpsgi = bless {}, 'FakeTPSGI';
    {
        no warnings qw{once};
        *FakeTPSGI::see_also  = sub { return [ 303, [ Location => $_[1] ], [''] ] };
        *FakeTPSGI::forbidden = sub { return [ 403, [], ['no'] ] };
    }

    my $route = $Trog::Routes::HTML::routes{'/secrets'};
    ok( $route,                 'the page is a route' );
    ok( $route->{auth},         'behind a login' );
    ok( $route->{nocache},      'and never cached, since it is about who is asking' );
    ok( !$route->{totp_exempt}, 'and not somewhere an unenrolled login can get to' );

    my $rendered;
    my $index = Test::MockModule->new('Trog::Routes::HTML');
    $index->redefine( index => sub { $rendered = $_[0]; return [ 200, [], [''] ] } );

    Trog::Routes::HTML::secrets( { user => 'bob', user_acls => ['admin'], tpsgi => $tpsgi } );
    ok( $rendered->{has_vault}, 'the page knows there is a vault' );
    my ($keepass) = grep { $_->{name} eq 'keepass' } @{ $rendered->{secrets} };
    ok( $keepass,                       "bob's own secret is listed" );
    ok( !exists $keepass->{ciphertext}, 'without its ciphertext' );
    ok( $keepass->{stored},             'with when it was stored' );

    # The username comes off the session, so there is no field to put somebody
    # else's in.
    Trog::Routes::HTML::secrets( { user => 'eve', user_acls => ['public'], tpsgi => $tpsgi } );
    is_deeply( $rendered->{secrets}, [], "and eve sees none of bob's" );

    # Storing, and the thing stored not surviving the request that stored it.
    my $query = { user => 'eve', tpsgi => $tpsgi, name => 'ssh', secret => 'a passphrase' };
    my $res   = Trog::Routes::HTML::secrets_save($query);
    is( $res->[0], 303, 'saving redirects back to the page' );
    ok( !exists $query->{secret}, 'and the secret is gone from the query afterwards' );
    is( Trog::Vault::get( 'eve', 'ssh' ), 'a passphrase', 'having been stored' );

    $res = Trog::Routes::HTML::secrets_forget( { user => 'eve', tpsgi => $tpsgi, name => 'ssh' } );
    is( $res->[0],                        303,   'forgetting redirects too' );
    is( Trog::Vault::get( 'eve', 'ssh' ), undef, 'and it is gone' );

    # One user cannot reach into another's, whatever they post.
    Trog::Routes::HTML::secrets_forget( { user => 'eve', tpsgi => $tpsgi, name => 'keepass' } );
    is( Trog::Vault::get( 'bob', 'keepass' ), 'correct horse battery staple', "bob's is untouched by eve asking to forget it" );
};

done_testing();
