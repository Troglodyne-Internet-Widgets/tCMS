#!/usr/bin/env perl

# A datasource's posts are built fresh on every view and have never been near
# the datastore, so the search the reader typed -- which get() applied to the
# datastore and then threw away along with the posts it filtered -- has to be
# applied to them by somebody.  This is that somebody.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Test::Fatal qw{exception};

require_ok('Trog::DataSource') or BAIL_OUT("Can't find SUT");

my $t = 1700000000;

sub guest {
    my ( $title, %o ) = @_;
    return {
        id      => "id-$title",
        title   => $title,
        data    => '',
        created => $t++,
        user    => 'bob',
        version => 0,
        %o,
    };
}

my @posts = (
    guest( 'webserver', state => 'running',  hypervisor_title => 'Rack One' ),
    guest( 'database',  state => 'shut off', hypervisor_title => 'Rack One' ),
    guest( 'mailhost',  state => 'running',  hypervisor_title => 'Rack Two', user => 'ann' ),
);

sub titles {
    my (@got) = @_;
    return [ sort map { $_->{title} } @got ];
}

subtest 'the default filter searches title and body' => sub {
    is_deeply( titles( Trog::DataSource::filter( {},    @posts ) ), titles(@posts), 'an empty query filters nothing' );
    is_deeply( titles( Trog::DataSource::filter( undef, @posts ) ), titles(@posts), 'and neither does no query at all' );

    is_deeply( titles( Trog::DataSource::filter( { like => 'web' },      @posts ) ), ['webserver'], 'a substring of the title matches' );
    is_deeply( titles( Trog::DataSource::filter( { like => 'SERVER' },   @posts ) ), ['webserver'], 'case insensitively' );
    is_deeply( titles( Trog::DataSource::filter( { like => 'erve' },     @posts ) ), ['webserver'], 'inside a word' );
    is_deeply( titles( Trog::DataSource::filter( { like => 'nonesuch' }, @posts ) ), [],            'and nothing matches nothing' );

    # The body counts too, for a source whose posts have one.
    my @bodied = ( guest( 'notes', data => 'the quick brown fox' ) );
    is_deeply( titles( Trog::DataSource::filter( { like => 'quick' }, @bodied ) ), ['notes'], 'the body is searched as well' );

    # The default does NOT know about a source's own fields -- that is what a
    # source implementing filter() is for.
    is_deeply( titles( Trog::DataSource::filter( { like => 'Rack One' }, @posts ) ), [], 'but a field it has never heard of is not' );
};

subtest 'the rest of the query still means what it means' => sub {
    is_deeply( titles( Trog::DataSource::filter( { author => 'ann' },    @posts ) ), ['mailhost'], 'author filters on the post user' );
    is_deeply( titles( Trog::DataSource::filter( { author => 'nobody' }, @posts ) ), [],           'and an author with nothing gets nothing' );

    is_deeply( titles( Trog::DataSource::filter( { older => $posts[1]{created} }, @posts ) ), ['webserver'], 'older is older' );
    is_deeply( titles( Trog::DataSource::filter( { newer => $posts[1]{created} }, @posts ) ), ['mailhost'],  'and newer is newer' );

    # Straight off a query string, so it is coerced rather than trusted.
    is_deeply(
        titles( Trog::DataSource::filter( { older => "$posts[1]{created}abc" }, @posts ) ),
        ['webserver'],
        'a non-numeric older is coerced rather than dying'
    );

    # Combined, the way a search on a filtered page arrives.
    is_deeply( titles( Trog::DataSource::filter( { like => 'host', author => 'ann' }, @posts ) ), ['mailhost'], 'filters compose' );
    is_deeply( titles( Trog::DataSource::filter( { like => 'host', author => 'bob' }, @posts ) ), [],           'and disagree when they should' );
};

