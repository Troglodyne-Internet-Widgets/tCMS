use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal qw{exception};
use Path::Tiny();
use FindBin;

use lib "$FindBin::Bin/../lib";

# Nothing in this file may ever reach a real hypervisor.  Every libvirt object
# here is a fake that records what was asked of it, which is the only safe way
# to test the destructive half: the machine this suite runs on is itself a
# guest of the hypervisor the feature talks to.
require_ok('Trog::DataSource::Virt') or BAIL_OUT("Can't find SUT");

my $logmock = Test::MockModule->new('Trog::DataSource::Virt');
$logmock->redefine( WARN => sub { note(shift) } );
$logmock->redefine( INFO => sub { note(shift) } );

our @CALLS;

{
    package FakeDomain;
    sub new { my ( $c, %a ) = @_; return bless {%a}, $c }
    sub get_name        { $_[0]{name} }
    sub get_uuid_string { $_[0]{uuid} }
    sub is_active       { $_[0]{active} }
    sub get_info        { { state => $_[0]{state}, memory => 1024, nrVirtCpu => 2 } }

    # The operations we must never actually perform: record and return.
    sub create        { push @main::CALLS, [ 'create',        $_[0]{name} ]; 1 }
    sub shutdown      { push @main::CALLS, [ 'shutdown',      $_[0]{name} ]; 1 }
    sub destroy       { push @main::CALLS, [ 'destroy',       $_[0]{name} ]; 1 }
    sub create_snapshot { push @main::CALLS, [ 'create_snapshot', $_[0]{name} ]; 1 }
}

{
    package FakeConn;
    sub new { bless {}, shift }
    sub list_all_domains {
        return (
            FakeDomain->new( name => 'alpha', uuid => 'uuid-alpha', active => 1, state => 1 ),
            FakeDomain->new( name => 'beta',  uuid => 'uuid-beta',  active => 0, state => 5 ),
        );
    }
}

my $connect_fails = 0;
my $virtmock = Test::MockModule->new('Sys::Virt');
$virtmock->redefine(
    new => sub {
        die "libvirt error: nope\n" if $connect_fails;
        return FakeConn->new();
    }
);

my $series = {
    child_form  => 'guests.tx',
    tags        => ['guests'],
    visibility  => 'private',
    user        => 'specadmin',
    hypervisors => [ { id => 'hv-1', title => 'spec-hv', conn_uri => 'test:///default' } ],
};

subtest 'guests become posts' => sub {
    @CALLS = ();
    my @posts = Trog::DataSource::Virt::posts( $series, { user_acls => ['admin'] } );

    is( scalar @posts, 2, 'one post per guest' );
    is( $posts[0]{title}, 'alpha',      'named after the guest' );
    is( $posts[0]{id},    'uuid-alpha', "and identified by the guest's uuid, not ours" );
    is( $posts[0]{form},  'guests.tx',  "wearing the series' child type" );
    is( $posts[0]{state}, 'running',    'with a legible state' );
    is( $posts[1]{state}, 'shut off',   '...for each of libvirt\'s numeric ones' );
    is( $posts[0]{is_active}, 1, 'active guests are marked so' );
    is( $posts[1]{is_active}, 0, 'and inactive ones are not' );

    # The listing must not take screenshots: that is a per-guest round trip,
    # and it is the browser's job via the preview route.
    is( $posts[0]{preview}, '/guest/screenshot/hv-1/alpha', 'the preview is a route, not an inline capture' );
    is_deeply( \@CALLS, [], 'and nothing was done to any guest merely by listing' );

    is_deeply( $posts[0]{tags}, ['guests'], "children inherit the series' tags" );
    is( $posts[0]{visibility}, 'private', 'and its visibility' );
};

subtest 'an unreachable hypervisor says so rather than vanishing' => sub {
    $connect_fails = 1;
    my @posts = Trog::DataSource::Virt::posts( $series, { user_acls => ['admin'] } );
    $connect_fails = 0;

    is( scalar @posts, 1, 'we get a post back' );
    ok( $posts[0]{unreachable}, 'flagged as unreachable' );
    like( $posts[0]{state}, qr/unreachable/, 'saying as much' );
    is( $posts[0]{title}, 'spec-hv', 'named for the hypervisor we could not reach' );
};

