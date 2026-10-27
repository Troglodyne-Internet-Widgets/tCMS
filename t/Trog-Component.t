#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};

use FindBin::libs;

use Text::Xslate ();

require_ok('Trog::Component') or BAIL_OUT("Can't find SUT");

# Fixtures, registered in %INC so that _load()'s require() is satisfied without
# anything landing on disk in the real lib tree.
BEGIN {
    $INC{'Trog/Component/TestFixture.pm'}  = 1;
    $INC{'Trog/Component/TestSilent.pm'}   = 1;
    $INC{'Trog/Component/TestTriplet.pm'}  = 1;
    $INC{'Trog/Component/TestBoom.pm'}     = 1;
    $INC{'Trog/Component/TestRecurse.pm'}  = 1;
    $INC{'Trog/Component/TestNoRender.pm'} = 1;
}

our @ARGS_SEEN;

{

    package Trog::Component::TestFixture;
    sub render { @ARGS_SEEN = @_; return '<b>fixture</b>' }

    package Trog::Component::TestSilent;
    sub render { return undef }

    package Trog::Component::TestTriplet;
    sub render { return [ 500, [], ['boom'] ] }

    package Trog::Component::TestBoom;
    sub render { die "kaboom\n" }

    package Trog::Component::TestRecurse;
    sub render { return Trog::Component::component('TestRecurse') }

    package Trog::Component::TestNoRender;
    sub nope { return 1 }
}

subtest 'name validation' => sub {

    # Every one of these reaches require() as a path if it gets past the check.
    my %bad = (
        'traversal'     => '../../etc/passwd',
        'separator'     => 'Foo/Bar',
        'package sep'   => 'Foo::Bar',
        'leading digit' => '9Lives',
        'empty'         => '',
        'space'         => 'Emoji Picker',
        'dot'           => 'Foo.pm',
        'nul'           => "Foo\0Bar",
    );

    foreach my $case ( sort keys %bad ) {
        like(
            exception { Trog::Component::component( $bad{$case} ) },
            qr/component[ ]name/i,
            "$case rejected before anything is loaded"
        );
    }

    like( exception { Trog::Component::component(undef) }, qr/component[ ]name/i, "undef rejected" );

    # Nothing above should have made it as far as %INC.
    is( scalar( grep { m{^Trog/Component/} && !m{^Trog/Component/Test} } keys %INC ), 0, "no stray component was loaded" );
};

subtest 'loading' => sub {
    like(
        exception { Trog::Component::component('NoSuchComponentHere') },
        qr/NoSuchComponentHere/,
        "unknown component dies naming the component"
    );

    like(
        exception { Trog::Component::component('TestNoRender') },
        qr/no[ ]render/i,
        "a module without render() is not a component"
    );
};

subtest 'render' => sub {
    local @main::ARGS_SEEN = ();

    my $out = Trog::Component::component('TestFixture');
    is( "$out", '<b>fixture</b>', "component output comes back" );
    isa_ok( $out, 'Text::Xslate::Type::Raw', "output is marked raw so callers need no mark_raw" );
    is_deeply( \@ARGS_SEEN, [], "no args passed means render() sees none" );

    Trog::Component::component( 'TestFixture', { album => 'holiday', cols => 3 } );
    is_deeply( {@ARGS_SEEN}, { album => 'holiday', cols => 3 }, "args hash is flattened into render()" );

    Trog::Component::component( 'TestFixture', 'not a hashref' );
    is_deeply( \@ARGS_SEEN, [], "a non-hashref second arg is ignored rather than fatal" );
};

subtest 'failure modes' => sub {

    # Trog::Renderer::render() answers failure with a PSGI triplet, which is
    # meaningless halfway through a template.
    like(
        exception { Trog::Component::component('TestTriplet') },
        qr/TestTriplet\N*ARRAY/,
        "a PSGI triplet is caught rather than leaking into the page"
    );

    like(
        exception { Trog::Component::component('TestSilent') },
        qr/rendered[ ]nothing/,
        "an undef render is a failure, not an empty component"
    );

    like(
        exception { Trog::Component::component('TestBoom') },
        qr/TestBoom.*kaboom/s,
        "a component's own die is re-thrown naming the component"
    );
};

subtest 'recursion guard' => sub {
    no warnings qw{once};
    local $Trog::Component::MAX_DEPTH = 5;

    my $err = exception { Trog::Component::component('TestRecurse') };
    like( $err, qr/recursed[ ]more[ ]than[ ]5[ ]deep/, "self-referential component dies bounded" );

    is( $Trog::Component::depth, 0, "depth unwinds after the die" );
};

