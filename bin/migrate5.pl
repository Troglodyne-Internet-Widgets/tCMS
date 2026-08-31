#!/usr/bin/env perl

# Password reset code

use v5.36;
use re '/aa';

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::SQLite;

=head1 SYNOPSIS

Password reset code.

Adds the contact_email column to the auth database's user table, without which
there is nowhere to send a password reset to.

=head2 USAGE

    bin/migrate5.pl

Run from the tCMS root, as the schema and database paths are relative to it.

=head2 CAVEATS

Historical, and not idempotent -- SQLite will refuse a second ALTER TABLE for a
column which already exists, so re-running it dies rather than doing nothing.

Existing users end up with a NULL contact email and so can't reset their own
password until one is set.  Fix that with bin/tcms-useradd --contact_email.

=cut

sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

my $dbh = _dbh();

$dbh->do("ALTER TABLE user ADD COLUMN contact_email TEXT DEFAULT NULL;");