subtest 'act() drives the right libvirt call, and only on request' => sub {
    my %expected = (
        poweron  => 'create',
        poweroff => 'shutdown',
        snapshot => 'create_snapshot',
        destroy  => 'destroy',
    );

    foreach my $action ( sort keys %expected ) {
        @CALLS = ();
        my ( $ok, $message ) = Trog::DataSource::Virt::act( $action, 'test:///default', 'alpha', 'specadmin' );
        ok( $ok, "$action succeeded" ) or diag($message);
        is_deeply( \@CALLS, [ [ $expected{$action}, 'alpha' ] ], "$action called $expected{$action} on the named guest, once" );
    }
};

subtest 'act() refuses what it should' => sub {
    @CALLS = ();

    my ( $ok, $message ) = Trog::DataSource::Virt::act( 'rm-rf', 'test:///default', 'alpha', 'specadmin' );
    ok( !$ok, 'an action we do not define is refused' );
    like( $message, qr/not something we do/, 'and says so' );

    ( $ok, $message ) = Trog::DataSource::Virt::act( 'destroy', 'test:///default', '../../etc/passwd', 'specadmin' );
    ok( !$ok, 'a guest name that is a path is refused' );
    like( $message, qr/bad guest name/, 'before any connection is made' );

    ( $ok, $message ) = Trog::DataSource::Virt::act( 'destroy', 'test:///default', 'nosuchguest', 'specadmin' );
    ok( !$ok, 'a guest that is not there is refused' );
    like( $message, qr/no guest called/, 'rather than acting on some other one' );

    is_deeply( \@CALLS, [], 'and none of those touched a guest' );

    $connect_fails = 1;
    ( $ok, $message ) = Trog::DataSource::Virt::act( 'poweroff', 'test:///default', 'alpha', 'specadmin' );
    $connect_fails = 0;
    ok( !$ok, 'an unreachable hypervisor is refused' );
    like( $message, qr/could not reach/, 'and reported' );
    is_deeply( \@CALLS, [], 'having done nothing' );
};

subtest 'screenshot() validates the guest name before anything else' => sub {
    my ( $path, $why ) = Trog::DataSource::Virt::screenshot( 'test:///default', '../../../etc/passwd' );
    is( $path, undef, 'a path-shaped guest name gets no screenshot' );
    like( $why, qr/bad domain name/, 'and is named as the reason' );

    ( $path, $why ) = Trog::DataSource::Virt::screenshot( 'test:///default', 'alpha/../../beta' );
    is( $path, undef, 'nor does one with traversal in the middle' );
};

subtest 'the datasource hook only loads what it should' => sub {
    require Trog::Routes::HTML;

    my $htmlmock = Test::MockModule->new('Trog::Routes::HTML');
    $htmlmock->redefine( WARN => sub { note(shift) } );

    my $declared;
    my $dmmock = Test::MockModule->new('Trog::DataModule');
    $dmmock->redefine( type_meta_for => sub { return { 'x-tcms-datasource' => $declared } } );

    my @stored = ( { title => 'a stored post' } );
    my $query  = { primary_post => { child_form => 'guests.tx' }, user_acls => ['admin'] };

    # A type that declares nothing keeps its own posts -- this hook must be
    # invisible to the overwhelming majority of pages.
    $declared = undef;
    is_deeply( [ Trog::Routes::HTML::_datasource_posts( $query, \@stored ) ], \@stored, 'no datasource declared, posts untouched' );

    # The namespace restriction is the point: a sidecar is a file on disk, and
    # it must not be able to make us require an arbitrary module.
    foreach my $bad ( 'Trog::Routes::HTML', 'File::Path', '../../etc/passwd', 'Trog::DataSource::Virt::act' ) {
        $declared = $bad;
        is_deeply( [ Trog::Routes::HTML::_datasource_posts( $query, \@stored ) ], \@stored, "'$bad' is refused as a datasource" );
    }

    # One that does not exist is a warning, not a dead page.
    $declared = 'Trog::DataSource::Nonexistent';
    is_deeply( [ Trog::Routes::HTML::_datasource_posts( $query, \@stored ) ], \@stored, 'a datasource that will not load falls back' );

    # And a real one is actually used.
    $declared = 'Trog::DataSource::Virt';
    $query->{primary_post}{hypervisors} = [ { id => 'hv-1', title => 'spec-hv', conn_uri => 'test:///default' } ];
    my @got = Trog::Routes::HTML::_datasource_posts( $query, \@stored );
    is( scalar @got,   2,       'a declared datasource replaces the stored posts' );
    is( $got[0]{title}, 'alpha', 'with what it built' );
};

done_testing();
