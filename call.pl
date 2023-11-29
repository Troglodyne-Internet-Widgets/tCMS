#!/usr/bin/perl
# Really only useful for profiling read routes, which is all I want it for.

use strict;
use warnings;

#Grab our custom routes
use lib 'lib';
use TCMS;

my %env = (
    REQUEST_METHOD => $ARGV[0],
    PATH_INFO      => $ARGV[1],
    QUERY_STRING   => $ARGV[2],
);

my $limit = $ARGV[3] || 1;
our $app = \&TCMS::app;
for ( 0 .. $limit ) {
    my $out = $app->( \%env );
    print $out->[2][0];
}

