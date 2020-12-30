#!/bin/sh
docker build -t troglodyne/base . -f Dockerfile.build
./dockerdeploy.sh
