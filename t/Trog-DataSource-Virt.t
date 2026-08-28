use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use Test::Fatal qw{exception};
use Path::Tiny();
use JSON::MaybeXS();
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

    # Reading a console is not a mutation, so this one really runs.
    sub screenshot { return 'image/png' }
}

{
    package FakeStream;
    sub new { bless {}, shift }
    sub recv_all { my ( $self, $cb ) = @_; $cb->( $self, 'fake-png-bytes' ); return 1 }
    sub finish   { 1 }
}

{
    package FakeConn;
    sub new { bless {}, shift }
    sub new_stream { FakeStream->new() }
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

subtest 'screenshot() validates its inputs before anything else' => sub {
    my $hv = { id => 'hv-1', conn_uri => 'test:///default' };

    my ( $path, $why ) = Trog::DataSource::Virt::screenshot( $hv, '../../../etc/passwd' );
    is( $path, undef, 'a path-shaped guest name gets no screenshot' );
    like( $why, qr/bad guest name/, 'and is named as the reason' );

    ( $path, $why ) = Trog::DataSource::Virt::screenshot( $hv, 'alpha/../../beta' );
    is( $path, undef, 'nor does one with traversal in the middle' );

    # The cache path is built from the hypervisor id too, so it has to be
    # checked as well -- otherwise it is a directory traversal of its own.
    ( $path, $why ) = Trog::DataSource::Virt::screenshot( { id => '../../..', conn_uri => 'test:///default' }, 'alpha' );
    is( $path, undef, 'nor does a path-shaped hypervisor id' );
    like( $why, qr/bad hypervisor id/, 'which is reported separately' );
};

subtest 'the guest cache is scoped per hypervisor' => sub {

    # Two hypervisors, each with a guest called 'alpha' -- which is the normal
    # state of affairs, not a corner case.
    my $root = Path::Tiny->tempdir();
    local $Trog::DataSource::Virt::screenshot_dir = "$root";

    my @paths;
    foreach my $id (qw{hv-1 hv-2}) {
        my ( $path, $why ) = Trog::DataSource::Virt::screenshot( { id => $id, conn_uri => 'test:///default' }, 'alpha' );
        ok( $path, "screenshot taken for $id" ) or diag($why);
        push( @paths, $path );
    }

    isnt( $paths[0], $paths[1], "two hypervisors' guests do not share a cache entry" );
    like( $paths[0], qr{/hv-1/alpha\.png$}, 'the path names the hypervisor and the guest' );
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

subtest 'the guest routes avoid the router\'s own query keys' => sub {
    require Trog::Routes::HTML;

    # TPSGI applies a route's captures in extract_query, and *then* overwrites
    # $query->{domain} with the request's own host.  A capture or form field by
    # that name therefore never reaches the callback -- which silently aimed
    # the screenshot and action routes at a guest named after the web host.
    my @reserved = qw{domain route method scheme port user acls to};

    my $captures = $Trog::Routes::HTML::routes{'/guest/screenshot/(.*)/(.*)'}{captures};
    foreach my $capture (@$captures) {
        ok( !( grep { $_ eq $capture } @reserved ), "the screenshot route's '$capture' capture is not a router key" );
    }

    # The action form posts the same field names the handler reads, so check
    # the template rather than trusting that they still agree.
    my $form = Path::Tiny->new("$FindBin::Bin/../www/templates/html/components/forms/guests.tx")->slurp_utf8;
    foreach my $reserved (@reserved) {
        unlike( $form, qr/name="\Q$reserved\E"/, "the guest action form does not post a field called '$reserved'" )
          unless $reserved eq 'to';    # 'to' is the redirect target, and is meant to be the router's
    }
    like( $form, qr/name="guest"/, 'it posts the guest under a name that survives routing' );
};

subtest 'guests show nothing an unprivileged viewer cannot use' => sub {
    require Text::Xslate;

    # Rendered rather than grepped: what matters is what a given viewer ends up
    # looking at, and the template has enough branches that reading it is not
    # the same as knowing.
    my $tx = Text::Xslate->new(
        path     => ["$FindBin::Bin/../www/templates/html/components"],
        function => { render_it => sub { $_[0] } },
    );

    my %post = (
        form    => 'guests.tx',
        id      => 'uuid-alpha', title  => 'alpha',  state   => 'running', is_active => 1,
        preview => '/guest/screenshot/hv-1/alpha',   domain  => 'alpha',
        hypervisor => 'hv-1', hypervisor_title => 'spec-hv', vcpus => 2,
        addpost => 0, unreachable => 0,
    );

    my %views = (
        'tiled, logged out'   => { tiled => 1, can_edit => 0 },
        'untiled, logged out' => { tiled => 0, can_edit => 0 },
        'untiled, admin'      => { tiled => 0, can_edit => 1 },
    );

    require Trog::Routes::HTML;

    foreach my $view ( sort keys %views ) {
        my $admin = $views{$view}{can_edit};

        # Redact the way posts() does before rendering, so this covers the
        # thing that actually protects the capture -- the template only decides
        # whether to draw an img for a value it was given.
        my %shown = %post;
        Trog::Routes::HTML::_redact_private( \%shown ) unless $admin;

        my $out = $tx->render( 'forms/guests.tx', { post => \%shown, style => '', route => '/vm', %{ $views{$view} } } );

        # The guest is always named -- that is the point of the page.
        like( $out, qr/alpha/, "$view: the guest is listed" );

        # The screenshot route requires the admin acl, so showing the img to
        # anyone else is a broken image and nothing else.
        is( scalar( () = $out =~ m/<img /g ), $admin ? 1 : 0, "$view: console capture shown only to an admin" );
        is( scalar( () = $out =~ m{href="/guest/screenshot}g ), $admin ? 1 : 0, "$view: and so is the link to it" );

        # Powering off, snapshotting and destroying likewise.
        is( scalar( () = $out =~ m{action="/guest/act"}g ), $admin ? 1 : 0, "$view: controls shown only to an admin" );
        foreach my $action (qw{poweroff snapshot destroy}) {
            is( scalar( () = $out =~ m/value="\Q$action\E"/g ), $admin ? 1 : 0, "$view: no $action button" ) unless $admin;
        }
    }
};

subtest 'the guests type declares its console capture private' => sub {
    require Trog::DataModule;

    is_deeply( Trog::DataModule::private_fields_for('guests.tx'), ['preview'],
        'so the url to it is withheld rather than guarded in the template' );
};

subtest 'private fields are dropped before a non-editor sees them' => sub {
    require Trog::Routes::HTML;
    require Trog::DataModule;

    my $dmmock = Test::MockModule->new('Trog::DataModule');
    $dmmock->redefine( private_fields_for => sub { return $_[0] eq 'secretive.tx' ? ['hidden'] : [] } );

    my $post = {
        form   => 'secretive.tx',
        title  => 'a post',
        hidden => 'the secret',
        shown  => 'not a secret',

        # A relation is a post in its own right, with its own private fields.
        related => { form => 'secretive.tx', title => 'related', hidden => 'another secret' },
        many    => [ { form => 'secretive.tx', hidden => 'a third secret' } ],
        other   => { form => 'ordinary.tx',   hidden => 'not declared private here' },
    };

    Trog::Routes::HTML::_redact_private($post);

    ok( !exists $post->{hidden},              'the private field is gone' );
    is( $post->{shown}, 'not a secret',       'and the public ones are not' );
    is( $post->{title}, 'a post',             '...including the ones every post has' );
    ok( !exists $post->{related}{hidden},     'a related post is redacted too' );
    ok( !exists $post->{many}[0]{hidden},     'and so is one reached through a list' );
    is( $post->{other}{hidden}, 'not declared private here', 'a type that declares nothing keeps everything' );
};

subtest 'a post that refers to itself does not hang the redactor' => sub {
    require Trog::Routes::HTML;
    require Trog::DataModule;

    my $dmmock = Test::MockModule->new('Trog::DataModule');
    $dmmock->redefine( private_fields_for => sub { return ['hidden'] } );

    my $post = { form => 'loop.tx', hidden => 'secret' };
    $post->{itself} = $post;

    # A relation can point back at whatever pulled it in.
    is( exception { Trog::Routes::HTML::_redact_private($post) }, undef, 'it terminates' );
    ok( !exists $post->{hidden}, 'having done the job' );
};

subtest 'a hypervisor does not show its connection uri to everyone' => sub {
    require Trog::DataModule;

    # The uri carries a host and a username, and these pages are public.  It is
    # declared private rather than guarded in the template, so the value is
    # dropped before rendering and the template needs no guard of its own.
    my $private = Trog::DataModule::private_fields_for('hypervisor.tx');
    is_deeply( $private, ['conn_uri'], 'the connection uri is declared private' );

    my $sidecar = JSON::MaybeXS::decode_json(
        Path::Tiny->new("$FindBin::Bin/../www/templates/html/components/forms/hypervisor.json")->slurp_utf8 );
    ok( $sidecar->{properties}{conn_uri}{'x-tcms-private'}, 'and says so in its sidecar' );
};

done_testing();
