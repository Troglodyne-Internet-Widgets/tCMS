#!/usr/bin/env perl

# A post type names its enrich sub in a sidecar.  The module part of that name
# is loaded, so it has to be a module name and nothing else: a name that starts
# with :: becomes a path that starts with a slash.

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::MockModule qw{strict};

use FindBin::libs;

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

# A module that is already loaded, so that the one that does not exist is the
# only thing that makes a load fail.
$INC{'Trog/Test/Enrich.pm'} = 1;
{

    package Trog::Test::Enrich;
    sub extra ( $, $ ) { return ( enriched => 1 ) }
}

my @warnings;
my $routes = Test::MockModule->new('Trog::Routes::HTML');
$routes->redefine( WARN => sub { push( @warnings, shift ) } );

my $enrich;
my $meta = Test::MockModule->new('Trog::DataModule');
$meta->redefine( type_meta_for => sub { return { 'x-tcms-post-type' => { enrich => $enrich } } } );
$meta->redefine( relations_for => sub { return {} } );

sub enriched ($sub) {
    $enrich   = $sub;
    @warnings = ();
    my $post = { form => 'fake.tx' };
    Trog::Routes::HTML::enrich_post( $post, {} );
    return $post;
}

subtest 'a sub in a module that is a module name runs' => sub {
    my $post = enriched('Trog::Test::Enrich::extra');
    is( $post->{enriched}, 1, 'and its output is put on the post' );
    is_deeply( \@warnings, [], 'without a warning' );
};

subtest 'a sub in something that is not a module name is refused' => sub {
    foreach my $bad ( '::Trog::Test::Enrich::extra', 'Trog::::Enrich::extra', 'Trog::Test::Enrich::::extra', '::Foo::bar', 'Trog:Test::extra' ) {    ## no critic (RequireQwForLiteralLists) -- names that are not words
        my $post = enriched($bad);
        ok( !exists $post->{enriched}, "'$bad' does not run" );
        is( scalar @warnings, 1, '...and is warned about once' );
        like( $warnings[0], qr/malformed[ ]enrich[ ]sub/, '...as a malformed name' );
    }
};

subtest 'a module that does not load is warned about' => sub {
    my $post = enriched('Trog::Test::Missing::extra');
    ok( !exists $post->{enriched}, 'its sub does not run' );
    like( $warnings[0], qr/will[ ]not[ ]load/, 'and the load failure is said' );
};

done_testing();
