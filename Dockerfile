FROM ubuntu:latest
ARG port=5000

LABEL description="tCMS: a Perl CMS by Troglodyne LLC"

EXPOSE $port/tcp

USER root
RUN useradd tcms
RUN apt-get update
RUN apt-get install -y make apt-utils mlocate

ADD --chown=tcms . /home/tcms

WORKDIR /home/tcms

RUN apt-get install -y locales
RUN localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
ENV LANG en_US.utf8

ENV DEBIAN_FRONTEND=noninteractive
RUN ln -fs /usr/share/zoneinfo/UTC /etc/localtime
RUN apt-get install -y tzdata
RUN dpkg-reconfigure --frontend noninteractive tzdata

RUN make depend
RUN updatedb

USER tcms
RUN make install
RUN make reset-dummy-data
CMD /usr/bin/starman -p $port www/server.psgi
