use strict;
use warnings;

use Test::More;
use Test::MockModule qw{strict};
use FindBin;

use lib "$FindBin::Bin/../lib";

# Stub missing non-core modules before requiring anything that pulls them in
BEGIN {
    $INC{'Log/Dispatch.pm'}          = 1;
    $INC{'Log/Dispatch/DBI.pm'}      = 1;
    $INC{'Log/Dispatch/Screen.pm'}   = 1;
    $INC{'Log/Dispatch/FileRotate.pm'} = 1;
    $INC{'Trog/Log/DBI.pm'}          = 1;
    $INC{'Config/Simple.pm'}         = 1;
    $INC{'HTTP/Tiny/UNIX.pm'}        = 1;
    $INC{'File/LibMagic.pm'}         = 1;
    $INC{'Imager/QRCode.pm'}         = 1;

    package Log::Dispatch;
    sub new { bless {}, shift }
    sub add { }
    sub log { }

    package Config::Simple;
    sub new { bless {}, shift }
    sub vars { {} }
}

require_ok('Trog::DataModule') or BAIL_OUT("Can't load Trog::DataModule");

# ── _title_to_slug ────────────────────────────────────────────────────────────

subtest '_title_to_slug — basic cases' => sub {
    is( Trog::DataModule::_title_to_slug('Hello World'),
        'hello-world', 'spaces become hyphens, lowercased' );

    is( Trog::DataModule::_title_to_slug('Hello World - A Test!'),
        'hello-world-a-test', 'punctuation stripped, hyphen preserved' );

    is( Trog::DataModule::_title_to_slug('  -- Leading Hyphens --  '),
        'leading-hyphens', 'leading/trailing hyphens and spaces trimmed' );

    is( Trog::DataModule::_title_to_slug('C++ Programming'),
        'c-programming', 'consecutive non-alnum collapsed to one hyphen' );

    is( Trog::DataModule::_title_to_slug("I'm a title"),
        'im-a-title', 'apostrophe stripped cleanly' );
};

subtest '_title_to_slug — empty/whitespace-only' => sub {
    is( Trog::DataModule::_title_to_slug(''),    '', 'empty string gives empty slug' );
    is( Trog::DataModule::_title_to_slug('!!!'), '', 'all punctuation gives empty slug' );
    is( Trog::DataModule::_title_to_slug('   '), '', 'whitespace-only gives empty slug' );
};

subtest '_title_to_slug — truncation' => sub {
    my $long = 'this is a very long post title that will need to be truncated because it exceeds the limit';
    my $slug = Trog::DataModule::_title_to_slug($long);
    ok( length($slug) <= $Trog::DataModule::SLUG_MAX_LENGTH,
        "slug length <= SLUG_MAX_LENGTH ($Trog::DataModule::SLUG_MAX_LENGTH)" );
    unlike( $slug, qr/-$/, 'slug does not end with a hyphen after truncation' );
};

subtest '_title_to_slug — underscores treated as whitespace' => sub {
    is( Trog::DataModule::_title_to_slug('snake_case_title'),
        'snake-case-title', 'underscores become hyphens' );
};

# ── add() — slug alias injection ──────────────────────────────────────────────
# We test through a minimal subclass that stubs out the I/O methods.

{
    package TestDataModule;
    use parent -norequire, 'Trog::DataModule';

    sub new {
        my ( $class, %args ) = @_;
        return bless { %args }, $class;
    }

    sub read  { [] }
    sub write { }

    sub get {
        my ( $self, %args ) = @_;
        return @{ $self->{_existing} // [] } if $args{id};
        return ();
    }

    sub aliases {
        my ($self) = @_;
        return %{ $self->{_aliases} // {} };
    }
}

sub make_dm {
    my (%args) = @_;
    return TestDataModule->new(%args);
}

subtest 'add() auto-adds slug alias for plain post' => sub {
    my $dm = make_dm();

    my %post = (
        id         => 'test-uuid-1',
        title      => 'My First Blog Post',
        visibility => 'public',
        aliases    => [],
        tags       => ['public'],
    );
    $dm->add( \%post );

    ok( grep { $_ eq '/posts/my-first-blog-post' } @{ $post{aliases} },
        'slug alias /posts/my-first-blog-post added' );
};

subtest 'add() skips slug for series post (aclname present)' => sub {
    my $dm = make_dm();

    my %post = (
        id         => 'test-uuid-2',
        title      => 'My Series',
        aclname    => 'my-series',
        visibility => 'public',
        aliases    => [],
        tags       => ['public'],
    );
    $dm->add( \%post );

    ok( !grep { $_ eq '/posts/my-series' } @{ $post{aliases} },
        'slug alias NOT added for series post' );
};

subtest 'add() skips slug for user post (callback=users)' => sub {
    my $dm = make_dm();

    my %post = (
        id           => 'test-uuid-3',
        title        => 'Jane Doe',
        callback     => 'Trog::Routes::HTML::users',
        display_name => 'Jane Doe',
        visibility   => 'public',
        aliases      => [],
        tags         => ['public'],
    );
    $dm->add( \%post );

    ok( !grep { $_ eq '/posts/jane-doe' } @{ $post{aliases} },
        'slug alias NOT added for user post' );
};

subtest 'add() skips slug when already in aliases (re-save)' => sub {
    my $dm = make_dm();

    my %post = (
        id         => 'test-uuid-4',
        title      => 'My Post',
        visibility => 'public',
        aliases    => ['/posts/my-post'],    # already there
        tags       => ['public'],
    );
    $dm->add( \%post );

    my @slug_aliases = grep { $_ eq '/posts/my-post' } @{ $post{aliases} };
    is( scalar @slug_aliases, 1, 'slug alias present exactly once after re-save' );
};

subtest 'add() skips slug when taken by another post' => sub {
    my $dm = make_dm( _aliases => { '/posts/my-post' => '/posts/other-uuid' } );

    my %post = (
        id         => 'test-uuid-5',
        title      => 'My Post',
        visibility => 'public',
        aliases    => [],
        tags       => ['public'],
    );
    $dm->add( \%post );

    ok( !grep { $_ eq '/posts/my-post' } @{ $post{aliases} },
        'slug alias NOT added when already taken by a different post' );
};

subtest 'add() allows slug that maps back to same post (idempotent re-slug)' => sub {
    my $dm = make_dm( _aliases => { '/posts/my-post' => '/posts/test-uuid-6' } );

    my %post = (
        id         => 'test-uuid-6',
        title      => 'My Post',
        local_href => '/posts/test-uuid-6',
        visibility => 'public',
        aliases    => [],
        tags       => ['public'],
    );
    $dm->add( \%post );

    ok( grep { $_ eq '/posts/my-post' } @{ $post{aliases} },
        'slug alias re-added when existing alias already maps to this post' );
};

done_testing;
