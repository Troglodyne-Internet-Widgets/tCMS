use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal qw{exception};
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurper qw{read_text};
use DBI;

# Stub modules with heavy native or optional deps before loading any SUT.

BEGIN {
    package Trog::TOTP;
    sub new                  { bless {}, $_[0] }
    sub _valid_secret        { }
    sub secret               { 'FAKESECRET' }
    sub generate_otp         { 'otpauth://totp/fake' }
    sub expected_totp_code   { '123456' }
    sub validate_otp         { 1 }
    $INC{'Trog/TOTP.pm'} = 1;
}

BEGIN {
    package Imager::QRCode;
    sub new  { bless {}, $_[0] }
    sub plot { bless {}, 'FakeImage' }
    $INC{'Imager/QRCode.pm'} = 1;
}

BEGIN {
    package Imager::Color;
    sub new { bless {}, $_[0] }
    $INC{'Imager/Color.pm'} = 1;
}

BEGIN {
    package FakeImage;
    sub write { 1 }
    sub errstr { '' }
}

BEGIN {
    package HTTP::Tiny::UNIX;
    $INC{'HTTP/Tiny/UNIX.pm'} = 1;
}

BEGIN {
    package Plack::MIME;
    sub mime_type { undef }
    $INC{'Plack/MIME.pm'} = 1;
}

BEGIN {
    package Mojo::File;
    sub new { bless { path => $_[1] }, $_[0] }
    sub extname {
        my $self = shift;
        $self->{path} =~ /\.([^.\/]+)$/ ? $1 : '';
    }
    $INC{'Mojo/File.pm'} = 1;
}

BEGIN {
    package File::LibMagic;
    sub new                { bless {}, $_[0] }
    sub info_from_filename { {} }
    $INC{'File/LibMagic.pm'} = 1;
}

BEGIN {
    package Ref::Util;
    use Exporter 'import';
    our @EXPORT_OK = qw{is_hashref is_arrayref};
    sub is_hashref  { ref $_[0] eq 'HASH' }
    sub is_arrayref { ref $_[0] eq 'ARRAY' }
    $INC{'Ref/Util.pm'} = 1;
}

BEGIN {
    package Log::Dispatch;
    sub new     { bless {}, $_[0] }
    sub add     { }
    sub debug   { }
    sub info    { }
    sub warning { }
    sub log_and_die { die $_[2] }
    $INC{'Log/Dispatch.pm'} = 1;

    package Log::Dispatch::FileRotate;
    sub new { bless {}, $_[0] }
    $INC{'Log/Dispatch/FileRotate.pm'} = 1;

    package Log::Dispatch::Screen;
    sub new { bless {}, $_[0] }
    $INC{'Log/Dispatch/Screen.pm'} = 1;

    package Log::Dispatch::DBI;
    sub new { bless {}, $_[0] }
    $INC{'Log/Dispatch/DBI.pm'} = 1;
}

BEGIN {
    package Trog::Log::DBI;
    sub new { bless {}, $_[0] }
    $INC{'Trog/Log/DBI.pm'} = 1;
}

BEGIN {
    package Trog::Log;
    use Exporter 'import';
    our @EXPORT_OK   = qw{log_init is_debug INFO DEBUG WARN FATAL};
    our %EXPORT_TAGS = ( 'all' => \@EXPORT_OK );
    sub log_init { }
    sub is_debug { 0 }
    sub INFO  { }
    sub DEBUG { }
    sub WARN  { }
    sub FATAL { }
    $INC{'Trog/Log.pm'} = 1;
}

BEGIN {
    package FindBin::libs;
    sub import { }
    $INC{'FindBin/libs.pm'} = 1;
}

require_ok('Trog::SQLite') or BAIL_OUT("Can't load Trog::SQLite");
require_ok('Trog::Auth')   or BAIL_OUT("Can't load Trog::Auth");

# Build an in-memory SQLite auth database using the real schema.
sub _make_auth_dbh {
    my $schema = read_text("$FindBin::Bin/../schema/auth.schema");
    my $dbh    = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '' );
    $dbh->{sqlite_allow_multiple_statements} = 1;
    $dbh->do($schema) or die "Could not apply auth schema: " . $dbh->errstr;
    $dbh->{sqlite_allow_multiple_statements} = 0;
    $dbh->do("PRAGMA foreign_keys = ON");
    return $dbh;
}

