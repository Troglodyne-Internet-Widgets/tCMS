#!/bin/sh
docker build -t troglodyne/tcms .
docker run -dp 5000:5000 troglodyne/tcms:latest "//usr/bin/starman" "www/server.psgi"
