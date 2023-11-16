#!/usr/bin/env perl

# Display names

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

$dbh->do("ALTER TABLE user ADD COLUMN display_name TEXT DEFAULT NULL;");
