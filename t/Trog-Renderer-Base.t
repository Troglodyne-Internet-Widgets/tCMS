#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal      qw{exception};
use Test::MockModule qw{strict};
use Time::HiRes      ();

use FindBin::libs;

require_ok('Trog::Renderer::Base') or BAIL_OUT("Can't find SUT");

subtest 'render' => sub {
    my %options = ( template => 'manual.tx', contenttype => 'text/html', component => 1 );

    like(
        exception { Trog::Renderer::Base::render( %options, data => {} ) },
        qr/disallowed[ ]key[ ]'content'/,
        'a variable that the template reads and data lacks is fatal, and named'
    );
    my $out;
    is( exception { $out = Trog::Renderer::Base::render( %options, data => { content => undef } ) }, undef, 'but one that data has as undef is not' );
    like( $out, qr{<div[ ]id="backoffice">\s*</div>}, 'and renders as nothing' );

    my %data = ( content => 'x' );
    Trog::Renderer::Base::render( %options, data => \%data );
    $data{later} = 1;
    is( $data{later}, 1, "and the caller's data is not left locked" );
};

{

    package FakeConfig;
    sub new   ( $class, %values ) { return bless {%values}, $class }
    sub param ( $self, $key )     { return $self->{$key} }
}

subtest 'headers: the media host is in the Content-Security-Policy' => sub {
    my $mock = Test::MockModule->new('Trog::Config');
    my sub sources ($media_base) {
        $mock->redefine( get => sub { return FakeConfig->new( 'security.allow_embeds_from' => 'vimeo.test.test', 'general.media_base' => $media_base ) } );
        my %headers = Trog::Renderer::Base::headers( { contenttype => 'text/html', data => { scheme => 'https', domain => 'www.test.test', start => [ Time::HiRes::gettimeofday() ] } }, q{} );
        my ($default) = grep { index( $_, 'default-src ' ) == 0 } split( m/;/, $headers{'Content-Security-Policy'} );
        return [ split( q{ }, $default ) ];
    }

    is_deeply( sources(q{}), [ 'default-src', 'https:', q{'self'}, 'data:', q{'unsafe-eval'}, q{'unsafe-inline'}, 'vimeo.test.test' ], 'without a media host, the policy is the configured one' );
    is( sources('https://media.test.test')->[-1],                      'https://media.test.test',     'a media host is added' );
    is( sources('https://user:pass@Media.Test.Test:443/assets')->[-1], 'https://media.test.test',     'as its origin, without the user, the default port or the path' );
    is( sources('http://media.test.test:8080/assets')->[-1],           'http://media.test.test:8080', 'and with a port that is not the default' );
};

done_testing();
