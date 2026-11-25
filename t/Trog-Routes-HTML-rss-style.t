#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;

use FindBin::libs;

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

subtest 'rss_style' => sub {
    my $res  = Trog::Routes::HTML::rss_style( { route => '/styles/rss-style.xsl', title => '<b>x</b>' } );
    my $body = join( '', @{ $res->[2] } );

    is( $res->[0], 200, 'renders' );
    like( $body, qr{<title><xsl:value-of[ ]select="rss/channel/title"/></title>}, 'with the title of the channel as its title' );
    unlike( $body, qr{<b>x</b>}, 'and not a title from the query' );
};

done_testing();
