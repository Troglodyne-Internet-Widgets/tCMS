#!/usr/bin/env perl

# Display names

use v5.36;
use re '/aa';

use FindBin;

use lib "$FindBin::Bin/../lib";

use Trog::SQLite;

=head1 SYNOPSIS

Display names.

Adds the display_name column to the auth database's user table, then walks the
flat file posts and converts profile posts from being titled with the user's
login name to being titled with their display name, moving them from
/users/<login> to /users/<display name> in the process.

=head2 USAGE

    bin/migrate6.pl

Run from the tCMS root.  Rebuild the post index afterwards, as the profile
posts have changed their local_href and the routes table still points at the
old one -- the script says so when it has actually changed something.

=head2 CAVEATS

Historical, and not idempotent -- SQLite will refuse a second ALTER TABLE for a
column which already exists, so re-running it dies rather than doing nothing.

Post revisions are rewritten in place rather than through the data model, so
take a backup of data/ before running it.

Users with no display name set are skipped, which leaves their profile post
where it was.

=cut

sub _dbh {
    my $file   = 'schema/auth.schema';
    my $dbname = "config/auth.db";
    return Trog::SQLite::dbh( $file, $dbname );
}

my $dbh = _dbh();

$dbh->do("ALTER TABLE user ADD COLUMN display_name TEXT DEFAULT NULL;");

# Update all the profile type posts to have correct display names
use Trog::Auth;
use JSON::MaybeXS;
use File::Slurper;
use File::Slurper::Temp;
use URI::Escape;
use Data::Dumper;

my $global_changes;
opendir( my $dh, 'data/files' );
while ( my $entry = readdir $dh ) {
    my $fname = "data/files/$entry";
    next unless -f $fname;    ## no critic (ProhibitFiletest_f) -- skipping . and .. and any subdirs
    my $contents = File::Slurper::read_binary($fname);
    my $decoded  = JSON::MaybeXS::decode_json($contents);
    next unless List::Util::any { $_->{is_profile} } @$decoded;

    # If the title on the profile post responsds to a username, then let's change that to a display name
    my $made_changes;
    foreach my $revision (@$decoded) {
        my $user         = $revision->{title};
        my $display_name = Trog::Auth::username2display($user);
        next unless $display_name;
        print "converting $user to display name $display_name\n";
        $revision->{title}      = $display_name;
        $revision->{local_href} = "/users/$display_name";
        $made_changes           = 1;
    }
    next unless $made_changes;

    print "Writing changes to $fname\n";
    my $encoded = JSON::MaybeXS::encode_json($decoded);

    # Temp:: rather than plain File::Slurper -- it writes to a tempfile and
    # renames over the target, so a crash partway can't leave a half written
    # post behind.
    File::Slurper::Temp::write_binary( $fname, $encoded );

    # Next, waste and rebuild the posts index for these user posts
    $global_changes = 1;
}
print "Changes made.  Please rebuild the posts index.\n" if $global_changes;
