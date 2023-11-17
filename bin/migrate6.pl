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

#$dbh->do("ALTER TABLE user ADD COLUMN display_name TEXT DEFAULT NULL;");

# Update all the profile type posts to have correct display names
use Trog::Auth;
use JSON::MaybeXS;
use File::Slurper;
use URI::Escape;
use Data::Dumper;

my $global_changes;
opendir(my $dh, 'data/files');
while (my $entry = readdir $dh) {
	my $fname = "data/files/$entry";
	next unless -f $fname;
	my $contents = File::Slurper::read_binary($fname);
	my $decoded = JSON::MaybeXS::decode_json($contents);
	next unless List::Util::any { $_->{is_profile} } @$decoded;

	# If the title on the profile post responsds to a username, then let's change that to a display name
	my $made_changes;
	foreach my $revision (@$decoded) {
		my $user = $revision->{title};
		my $display_name = Trog::Auth::username2display($user);
		next unless $display_name;
		print "converting $user to display name $display_name\n";
		$revision->{title}      = $display_name;
		$revision->{local_href} = "/users/$display_name";
		$made_changes = 1;
	}
	next unless $made_changes;
	
	print "Writing changes to $fname\n";
	my $encoded = JSON::MaybeXS::encode_json($decoded);
	File::Slurper::write_binary($fname, $encoded);

	# Next, waste and rebuild the posts index for these user posts
	$global_changes=1;
}
print "Changes made.  Please rebuild the posts index.\n" if $global_changes;