subtest 'what the default deliberately does not do' => sub {

    # Tags and acls are answers about the datastore, and they are settled before
    # a datasource is reached -- the reader got to the series page by holding
    # its acls, and every synthesized post belongs to that series.  Applying
    # them again would blank the page for a source whose posts carry no tags,
    # which nothing requires them to.
    is_deeply( titles( Trog::DataSource::filter( { acls => [] },           @posts ) ), titles(@posts), 'an empty acl list does not blank the page' );
    is_deeply( titles( Trog::DataSource::filter( { tags => ['nonesuch'] }, @posts ) ), titles(@posts), 'nor does a tag nothing carries' );

    # An id query would otherwise match the series, not its children, and leave
    # nothing at all.
    is_deeply( titles( Trog::DataSource::filter( { id => 'the-series' }, @posts ) ), titles(@posts), 'and neither does the series id' );
};

subtest 'searchable_match' => sub {
    ok( Trog::DataSource::searchable_match( 'ell', 'hello' ),       'a substring matches' );
    ok( Trog::DataSource::searchable_match( 'ELL', 'hello' ),       'case insensitively' );
    ok( Trog::DataSource::searchable_match( 'x', 'a', undef, 'x' ), 'across several values' );
    ok( !Trog::DataSource::searchable_match( 'zz', 'a', 'b' ),      'and misses when it should' );

    ok( !Trog::DataSource::searchable_match( '',    'anything' ), 'an empty search matches nothing' );
    ok( !Trog::DataSource::searchable_match( undef, 'anything' ), 'and neither does no search' );

    # Quotemeta'd, so a search for punctuation is a search for punctuation.
    ok( !Trog::DataSource::searchable_match( '.*', 'anything' ), 'a regex is text, not a pattern' );
    ok( Trog::DataSource::searchable_match( '.*',  'a .* b' ),   'and matches where that text is' );
    is( exception { Trog::DataSource::searchable_match( '(unclosed', 'x' ) }, undef, 'even when it would not compile' );

    # A body stored as an array would otherwise be matched against its address.
    ok( !Trog::DataSource::searchable_match( 'ARRAY', ['slide one'] ), 'a reference is skipped, not stringified' );
};

subtest 'for_type' => sub {
    is( Trog::DataSource::for_type(),          undef, 'no type names no source' );
    is( Trog::DataSource::for_type(''),        undef, 'and neither does an empty one' );
    is( Trog::DataSource::for_type('blog.tx'), undef, 'a type with no datasource names none' );
};

subtest 'cacheable' => sub {

    # A datasource page is cached like any other unless something says not to,
    # and nothing else ever invalidates it: saving a post does not, because no
    # post was saved.  A source that cannot say when its posts go stale would
    # therefore be cached forever wrong.
    is( Trog::DataSource::cacheable('Trog::DataSource::TestPlain'), 0, 'a source which says nothing is not cacheable' );
    is( Trog::DataSource::cacheable(undef),                         0, 'and neither is no source at all' );

    require Trog::DataSource::Virt;
    is( Trog::DataSource::cacheable('Trog::DataSource::Virt'), 0, 'Virt is not: a guest\'s state is the point of the page' );

    require Trog::DataSource::DirIndex;
    is( Trog::DataSource::cacheable('Trog::DataSource::DirIndex'), 1, 'DirIndex is, because it watches the directory' );
};

subtest 'the route marks an uncacheable page nocache' => sub {
    require Trog::Routes::HTML;
    require Test::MockModule;

    my $meta = Test::MockModule->new('Trog::DataModule');
    my $source;
    $meta->redefine( type_meta_for => sub { return $source ? { 'x-tcms-datasource' => $source } : {} } );

    my $query = sub { return { primary_post => { child_form => 'fake.tx' } } };

    # An ordinary page is left alone.
    $source = undef;
    my $ordinary = $query->();
    Trog::Routes::HTML::_datasource_posts( $ordinary, [ guest('stored') ] );
    ok( !$ordinary->{nocache}, 'an ordinary page is not marked' );

    $source = 'Trog::DataSource::TestPlain';
    my $uncacheable = $query->();
    Trog::Routes::HTML::_datasource_posts( $uncacheable, [] );
    is( $uncacheable->{nocache}, 1, 'a source which has not said is marked nocache' );

    $source = 'Trog::DataSource::TestCached';
    my $cacheable = $query->();
    Trog::Routes::HTML::_datasource_posts( $cacheable, [] );
    ok( !$cacheable->{nocache}, 'and one which has said so is not' );
};

