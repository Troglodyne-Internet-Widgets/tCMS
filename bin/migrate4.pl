#!/usr/bin/env perl

# Migrate to 2FA

use strict;
use warnings;

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::SQLite;
sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh($file,$dbname);
}

my $dbh = _dbh();

$dbh->do("ALTER TABLE user ADD COLUMN totp_secret TEXT DEFAULT NULL;");
