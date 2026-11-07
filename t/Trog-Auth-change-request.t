#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;

use Test::More;
use Cwd();
use File::Copy();
use File::Path();
use File::Temp();

# Auth keeps its database at config/auth.db under the cwd, so it gets a sandbox.
my $repo = Cwd::getcwd();
my $root = File::Temp::tempdir( CLEANUP => 1 );
File::Path::make_path( "$root/config", "$root/schema" );
File::Copy::copy( "$repo/schema/auth.schema", "$root/schema/auth.schema" ) or die $!;
chdir($root)                                                               or die "chdir $root: $!";
END { chdir($repo) if $repo }

require_ok('Trog::Auth') or BAIL_OUT("Can't find SUT");

my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );
sub contact_of ($user) { return $dbh->selectrow_hashref( 'SELECT display_name, contact_email FROM user WHERE name = ?', undef, $user ) }

subtest 'process_change_request: each reset keeps its own user' => sub {
    Trog::Auth::useradd( qw{alice Alice old}, [], 'alice@test.test' );
    Trog::Auth::useradd( qw{bob Bob old},     [], 'bob@test.test' );
    for my $user (qw{alice bob}) { Trog::Auth::add_change_request( user => $user, token => "t-$user", type => 'reset_pass' ) }

    like( Trog::Auth::process_change_request( 't-alice', 'new' ), qr/for[ ]alice/, 'the first reset is done' );
    like( Trog::Auth::process_change_request( 't-bob',   'new' ), qr/for[ ]bob/,   'and the second' );

    is_deeply( contact_of('alice'), { display_name => 'Alice', contact_email => 'alice@test.test' }, 'the first user is as they were' );
    is_deeply( contact_of('bob'),   { display_name => 'Bob',   contact_email => 'bob@test.test' },   'and the second keeps their own name and address, not the first one\'s' );
};

subtest 'process_change_request: the password comes from the caller, and is not repeated' => sub {
    Trog::Auth::add_change_request( user => 'alice', token => 't-secret', type => 'reset_pass' );
    is( $dbh->selectrow_array( 'SELECT secret FROM change_request WHERE token = ?', undef, 't-secret' ), undef, 'the request stores no password' );

    ok( !Trog::Auth::process_change_request( 't-secret', q{} ), 'an empty password is refused' );
    is( $dbh->selectrow_array( 'SELECT processed FROM change_request WHERE token = ?', undef, 't-secret' ), 0, 'and leaves the token unspent' );

    my $msg = Trog::Auth::process_change_request( 't-secret', 'hunter2-alice' );
    ok( $msg, 'a password is set' );
    unlike( $msg, qr/hunter2/, 'and the message does not repeat it' );
    ok( Trog::Auth::check_password( 'alice', 'hunter2-alice' ),     'and alice can log in with it' );
    ok( !Trog::Auth::process_change_request( 't-secret', 'again' ), 'the token cannot be used twice' );
};

subtest 'reset_password: only the password changes' => sub {
    Trog::Auth::useradd( qw{carol Carol old}, [qw{admin}], 'carol@test.test' );
    $dbh->do( 'UPDATE user SET totp_secret = ? WHERE name = ?',              undef, 'JBSWY3DPEHPK3PXP', 'carol' );
    $dbh->do( 'INSERT OR REPLACE INTO session (id, username) VALUES (?, ?)', undef, 'carol-session',    'carol' );

    ok( !Trog::Auth::reset_password( 'carol',  q{} ),   'an empty password is refused' );
    ok( !Trog::Auth::reset_password( 'nobody', 'new' ), 'and so is a user who does not exist' );
    is( Trog::Auth::session2user('carol-session'), 'carol', 'neither one ends her session' );

    ok( Trog::Auth::reset_password( 'carol', 'carol-new' ), 'a password is set' );
    ok( Trog::Auth::check_password( 'carol', 'carol-new' ), 'and works' );
    is_deeply( Trog::Auth::acls4user('carol'), ['admin'], 'carol keeps her ACLs' );
    ok( Trog::Auth::has_totp('carol'), 'and her TOTP enrollment' );
    is_deeply( contact_of('carol'), { display_name => 'Carol', contact_email => 'carol@test.test' }, 'and her name and address' );
    is( Trog::Auth::session2user('carol-session'), q{}, 'but her session ends' );
};

subtest 'schema update 1 clears the passwords that resets stored' => sub {
    my $dir = "$root/update";
    File::Path::make_path($dir);
    File::Copy::copy( "$repo/schema/auth.schema", "$dir/auth.schema" ) or die $!;

    my $old = Trog::SQLite::dbh( "$dir/auth.schema", "$dir/old.db" );
    $old->do( 'INSERT INTO user (name, display_name, contact_email, salt, hash) VALUES (?,?,?,?,?)', undef, qw{dave Dave dave@test.test salt hash} );
    $old->do( 'INSERT INTO change_request (username, type, token, secret) VALUES (?,?,?,?)',         undef, qw{dave reset_pass t-dave plain-text} );
    Trog::SQLite::forget();

    File::Copy::copy( "$repo/schema/auth.schema.v1.update.sql", "$dir/auth.schema.v1.update.sql" ) or die $!;
    my $new = Trog::SQLite::dbh( "$dir/auth.schema", "$dir/old.db" );
    is( Trog::SQLite::schema_version($new), 1, 'the update runs' );
    is_deeply( $new->selectrow_arrayref('SELECT token, secret FROM change_request'), [ 't-dave', undef ], 'and keeps the request without its password' );
    Trog::SQLite::forget();
    $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );
};

done_testing();
