#!/usr/bin/starman

use strict;
use warnings;

#Grab our custom routes
use lib 'lib';
use TCMS;

our $app = \&TCMS::app;
