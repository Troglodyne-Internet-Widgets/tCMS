#!/bin/sh
sudo docker cp $1:/home/tcms/config $PWD
sudo docker cp $1:/home/tcms/data $PWD
sudo docker cp $1:/home/tcms/www/assets $PWD/www
sudo chown -R $USER:$USER $PWD/config/
sudo chown -R $USER:$USER $PWD/data/
sudo chown -R $USER:$USER $PWD/www/assets/
sudo docker kill $1