subtest 'as an xslate function' => sub {

    # Same shape as the injection in Trog::Renderer::Base::render().
    my $tx = Text::Xslate->new( function => { component => \&Trog::Component::component } );

    is(
        $tx->render_string( q{<: component('TestFixture') :>}, {} ),
        '<b>fixture</b>',
        "markup survives unescaped without | mark_raw"
    );

    is(
        $tx->render_string( q{<: component('TestFixture', { cols => 3 }) :>}, {} ),
        '<b>fixture</b>',
        "the args form parses in a template"
    );
};

subtest 'a failure inside a template is not swallowed' => sub {
    no warnings qw{once};

    my $tx = Text::Xslate->new( function => { component => \&Trog::Component::component } );

    # Xslate catches the die, warns, and renders on with a hole where the call
    # was -- which is exactly why $error exists.  Muffle the warning so the test
    # output stays readable.
    my $render = sub {
        my ($template) = @_;
        local $Trog::Component::error;
        local $SIG{__WARN__} = sub { };
        my $out = $tx->render_string( $template, {} );
        return ( $out, $Trog::Component::error );
    };

    my ( $out, $err ) = $render->(q{before<: component('../../etc/passwd') :>after});
    is( $out, 'beforeafter', "Xslate really does render on past a dead component" );
    like( $err, qr/component[ ]name/i, "...and the failure is recorded for the renderer to find" );

    ( $out, $err ) = $render->(q{<: component('TestBoom') :>});
    like( $err, qr/TestBoom/, "a component's own death is recorded" );

    ( $out, $err ) = $render->(q{<: component('TestFixture') :>});
    is( $err, undef, "a good render leaves no error behind" );

    # Trog::Renderer::Base localises $error per render, so a nested render
    # cannot inherit a stale one.
    ( $out, $err ) = $render->(q{<: component('TestBoom') :><: component('TestFixture') :>});
    like( $err, qr/TestBoom/, "the first failure wins, not the last" );
};

subtest 'render_template' => sub {
    require Trog::Renderer;

    my %seen;
    my $renderer = Test::MockModule->new('Trog::Renderer');
    $renderer->redefine( render => sub ( $class, %args ) { %seen = %{ $args{data} }; return 'rendered' } );
    my $themes = Test::MockModule->new('Trog::Themes');

    $themes->redefine( td => sub { '/themes/bogus' } );
    is( Trog::Component::render_template( 'bogus.tx', { title => 'x' } ), 'rendered', "the body of the render comes back" );
    is_deeply( \%seen, { title => 'x', theme_dir => '/themes/bogus' }, "a template that is passed no theme_dir gets the URL path of the theme" );

    Trog::Component::render_template( 'bogus.tx', { theme_dir => undef } );
    is( $seen{theme_dir}, '/themes/bogus', "an undefined theme_dir is filled in, as the Header component passes one" );

    Trog::Component::render_template( 'bogus.tx', { theme_dir => '/themes/other' } );
    is( $seen{theme_dir}, '/themes/other', "a theme_dir that the caller passes wins" );

    $themes->redefine( td => sub { '' } );
    Trog::Component::render_template('bogus.tx');
    is( $seen{theme_dir}, '', "theme_dir is empty when there is no theme" );

    $renderer->redefine( render => sub { [ 500, [], ['boom'] ] } );
    like( exception { Trog::Component::render_template('bogus.tx') }, qr/component[ ]template[ ]'bogus[.]tx'/, "a failed render dies naming the template" );
};

subtest 'through the real renderer' => sub {
    require Trog::Renderer::Base;

    # posts.tx is the live call site; render it as an editor with no posts and
    # the EmojiPicker component has to come back through the whole stack.
    my $body = eval {
        Trog::Renderer::Base::render(
            template    => 'posts.tx',
            contenttype => 'text/html',
            component   => 1,
            data        => {
                can_edit =>  1,
                direct   =>  1,
                failure  => -1,
                posts    => [],
                forms    => [],
                ( map { $_ => undef } qw{acls app category embed footers headers in_series like limit message months newer nochrome older page pages pages_total paginate_offset post post_visibilities primary_post route rss sizes style subhead tiled to years} ),
            },
        );
    };
    my $err = $@;

  SKIP: {
        skip( "no emoji list on disk -- run make prereq-frontend", 2 )
          if $err && $err =~ m/list\.min\.json|prereq-frontend/;
        is( $err, '', "posts.tx renders" ) or diag($err);
        like( $body, qr/id="emoji-container"/, "component('EmojiPicker') reached the page" );
    }
};

done_testing();
