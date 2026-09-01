use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use FindBin;

use lib "$FindBin::Bin/../lib";

# Stub modules absent from the test environment before loading Trog::Auth
BEGIN {
    # Logging stubs — Log::Dispatch family not installed in test env
    $INC{'Log/Dispatch.pm'}            = 1;
    $INC{'Log/Dispatch/DBI.pm'}        = 1;
    $INC{'Log/Dispatch/Screen.pm'}     = 1;
    $INC{'Log/Dispatch/FileRotate.pm'} = 1;
    $INC{'Trog/Log/DBI.pm'}            = 1;

    # Other missing optional deps
    $INC{'HTTP/Tiny/UNIX.pm'} = 1;
    $INC{'File/LibMagic.pm'}  = 1;
    $INC{'Imager/QRCode.pm'}  = 1;
    $INC{'Config/Simple.pm'}  = 1;

}

require_ok('Trog::Auth') or BAIL_OUT("Can't load Trog::Auth");

subtest 'users_with_emails — no rows returned' => sub {
    my $sqlite_mock = Test::MockModule->new('Trog::SQLite');
    $sqlite_mock->redefine(
        'dbh',
        sub {
            my $fake_dbh = bless {}, 'FakeDBH_NoRows';
            no warnings 'once';
            *FakeDBH_NoRows::selectall_arrayref = sub { undef };
            return $fake_dbh;
        }
    );
    my $result = Trog::Auth::users_with_emails();
    is( ref $result,     'ARRAY', 'returns arrayref even when DB returns undef' );
    is( scalar @$result, 0,       'empty arrayref when no rows' );
};

subtest 'users_with_emails — returns populated list' => sub {
    my $fake_rows = [
        { name => 'alice', contact_email => 'alice@example.com' },
        { name => 'bob',   contact_email => 'bob@example.com' },
    ];
    my $sqlite_mock = Test::MockModule->new('Trog::SQLite');
    $sqlite_mock->redefine(
        'dbh',
        sub {
            my $fake_dbh = bless {}, 'FakeDBH_WithRows';
            no warnings 'once';
            *FakeDBH_WithRows::selectall_arrayref = sub { $fake_rows };
            return $fake_dbh;
        }
    );
    my $result = Trog::Auth::users_with_emails();
    is( ref $result,                 'ARRAY',             'returns arrayref' );
    is( scalar @$result,             2,                   'correct number of users' );
    is( $result->[0]{name},          'alice',             'first user name' );
    is( $result->[0]{contact_email}, 'alice@example.com', 'first user email' );
    is( $result->[1]{name},          'bob',               'second user name' );
};

subtest 'libravatar hash matching logic' => sub {
    use Digest::MD5 qw{md5_hex};
    use Digest::SHA qw{sha256_hex};

    my $email  = 'Test@Example.COM';
    my $norm   = lc($email);
    my $sha256 = sha256_hex($norm);
    my $md5    = md5_hex($norm);

    isnt( $sha256, $md5, 'SHA-256 and MD5 hashes differ' );
    is( length($sha256), 64, 'SHA-256 hash is 64 hex chars' );
    is( length($md5),    32, 'MD5 hash is 32 hex chars' );

    # Case-normalisation must be consistent with what the endpoint does
    is( sha256_hex( lc($email) ), $sha256, 'lc() gives stable SHA-256' );
    is( md5_hex( lc($email) ),    $md5,    'lc() gives stable MD5' );

    # Simulate the lookup: given a hash, find the matching email
    my @users = (
        { name => 'alice', contact_email => 'alice@example.com' },
        { name => 'bob',   contact_email => 'bob@example.com' },
    );
    my $target_hash = sha256_hex( lc('alice@example.com') );
    my $matched;
    for my $u (@users) {
        my $e = lc( $u->{contact_email} );
        if ( $target_hash eq sha256_hex($e) || $target_hash eq md5_hex($e) ) {
            $matched = $u->{name};
            last;
        }
    }
    is( $matched, 'alice', 'SHA-256 lookup finds the correct user' );

    my $target_md5 = md5_hex( lc('bob@example.com') );
    $matched = undef;
    for my $u (@users) {
        my $e = lc( $u->{contact_email} );
        if ( $target_md5 eq sha256_hex($e) || $target_md5 eq md5_hex($e) ) {
            $matched = $u->{name};
            last;
        }
    }
    is( $matched, 'bob', 'MD5 lookup finds the correct user' );

    # Unknown hash returns no match
    $matched = undef;
    for my $u (@users) {
        my $e = lc( $u->{contact_email} );
        if ( 'deadbeef' eq sha256_hex($e) || 'deadbeef' eq md5_hex($e) ) {
            $matched = $u->{name};
            last;
        }
    }
    is( $matched, undef, 'unknown hash returns no match' );
};

done_testing;
