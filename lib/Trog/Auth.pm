package Trog::Auth;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use UUID::Tiny ':std';
use Digest::SHA 'sha256';
use Trog::SQLite;

=head1 Trog::Auth

An SQLite3 authdb.

=head1 Termination Conditions

Throws exceptions in the event the session database cannot be accessed.

=head1 FUNCTIONS

=head2 session2user(sessid) = (STRING, INT)

Translate a session UUID into a username and id.

Returns empty strings on no active session.

=cut

sub session2user ($sessid) {
    my $dbh = _dbh();
    my $rows = $dbh->selectall_arrayref("SELECT name,id FROM sess_user WHERE session=?",{ Slice => {} }, $sessid);
    return ('','') unless ref $rows eq 'ARRAY' && @$rows;
    return ($rows->[0]->{name},$rows->[0]->{id});
}

=head2 acls4user(user_id) = ARRAYREF

Return the list of ACLs belonging to the user.
The function of ACLs are to allow you to access content tagged 'private' which are also tagged with the ACL name.

The 'admin' ACL is the only special one, as it allows for authoring posts, configuring tCMS, adding series (ACLs) and more.

=cut

sub acls4user($user_id) {
    my $dbh = _dbh();
    my $records = $dbh->selectall_arrayref("SELECT acl FROM user_acl WHERE user_id = ?", { Slice => {} }, $user_id);
    return () unless ref $records eq 'ARRAY' && @$records;
    my @acls = map { $_->{acl} } @$records;
    return \@acls;
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

=head2 killsession(user) = BOOL

Delete the provided user's session from the auth db.

=cut

sub killsession ($user) {
    my $dbh = _dbh();
    $dbh->do("DELETE FROM session WHERE user_id IN (SELECT id FROM user WHERE name=?)",undef,$user);
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
        return unless $dbh->do("INSERT OR REPLACE INTO user_acl (user_id,acl) VALUES ((SELECT id FROM user WHERE name=?),?)", undef, $user, $acl);
    }
    return 1;
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "$ENV{HOME}/.tcms/auth.db";
    return Trog::SQLite::dbh($file,$dbname);
}

1;
