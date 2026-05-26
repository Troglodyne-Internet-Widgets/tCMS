SHELL := /bin/bash

.PHONY: install
install:
	test -d www/themes || mkdir -p www/themes
	test -d data/files || mkdir -p data/files
	test -d www/assets/private || mkdir -p www/assets/private
	test -d www/statics || mkdir -p www/statics
	test -d totp/ || mkdir -p totp
	test -d ~/.tcms || mkdir ~/.tcms
	test -d logs || mkdir -p logs
	$(RM) pod2htmd.tmp;

.PHONY: prereq-node
prereq-node:
	npm i

.PHONY: prereq-frontend
prereq-frontend:
	mkdir -p www/scripts; pushd www/scripts && curl -L --remote-name-all                        \
		"https://raw.githubusercontent.com/chalda-pnuzig/emojis.json/master/dist/list.min.json" \
		"https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/highlight.min.js" \
		"https://cdn.jsdelivr.net/npm/chart.js" \
		"https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/reveal.js"; popd
	mkdir -p www/styles; pushd www/styles && curl -L --remote-name-all \
		"https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/styles/obsidian.min.css" \
	    "https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/reveal.css" \
		"https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/theme/white.css"; popd
	mv www/styles/white.css www/styles/reveal-white.css
	sed -i 's/Source Sans Pro,//g' www/styles/reveal-white.css

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

.PHONY: githook
githook:
	cp git-hooks/pre-commit .git/hooks
