#!/usr/bin/env perl

# Migrate to 2FA

use v5.36;
use re '/aa';

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::SQLite;

=head1 SYNOPSIS

Migrate to 2FA.

Adds the totp_secret column to the auth database's user table, which is where
Trog::Auth::totp() stores a user's TOTP secret once they enroll.

=head2 USAGE

    bin/migrate4.pl

Run from the tCMS root, as the schema and database paths are relative to it.

=head2 CAVEATS

Historical, and not idempotent -- SQLite will refuse a second ALTER TABLE for a
column which already exists, so re-running it dies rather than doing nothing.

Existing users end up with a NULL secret, which is to say 2FA off, and can
enroll whenever they like.

=cut

sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

my $dbh = _dbh();

$dbh->do("ALTER TABLE user ADD COLUMN totp_secret TEXT DEFAULT NULL;");
