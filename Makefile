# I Would highly suggest removing this. And either including it in the repo,
# Or, having the app bootstrap it.
.PHONY: install
install:
	test -d $(HOME)/.tcms || mkdir $(HOME)/.tcms
	test -d www/themes || mkdir www/themes
	test -d data/files || mkdir data/files
	$(RM) pod2htmd.tmp;

.PHONY: install-service
install-service:
	mkdir -p ~/.config/systemd/user
	cp service-files/systemd.unit ~/.config/systemd/user/tCMS.service
	sed -ie 's#__REPLACEME__#$(shell pwd)#g' ~/.config/systemd/user/tCMS.service
	systemctl --user daemon-reload
	systemctl --user enable tCMS
	systemctl --user start tCMS
	loginctl enable-linger $(USER)

.PHONY: reset-dummy-data
reset-dummy-data:
	cp -f data/DUMMY-dist.json data/DUMMY.json

.PHONY: prereq-debian
prereq-debian: prereq-debs prereq-perl prereq-frontend

.PHONY: prereq-debs
prereq-debs:
	apt-get install -y sqlite3 libsqlite3-dev libdbd-sqlite3-perl cpanminus starman libxml2 wget                         \
	    libtext-xslate-perl libplack-perl libconfig-tiny-perl libdatetime-format-http-perl libjson-maybexs-perl          \
	    libuuid-tiny-perl libcapture-tiny-perl libconfig-simple-perl libdbi-perl libfile-slurper-perl libfile-touch-perl \
	    libfile-copy-recursive-perl libxml-rss-perl libmodule-install-perl                                               \
	    libmoose-perl libmoosex-types-datetime-perl libxml-libxml-perl

.PHONY: prereq-perl
prereq-perl:
	cpanm -n --installdeps .

.PHONY: prereq-frontend
prereq-frontend:
	mkdir -p www/scripts; cd www/scripts && curl --remote-name-all                                  \
		"https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/fgEmojiPicker.js"     \
	  "https://github.com/woody180/vanilla-javascript-emoji-picker/raw/master/full-emoji-list.json"
