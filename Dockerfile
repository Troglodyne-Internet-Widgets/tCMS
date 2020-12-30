FROM troglodyne/base:latest AS tcms

ARG port=5000
LABEL description="tCMS: a Perl CMS by Troglodyne LLC"

EXPOSE $port/tcp

ADD . /home/tcms
RUN chown -R tcms /home/tcms

USER tcms

RUN make install
RUN make reset-dummy-data
CMD /usr/bin/starman -p $port www/server.psgi