subtest 'nocache on the query reaches the renderer' => sub {
    require Trog::Renderer;

    # TCMS::build_routes puts a route's nocache flag on the query, and exactly
    # one caller has ever forwarded it to render() as an option.  Everything
    # else was relying on being auth-gated, which says nothing about a route
    # that is nocache and public -- which is what an uncacheable datasource
    # page is.
    my @saved;
    my $tpsgi = bless {}, 'FakeTPSGI2';
    {
        no warnings qw{once};
        *FakeTPSGI2::add_post_close_callback = sub { $_[1]->();             return 1 };
        *FakeTPSGI2::save_render             = sub { push( @saved, $_[1] ); return 1 };
    }

    # The dispatch table holds a code ref taken at load time, so redefining the
    # sub it came from leaves the table pointing at the original.  Localise the
    # entry instead.
    no warnings qw{once};
    local $Trog::Renderer::renderers{html} = sub { return [ 200, [], ['a page'] ] };

    my %common = ( contenttype => 'text/html', template => 'whatever.tx', code => 200 );

    Trog::Renderer->render( %common, data => { route => '/cacheable', tpsgi => $tpsgi } );
    is_deeply( \@saved, ['/cacheable'], 'an ordinary page is saved as a static' );

    @saved = ();
    Trog::Renderer->render( %common, data => { route => '/live', tpsgi => $tpsgi, nocache => 1 } );
    is_deeply( \@saved, [], 'one whose query says nocache is not' );
};

