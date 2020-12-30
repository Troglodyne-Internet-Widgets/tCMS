.PHONY: install
install:
	test -d $(HOME)/.tcms || mkdir $(HOME)/.tcms
	test -d www/themes || mkdir www/themes
	test -d data/files || mkdir data/files
	rm pod2htmd.tmp; /bin/true

.PHONY: install-service
install-service:
	mkdir -p ~/.config/systemd/user
	cp service-files/systemd.unit ~/.config/systemd/user/tCMS.service
	sed -ie 's#__REPLACEME__#$(shell pwd)#g' ~/.config/systemd/user/tCMS.service
	systemctl --user daemon-reload
	systemctl --user enable tCMS
	systemctl --user start tCMS
	loginctl enable-linger $(USER)

.PHONY: test
test: reset-dummy-data
	prove

.PHONY: reset-dummy-data
reset-dummy-data:
	cp -f data/DUMMY-dist.json data/DUMMY.json

.PHONY: depend
depend:
	apt-get install -y sqlite3 libsqlite3-dev libdbd-sqlite3-perl cpanminus starman libxml2 wget
	apt-get install -y libtext-xslate-perl libplack-perl libconfig-tiny-perl libdatetime-format-http-perl libjson-maybexs-perl
	apt-get install -y libuuid-tiny-perl libcapture-tiny-perl libconfig-simple-perl libdbi-perl libfile-slurper-perl libfile-touch-perl
	apt-get install -y libfile-copy-recursive-perl libxml-rss-perl libmodule-install-perl
	apt-get install -y libmoose-perl libmoosex-types-datetime-perl libxml-libxml-perl
	cpanm Mojo::File Date::Format WWW::SitemapIndex::XML WWW::Sitemap::XML HTTP::Body Pod::Html URL::Encode
	wget -O www/scripts/fgEmojiPicker.js https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/fgEmojiPicker.js
	wget -O www/scripts/full-emoji-list.json https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/full-emoji-list.json
