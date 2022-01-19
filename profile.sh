#!/bin/bash

perl -MDevel::NYTProf call.pl GET / ?w=1 1000
nytprofhtml
