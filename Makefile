SHELL := /bin/bash

.PHONY: depend
depend:
	[ -f "/etc/debian_version" ] && make prereq-debs; /bin/true;
	make prereq-perl prereq-frontend

.PHONY: install
install:
	test -d www/themes || mkdir -p www/themes
	test -d data/files || mkdir -p data/files
	test -d www/assets || mkdir -p www/assets
	$(RM) pod2htmd.tmp;

.PHONY: install-service
install-service:
	mkdir -p ~/.config/systemd/user
	cp service-files/systemd.unit ~/.config/systemd/user/tCMS.service
	sed -ie 's#__REPLACEME__#$(shell pwd)#g' ~/.config/systemd/user/tCMS.service
	sed -ie 's#__PORT__#$(PORT)#g' ~/.config/systemd/user/tCMS.service
	systemctl --user daemon-reload
	systemctl --user enable tCMS
	systemctl --user start tCMS
	loginctl enable-linger $(USER)

.PHONY: prereq-debian
prereq-debian: prereq-debs prereq-perl prereq-frontend

.PHONY: prereq-debs
prereq-debs:
	sudo apt-get update
	sudo apt-get install -y sqlite3 libsqlite3-dev libdbd-sqlite3-perl cpanminus starman libxml2 curl                    \
	    libtext-xslate-perl libplack-perl libconfig-tiny-perl libdatetime-format-http-perl libjson-maybexs-perl          \
	    libuuid-tiny-perl libcapture-tiny-perl libconfig-simple-perl libdbi-perl libfile-slurper-perl libfile-touch-perl \
	    libfile-copy-recursive-perl libxml-rss-perl libmodule-install-perl libio-string-perl                             \
	    libmoose-perl libmoosex-types-datetime-perl libxml-libxml-perl liblist-moreutils-perl libclone-perl

.PHONY: prereq-perl
prereq-perl:
	sudo cpanm -n --installdeps .

.PHONY: prereq-frontend
prereq-frontend:
	mkdir -p www/scripts; pushd www/scripts && curl -L --remote-name-all                              \
		"https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/fgEmojiPicker.js"     \
		"https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/full-emoji-list.json" \
		"https://unpkg.com/signin-with-matrix@latest/dist/index.umd.js"                               \
		"https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/highlight.min.js"; mv index.umd.js matrix-login.js; popd
	mkdir -p www/styles; cd www/styles && curl -L --remote-name-all \
		"https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/styles/obsidian.min.css"

.PHONY: reset
reset: reset-remove install

.PHONY: reset-remove
reset-remove:
	rm -rf data; /bin/true
	rm -rf www/themes; /bin/true
	rm -rf www/assets; /bin/true
	rm config/auth.db; /bin/true
	rm config/main.cfg; /bin/true
	rm config/has_users; /bin/true
	rm config/setup; /bin/true
