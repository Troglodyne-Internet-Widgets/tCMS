.PHONY: test
test:
	prove t/*.t

.PHONY: depend
depend:
	sudo apt install cpanminus starman  libcal-dav-perl libtext-xslate-perl libserver-starter-perl liburl-encode-perl libplack-perl libcal-dav-perl libconfig-tiny-perl libdatetime-format-http-perl libjson-maybexs-perl libuuid-tiny-perl libcapture-tiny-perl libconfig-simple-perl
	sudo cpanm Mojo::File Date::Format
