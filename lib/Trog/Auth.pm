package Trog::Auth;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use DBI;
use DBD::SQLite;
use File::Slurper qw{read_text};
use UUID::Tiny ':std';
use Digest::SHA 'sha256';

=head1 Trog::Auth

An SQLite3 authdb.

=head1 Termination Conditions

Throws exceptions in the event the session database cannot be accessed.

=head1 FUNCTIONS

=head2 session2user(sessid) = STRING

Translate a session UUID into a username.

Returns empty string on no active session.

=cut

sub session2user ($sessid) {
    my $dbh = _dbh();
    my $rows = $dbh->selectall_arrayref("SELECT name FROM sess_user WHERE session=?",{ Slice => {} }, $sessid);
    return '' unless ref $rows eq 'ARRAY' && @$rows;
    return $rows->[0]->{name};
}

=head2 mksession(user, pass) = STRING

Create a session for the user and waste all other sessions.

Returns a session ID, or blank string in the event the user does not exist or incorrect auth was passed.

=cut

sub mksession ($user,$pass) {
    my $dbh = _dbh();
    my $records = $dbh->selectall_arrayref("SELECT salt FROM user WHERE name = ?", { Slice => {} }, $user);
    return '' unless ref $records eq 'ARRAY' && @$records;
    my $salt = $records->[0]->{salt};
    my $hash = sha256($pass.$salt);
    my $worked = $dbh->selectall_arrayref("SELECT id FROM user WHERE hash=? AND name = ?", { Slice => {} }, $hash, $user);
    return '' unless ref $worked eq 'ARRAY' && @$worked;
    my $uid = $worked->[0]->{id};
    my $uuid = create_uuid_as_string(UUID_V1, UUID_NS_DNS);
    $dbh->do("INSERT OR REPLACE INTO session (id,user_id) VALUES (?,?)", undef, $uuid, $uid) or return '';
    return $uuid;
}

=head2 useradd(user, pass) = BOOL

Adds a user identified by the provided password into the auth DB.

Returns True or False (likely false when user already exists).

=cut

sub useradd ($user, $pass) {
    my $dbh = _dbh();
    my $salt = create_uuid();
    my $hash = sha256($pass.$salt);
    return $dbh->do("INSERT INTO user (name,salt,hash) VALUES (?,?,?)", undef, $user, $salt, $hash);
}

my $dbh;
# Ensure the db schema is OK, and give us a handle
sub _dbh {
    return $dbh if $dbh;
    my $qq = read_text('schema/auth.schema');
    my $dbname = "$ENV{HOME}/.tcms/auth.db";
    $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","");
    $dbh->{sqlite_allow_multiple_statements} = 1;
    $dbh->do($qq) or die "Could not ensure auth database consistency";
    $dbh->{sqlite_allow_multiple_statements} = 0;
    return $dbh;
}

1;