subtest 'the defaults are advertised' => sub {
    ok( length Trog::DataSource::lang(), 'there is a language to advertise' );
    like( Trog::DataSource::help(), qr{^https?://}, 'and somewhere to read about it' );
};

subtest 'Trog::DataSource::Virt searches what its posts carry' => sub {
    require_ok('Trog::DataSource::Virt') or return;

    # A guest post's body is empty; everything about it is in named fields.
    is_deeply( titles( Trog::DataSource::Virt::filter( { like => 'web' },      @posts ) ), ['webserver'],                   'the guest name is searched' );
    is_deeply( titles( Trog::DataSource::Virt::filter( { like => 'shut' },     @posts ) ), ['database'],                    'and so is its state' );
    is_deeply( titles( Trog::DataSource::Virt::filter( { like => 'Rack One' }, @posts ) ), [ sort qw{database webserver} ], 'and the hypervisor it is on' );
    is_deeply( titles( Trog::DataSource::Virt::filter( { like => 'nonesuch' }, @posts ) ), [],                              'and nothing matches nothing' );

    # The rest of the query is still the default's job.
    is_deeply( titles( Trog::DataSource::Virt::filter( { author => 'ann' },                      @posts ) ), ['mailhost'], 'author still filters' );
    is_deeply( titles( Trog::DataSource::Virt::filter( { like   => 'running', author => 'ann' }, @posts ) ), ['mailhost'], 'alongside the search' );

    # It says so, rather than letting the page advertise the data model's.
    isnt( Trog::DataSource::Virt::lang(), Trog::DataSource::lang(), 'and it describes its own search' );
    like( Trog::DataSource::Virt::lang(), qr/guest/i, 'in terms of what is on the page' );
};

#--------------------------------------------------------------------------
# The wiring: a route has to actually reach for all this.
#--------------------------------------------------------------------------

BEGIN {
    $INC{'Trog/DataSource/TestPlain.pm'}  = 1;
    $INC{'Trog/DataSource/TestPicky.pm'}  = 1;
    $INC{'Trog/DataSource/TestBroken.pm'} = 1;
    $INC{'Trog/DataSource/TestCached.pm'} = 1;
}

{
    # A source with no filter() of its own: the default has to be applied for it.
    package Trog::DataSource::TestPlain;
    sub posts { return ( main::guest('alpha'), main::guest('beta') ) }

    # One which can say when its posts go stale, and so may be cached.
    package Trog::DataSource::TestCached;
    use constant CACHEABLE => 1;
    sub posts { return ( main::guest('cached') ) }

    # One with opinions, including its own search language.
    package Trog::DataSource::TestPicky;
    our @FILTERED;
    sub posts { return ( main::guest('alpha'), main::guest('beta') ) }

    sub filter {
        my ( $q, @p ) = @_;
        push @FILTERED, $q->{like};
        return grep { $_->{title} eq 'beta' } @p;
    }
    sub lang { 'Picky search' }
    sub help { 'https://example.com/picky' }

    # One whose filter blows up.
    package Trog::DataSource::TestBroken;
    sub posts  { return ( main::guest('alpha') ) }
    sub filter { die "no\n" }
}

subtest 'the route applies the search to synthesized posts' => sub {
    require Trog::Routes::HTML;
    require Test::MockModule;

    my $meta = Test::MockModule->new('Trog::DataModule');
    my $source;
    $meta->redefine( type_meta_for => sub { return $source ? { 'x-tcms-datasource' => $source } : {} } );

    my $query = sub { return { primary_post => { child_form => 'fake.tx' }, @_ } };

    # No datasource at all: the stored posts are handed straight back.
    $source = undef;
    my @stored = ( guest('stored') );
    is_deeply( titles( Trog::Routes::HTML::_datasource_posts( $query->(), \@stored ) ), ['stored'], 'an ordinary type is left alone' );

    $source = 'Trog::DataSource::TestPlain';
    is_deeply( titles( Trog::Routes::HTML::_datasource_posts( $query->(), \@stored ) ), [ sort qw{alpha beta} ], 'a datasource replaces them' );

    # The point of the exercise.
    is_deeply(
        titles( Trog::Routes::HTML::_datasource_posts( $query->( like => 'alph' ), \@stored ) ),
        ['alpha'],
        'and the search reaches them, rather than being dropped'
    );
    is_deeply(
        titles( Trog::Routes::HTML::_datasource_posts( $query->( like => 'nonesuch' ), \@stored ) ),
        [],
        'including when it matches nothing'
    );

    # A source with its own filter gets to use it.
    $source                                = 'Trog::DataSource::TestPicky';
    @Trog::DataSource::TestPicky::FILTERED = ();
    is_deeply(
        titles( Trog::Routes::HTML::_datasource_posts( $query->( like => 'alph' ), \@stored ) ),
        ['beta'],
        "a source's own filter wins over the default"
    );
    is_deeply( \@Trog::DataSource::TestPicky::FILTERED, ['alph'], 'and it is handed the query' );

    # A filter that dies must not take the page with it.
    $source = 'Trog::DataSource::TestBroken';
    my @survived;
    {
        my $log = Test::MockModule->new('Trog::Routes::HTML');
        $log->redefine( WARN => sub { note(shift) } );
        @survived = Trog::Routes::HTML::_datasource_posts( $query->( like => 'x' ), \@stored );
    }
    is_deeply( titles(@survived), ['alpha'], 'a filter that dies falls back to the unfiltered posts' );

    # A sidecar cannot make us load whatever it likes.
    $source = 'Evil::Module';
    my @refused;
    {
        my $log = Test::MockModule->new('Trog::DataSource');
        $log->redefine( WARN => sub { note(shift) } );
        @refused = Trog::Routes::HTML::_datasource_posts( $query->(), \@stored );
    }
    is_deeply( titles(@refused), ['stored'], 'a datasource outside the namespace is refused' );
};

subtest 'the search box says what it is searching' => sub {
    require Trog::Routes::HTML;
    require Test::MockModule;

    # Stubbed rather than built: constructing a real model here would create a
    # datastore in the repo, and none of this is about which model is configured.
    my $data = Test::MockModule->new('Trog::Data');
    $data->redefine( new => sub { return bless {}, 'FakeModel' } );

    {
        no warnings qw{once};
        *FakeModel::lang = sub { 'Model language' };
        *FakeModel::help = sub { 'https://example.com/model' };
    }

    my $meta = Test::MockModule->new('Trog::DataModule');
    my $source;
    $meta->redefine( type_meta_for => sub { return $source ? { 'x-tcms-datasource' => $source } : {} } );

    $source = undef;
    is_deeply(
        [ Trog::Routes::HTML::_search_language( { primary_post => { child_form => 'blog.tx' } } ) ],
        [ 'Model language', 'https://example.com/model' ],
        'an ordinary page advertises the data model'
    );
    is_deeply(
        [ Trog::Routes::HTML::_search_language( {} ) ],
        [ 'Model language', 'https://example.com/model' ],
        'and so does a page with no series at all'
    );

    # A datasource page is not being served out of the datastore, so the model's
    # query language is the wrong thing to advertise on it.
    $source = 'Trog::DataSource::TestPlain';
    is_deeply(
        [ Trog::Routes::HTML::_search_language( { primary_post => { child_form => 'fake.tx' } } ) ],
        [ Trog::DataSource::lang(), Trog::DataSource::help() ],
        'a datasource page advertises the datasource default'
    );

    $source = 'Trog::DataSource::TestPicky';
    is_deeply(
        [ Trog::Routes::HTML::_search_language( { primary_post => { child_form => 'fake.tx' } } ) ],
        [ 'Picky search', 'https://example.com/picky' ],
        'or its own, when it has one'
    );
};

subtest 'ordering is total, so page 2 means something' => sub {
    my @same = (
        guest( 'charlie', created => 100 ),
        guest( 'alpha',   created => 100 ),
        guest( 'bravo',   created => 100 ),
        guest( 'delta',   created => 200 ),
    );

    my @ordered = Trog::DataSource::order( {}, @same );
    is_deeply( [ map { $_->{title} } @ordered ], [qw{delta alpha bravo charlie}], 'newest first, then by title' );

    # The property that actually matters: same input, same order, every time.
    is_deeply(
        [ map { $_->{title} } Trog::DataSource::order( {}, reverse @same ) ],
        [ map { $_->{title} } @ordered ],
        'and it does not depend on what order they arrived in'
    );

    # A source that stamps everything with the time it built them -- which is
    # every libvirt guest -- falls back to being sorted by name.
    my @built = map { guest( $_, created => 1700 ) } qw{zulu alpha mike};
    is_deeply( [ map { $_->{title} } Trog::DataSource::order( {}, @built ) ], [qw{alpha mike zulu}], 'identical timestamps sort by name' );

    # Missing fields must not make it die or shuffle.
    my @sparse = ( { id => 'b' }, { id => 'a' }, guest('titled') );
    is( exception { Trog::DataSource::order( {}, @sparse ) }, undef, 'posts missing created and title are still orderable' );
};

subtest 'offset pagination' => sub {
    require Trog::Routes::HTML;

    my @ten = map { guest( sprintf( 'g%02d', $_ ), created => 100 + $_ ) } 1 .. 10;

    my ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 1 }, 4, @ten );
    is( $page,            1,     'page one is page one' );
    is( $total,           3,     'ten posts at four a page is three pages' );
    is( scalar(@slice),   4,     'and a full page' );
    is( $slice[0]{title}, 'g01', 'starting at the beginning' );

    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 2 }, 4, @ten );
    is( $slice[0]{title}, 'g05', 'page two carries on where page one stopped' );
    is( scalar(@slice),   4,     'and is also full' );

    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 3 }, 4, @ten );
    is( scalar(@slice),   2,     'the last page holds the remainder' );
    is( $slice[0]{title}, 'g09', 'from where page two stopped' );

    # Every post appears exactly once across the pages, which is the whole point.
    my @walked;
    push( @walked, ( Trog::Routes::HTML::_paginate_offset( { page => $_ }, 4, @ten ) )[ 2 .. 5 ] ) for 1 .. 3;
    @walked = grep { defined } @walked;
    is_deeply( [ sort map { $_->{title} } @walked ], [ sort map { $_->{title} } @ten ], 'walking the pages visits everything, once' );

    # Straight off a query string.
    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 99 }, 4, @ten );
    is( $page, 3, 'a page past the end shows the last one' );
    ok( scalar(@slice), 'rather than nothing at all' );

    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 0 }, 4, @ten );
    is( $page, 1, 'and page zero is page one' );
    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 'nonsense' }, 4, @ten );
    is( $page, 1, 'as is a page that is not a number' );
    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( {}, 4, @ten );
    is( $page, 1, 'and no page at all' );

    # A limit that would divide by zero.
    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 1 }, 0, @ten );
    is( $total,         1,  'a limit of zero falls back to the default rather than dividing by it' );
    is( scalar(@slice), 10, 'and shows everything' );

    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 1 }, 4 );
    is( $total,         1, 'no posts is one empty page' );
    is( scalar(@slice), 0, 'holding nothing' );

    ( $page, $total, @slice ) = Trog::Routes::HTML::_paginate_offset( { page => 1 }, 25, @ten );
    is( $total,         1,  'fewer posts than a page is one page' );
    is( scalar(@slice), 10, 'holding all of them' );
};

