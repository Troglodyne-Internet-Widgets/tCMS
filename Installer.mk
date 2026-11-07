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

# The scripts and styles that the pages load, which git does not track.  make
# fetches only the ones that are missing, so a checkout keeps the files that it
# serves.  make -B prereq-frontend fetches all of them again.
FRONTEND := www/scripts/list.min.json www/scripts/highlight.min.js www/scripts/chart.min.js www/scripts/reveal.min.js \
	www/styles/obsidian.min.css www/styles/reveal.css www/styles/reveal-white.css

.PHONY: prereq-frontend
prereq-frontend: $(FRONTEND)

# To a temporary name first, so that a download that fails leaves no file that
# make takes as fetched.
define fetch
	mkdir -p $(@D)
	curl -fsSL --retry 3 -o $@.part "$(1)"
	mv $@.part $@
endef

www/scripts/list.min.json:
	$(call fetch,https://raw.githubusercontent.com/chalda-pnuzig/emojis.json/master/dist/list.min.json)

www/scripts/highlight.min.js:
	$(call fetch,https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/highlight.min.js)

www/scripts/chart.min.js:
	$(call fetch,https://cdn.jsdelivr.net/npm/chart.js)

www/scripts/reveal.min.js:
	$(call fetch,https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/reveal.js)

www/styles/obsidian.min.css:
	$(call fetch,https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/styles/obsidian.min.css)

www/styles/reveal.css:
	$(call fetch,https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/reveal.css)

# Without the font that the theme names first, which tCMS does not serve.
www/styles/reveal-white.css:
	mkdir -p $(@D)
	curl -fsSL --retry 3 -o $@.part "https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/theme/white.css"
	sed -i 's/Source Sans Pro,//g' $@.part
	mv $@.part $@

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