# Helper: insert a user directly into the auth DB.
sub _add_user {
    my ( $dbh, $user, $display, $pass, $acl, $email ) = @_;
    use Digest::SHA 'sha256';
    my $salt = 'testsalt';
    my $hash = sha256( $pass . $salt );
    $dbh->do( "INSERT INTO user (name,display_name,salt,hash,contact_email) VALUES (?,?,?,?,?)",
        undef, $user, $display, $salt, $hash, $email );
    $dbh->do( "INSERT INTO user_acl (username,acl) VALUES (?,?)", undef, $user, $acl );
    return 1;
}

my $auth_dbh;
my $sqlite_mock;

sub setup {
    $auth_dbh    = _make_auth_dbh();
    $sqlite_mock = Test::MockModule->new('Trog::SQLite');
    $sqlite_mock->redefine( 'dbh', sub { $auth_dbh } );
}

setup();

subtest user_exists => sub {
    _add_user( $auth_dbh, 'alice', 'Alice A', 'secret', 'admin', 'alice@example.com' );
    ok( Trog::Auth::user_exists('alice'), 'existing user found' );
    ok( !Trog::Auth::user_exists('nobody'), 'absent user not found' );
};

subtest user_has_session => sub {
    ok( !Trog::Auth::user_has_session('alice'), 'no session initially' );
    $auth_dbh->do( "INSERT INTO session (id,username) VALUES ('sess-alice','alice')" );
    ok( Trog::Auth::user_has_session('alice'), 'session detected after insert' );
    $auth_dbh->do("DELETE FROM session WHERE username='alice'");
};

subtest session2user => sub {
    $auth_dbh->do( "INSERT INTO session (id,username) VALUES ('sess-abc','alice')" );
    is( Trog::Auth::session2user('sess-abc'), 'alice', 'session resolves to username' );
    is( Trog::Auth::session2user('bogus-id'), '',      'unknown session returns empty string' );
    $auth_dbh->do("DELETE FROM session WHERE id='sess-abc'");
};

subtest primary_user => sub {
    is( Trog::Auth::primary_user(), 'alice', 'primary_user returns admin ACL user' );
};

subtest acls4user => sub {
    my $acls = Trog::Auth::acls4user('alice');
    is_deeply( $acls, ['admin'], 'acls4user returns correct ACL list' );
    my $empty = Trog::Auth::acls4user('nobody');
    is( $empty, undef, 'acls4user returns undef for unknown user' );
};

subtest killsession => sub {
    $auth_dbh->do( "INSERT INTO session (id,username) VALUES ('sess-kill','alice')" );
    ok( Trog::Auth::killsession('alice'), 'killsession returns true' );
    my $rows = $auth_dbh->selectall_arrayref("SELECT id FROM session WHERE username='alice'");
    is( scalar @$rows, 0, 'session deleted from database' );
};

subtest useradd => sub {
    my $result = Trog::Auth::useradd( 'bob', 'Bob B', 'password123', ['admin'], 'bob@example.com' );
    ok( $result, 'useradd returns true for new user' );
    ok( Trog::Auth::user_exists('bob'), 'new user exists after useradd' );

    like( exception { Trog::Auth::useradd( undef, 'No Name', 'pw', [], 'x@y.com' ) },
        qr/username/i, 'useradd dies without username' );
    like( exception { Trog::Auth::useradd( 'newuser_nd', undef, 'pw', [], 'x@y.com' ) },
        qr/display name/i, 'useradd dies without display name for new user' );
    like( exception { Trog::Auth::useradd( 'bob', 'bob', 'pw', [], 'x@y.com' ) },
        qr/same/i, 'useradd dies when username equals display name' );
    like( exception { Trog::Auth::useradd( 'newuser', 'New User', undef, [], 'x@y.com' ) },
        qr/password/i, 'useradd dies without password for new user' );
    like( exception { Trog::Auth::useradd( 'bob', 'Bob B', 'pw', 'notarray', 'x@y.com' ) },
        qr/array/i, 'useradd dies when ACLs not an arrayref' );
    like( exception { Trog::Auth::useradd( 'newuser2', 'New User 2', 'pw', [], undef ) },
        qr/contact email/i, 'useradd dies without contact email' );
};

subtest mksession => sub {
    my $sess = Trog::Auth::mksession( 'bob', 'password123', undef );
    ok( $sess, 'mksession returns session ID for valid credentials' );
    is( Trog::Auth::session2user($sess), 'bob', 'session maps back to correct user' );

    my $bad = Trog::Auth::mksession( 'bob', 'wrongpassword', undef );
    is( $bad, '', 'mksession returns empty string for wrong password' );

    my $nouser = Trog::Auth::mksession( 'phantom', 'pw', undef );
    is( $nouser, '', 'mksession returns empty string for nonexistent user' );
};

done_testing;
