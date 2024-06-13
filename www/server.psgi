#!/usr/bin/starman

use strict;
use warnings;

#Grab our custom routes
use FindBin::libs;
use TCMS;
use Trog::Autoreload;

our $MASTER_PID = $$;

$ENV{PSGI_ENGINE} //= 'starman';

our $app = \&TCMS::app;

# TODO Fork off the supervisor process Trog::Autoreload
