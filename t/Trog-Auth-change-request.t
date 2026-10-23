#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use FindBin::libs;

use Test::More;
use Cwd();
use File::Copy();
use File::Path();
use File::Temp();

# Auth keeps its database at config/auth.db under the cwd, so it gets a sandbox.
my $repo = Cwd::getcwd();
my $root = File::Temp::tempdir( CLEANUP => 1 );
File::Path::make_path( "$root/config", "$root/schema" );
File::Copy::copy( "$repo/schema/auth.schema", "$root/schema/auth.schema" ) or die $!;
chdir($root)                                                               or die "chdir $root: $!";
END { chdir($repo) if $repo }

require_ok('Trog::Auth') or BAIL_OUT("Can't find SUT");

my $dbh = Trog::SQLite::dbh( 'schema/auth.schema', 'config/auth.db' );
sub contact_of ($user) { return $dbh->selectrow_hashref( 'SELECT display_name, contact_email FROM user WHERE name = ?', undef, $user ) }

subtest 'process_change_request: each reset keeps its own user' => sub {
    Trog::Auth::useradd( qw{alice Alice old}, [], 'alice@test.test' );
    Trog::Auth::useradd( qw{bob Bob old},     [], 'bob@test.test' );
    Trog::Auth::add_change_request( user => $_, token => "t-$_", type => 'reset_pass', secret => 'new' ) for qw{alice bob};

    like( Trog::Auth::process_change_request('t-alice'), qr/for[ ]alice/, 'the first reset is done' );
    like( Trog::Auth::process_change_request('t-bob'),   qr/for[ ]bob/,   'and the second' );

    is_deeply( contact_of('alice'), { display_name => 'Alice', contact_email => 'alice@test.test' }, 'the first user is as they were' );
    is_deeply( contact_of('bob'),   { display_name => 'Bob',   contact_email => 'bob@test.test' },   'and the second keeps their own name and address, not the first one\'s' );
};

done_testing();
