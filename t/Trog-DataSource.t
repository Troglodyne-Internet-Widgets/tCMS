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
}

{
    # A source with no filter() of its own: the default has to be applied for it.
    package Trog::DataSource::TestPlain;
    sub posts { return ( main::guest('alpha'), main::guest('beta') ) }

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

done_testing();
