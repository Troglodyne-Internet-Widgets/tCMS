#!/usr/bin/starman

use strict;
use warnings;

#Grab our custom routes
use lib 'lib';
use TCMS;

$ENV{PSGI_ENGINE} //= 'starman';

our $app = \&TCMS::app;
