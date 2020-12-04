.PHONY: install
install:
	test -d $(HOME)/.tcms || mkdir $(HOME)/.tcms
	test -d www/themes || mkdir www/themes
	test -d data/files || mkdir data/files
	rm pod2htmd.tmp; /bin/true

.PHONY: test
test: reset-dummy-data
	prove

.PHONY: reset-dummy-data
reset-dummy-data:
	cp -f data/DUMMY-dist.json data/DUMMY.json

.PHONY: depend
depend:
	sudo apt install -y sqlite3 libsqlite3-dev libdbd-sqlite3-perl cpanminus starman  libcal-dav-perl libtext-xslate-perl libserver-starter-perl libplack-perl libcal-dav-perl libconfig-tiny-perl libdatetime-format-http-perl libjson-maybexs-perl libuuid-tiny-perl libcapture-tiny-perl libconfig-simple-perl libdbi-perl libfile-slurper-perl libfile-touch-perl libfile-copy-recursive-perl libxml-rss-perl libmodule-install-perl libio-aio-perl
	sudo cpanm Mojo::File Date::Format WWW::SitemapIndex::XML WWW::Sitemap::XML HTTP::Body Pod::Html URL::Encode
	wget -O www/scripts/fgEmojiPicker.js https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/fgEmojiPicker.js
	wget -O www/scripts/full-emoji-list.json https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/full-emoji-list.json
