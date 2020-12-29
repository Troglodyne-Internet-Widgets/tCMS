#!/bin/sh
sudo docker build -t troglodyne/tcms .
sudo docker run -dp 5000:5000 troglodyne/tcms:latest /usr/bin/starman -p 5000 www/server.psgi
