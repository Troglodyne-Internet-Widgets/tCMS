#!/usr/bin/perl

use strict;
use warnings;

use lib 'lib';
use Trog::Data;
use Trog::Config;
use Trog::SQLite::TagIndex;

# Use this to build the post index after you import data, otherwise it's not needed

my $conf = Trog::Config::get();
my $search = Trog::Data->new($conf);

Trog::SQLite::TagIndex::build_index($search);
Trog::SQLite::TagIndex::build_routes($search);
