#!/usr/bin/env perl
use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Test::More;
use Test::Fatal qw{exception};

use FindBin::libs;

require_ok('Trog::DataModule') or BAIL_OUT("Can't find SUT");

subtest 'filter, with a search' => sub {
    my %stored = ( version => 0, created => 1, tags => ['public'] );
    my @posts  = (
        { %stored, id => 'titled',   title => 'A Spec Title', data => 'body' },
        { %stored, id => 'untitled', data  => 'a spec body' },
        { %stored, id => 'slides',   title => 'Deck',  data => [ 'first slide', 'a spec slide' ] },
        { %stored, id => 'other',    title => 'Other', data => 'nothing here' },
    );
    my $search = sub ($like) {
        my @found;
        my $err = exception { @found = Trog::DataModule::filter( undef, { like => $like, acls => ['admin'] }, @posts ) };
        return ( $err, [ map { $_->{id} } @found ] );
    };

    my ( $err, $found ) = $search->('spec');
    is( $err, undef, 'a post with no title does not stop the search' );
    is_deeply( $found, [qw{titled untitled slides}], 'which finds a title, a body, and a slide of a body that is a list' );

    ( $err, $found ) = $search->('ARRAY');
    is_deeply( $found, [], 'and never the address of that list' );
};

done_testing();
