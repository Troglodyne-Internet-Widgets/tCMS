#!/bin/bash

perl -MDevel::NYTProf call.pl GET /
nytprofhtml
