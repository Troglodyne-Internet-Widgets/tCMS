#!/bin/sh
docker build -t troglodyne/tcms .
docker run --restart unless-stopped -dp 5000:5000 troglodyne/tcms:latest