subtest 'the paginator renders page links for a datasource' => sub {
    require Trog::Renderer::Base;

    my $render = sub {
        my (%vars) = @_;
        return Trog::Renderer::Base::render(
            template    => 'paginator.tx',
            contenttype => 'text/html',
            component   => 1,
            data        => { limit => 25, sizes => [ 25, 50, 100 ], years => [2024], months => [ 0 .. 11 ], older => 0, newer => 0, %vars },
        );
    };

    my $offset = $render->( paginate_offset => 1, pages => 1, page => 2, pages_total => 5, like => 'web' );
    like( $offset, qr/Page 2 of 5/,             'it says where you are' );
    like( $offset, qr/href="\?page=1&limit=25/, 'Prev goes back a page' );
    like( $offset, qr/href="\?page=3&limit=25/, 'Next goes on a page' );

    # &amp; because Xslate escapes what an expression emits, which is what an
    # ampersand in an attribute is supposed to be.  The cursor branch is the same.
    like( $offset, qr/like=web/, 'and the search survives the trip' );
    unlike( $offset, qr/older=|newer=/, 'no cursor, which could not move on such a page anyway' );
    unlike( $offset, qr/Jump to/,       'and no date jump, since these posts share a date' );

    my $first = $render->( paginate_offset => 1, pages => 1, page => 1, pages_total => 3 );
    unlike( $first, qr/rel="prev"/, 'the first page offers no Prev' );
    like( $first, qr/rel="next"/, 'but does offer Next' );

    my $last = $render->( paginate_offset => 1, pages => 1, page => 3, pages_total => 3 );
    like( $last, qr/rel="prev"/, 'the last page offers Prev' );
    unlike( $last, qr/rel="next"/, 'and no Next' );

    my $only = $render->( paginate_offset => 1, pages => 0, page => 1, pages_total => 1 );
    unlike( $only, qr/rel="prev"|rel="next"/, 'a single page offers neither' );
    like( $only, qr/id="paginator" class="disabled"/, 'and says so' );

    # Stored posts are untouched by any of this.
    my $cursor = $render->( paginate_offset => 0, pages => 1, older => 1700, newer => 1800, like => 'x' );
    like( $cursor, qr/href="\?older=1700&limit=25/, 'the cursor paginator still pages by cursor' );
    like( $cursor, qr/href="\?newer=1800&limit=25/, 'both ways' );
    like( $cursor, qr/Jump to/,                     'and keeps its date jump' );
    unlike( $cursor, qr/\?page=/, 'with no page numbers' );
};

done_testing();
