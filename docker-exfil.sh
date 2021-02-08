#!/bin/sh
docker cp $1:/home/tcms/config $PWD
docker cp $1:/home/tcms/data $PWD
docker cp $1:/home/tcms/www/assets $PWD/www
if [ $user ]
then
    chown -R $USER:$USER $PWD/config/
    chown -R $USER:$USER $PWD/data/
    chown -R $USER:$USER $PWD/www/assets/
fi
docker kill $1
