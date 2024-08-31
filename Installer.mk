SHELL := /bin/bash
SERVER_NAME := $(shell test -r TCMS_HOSTNAME && cat TCMS_HOSTNAME || bin/tcms-hostname)
USER_NAME   := $(shell test -r TCMS_USERNAME && cat TCMS_USERNAME || bin/tcms-hostname --user)
THIS_DIR    := $(shell pwd)

.PHONY: depend
ifneq (exists, $(shell test -f /etc/debian_version && echo 'exists'))
depend: prereq-centos service-user perl-deps prereq-frontend prereq-node
else
depend: prereq-debs service-user perl-deps prereq-frontend prereq-node
endif

dirs: run www/themes data/files www/assets www/statics www/scripts www/styles totp .tcms .ssh logs
run www/themes data/files www/assets www/statics www/scripts totp .tcms .ssh logs:
	mkdir -p $@

.PHONY: install
install: dirs
	$(RM) pod2htmd.tmp; /bin/true

#TODO: uninstall!

.PHONY: service-user
ifneq (exists, $(shell test -z $(id $(USER_NAME) ) && echo 'exists'))
service-user: dirs
	sudo useradd -MU -s /bin/bash -d "$(shell pwd)" $(USER_NAME); /bin/true
	sudo chown -R $(USER_NAME):$(USER_NAME) .
	# Can be 760 if you aren't using git features as a developer user that is not the system user.
	sudo chmod -R 0770 .
	# For some reason, nginx needs world readability to see the socket, despite having group permissions.
	# Seems pretty dumb to me, but whatever.  We are locking every single other file away from it & other users.
	sudo chmod 0755 .
	sudo chown $(USER_NAME):www-data run
	sudo chmod 0770 run
	sudo chmod 0775 run
	sudo chown -R $(USER_NAME):www-data run
	sudo chmod -R 0770 bin/ tcms www/server.psgi
	sudo -u $(USER_NAME) chmod 0700 .ssh
	sudo -u $(USER_NAME) touch .ssh/authorized_keys
	sudo -u $(USER_NAME) chmod 0600 .ssh/authorized_keys
endif

.PHONY: install-service
ifneq (exists, $(shell test -f /usr/lib/systemd/system/$(SERVER_NAME).service && echo 'exists'))
install-service: service-user
	sudo systemctl disable $(SERVER_NAME); /bin/true
	cp service-files/systemd.unit service-files/$(SERVER_NAME).service
	sed -i 's#__DOMAIN__#$(SERVER_NAME)#g' service-files/$(SERVER_NAME).service
	sed -i 's#__USER__#$(USER_NAME)#g' service-files/$(SERVER_NAME).service
	sed -i 's#__REPLACEME__#$(shell pwd)#g' service-files/$(SERVER_NAME).service
	sudo ln -sr service-files/$(SERVER_NAME).service /usr/lib/systemd/system/$(SERVER_NAME).service; /bin/true
	sudo systemctl daemon-reload
	sudo systemctl enable $(SERVER_NAME)
	sudo systemctl start $(SERVER_NAME)
endif

.PHONY: prereq-debian
prereq-debian: prereq-debs prereq-perl prereq-frontend prereq-node

.PHONY: prereq-debs
prereq-debs:
	sudo apt-get update
	sudo apt-get install -y perlbrew sqlite3 nodejs npm libsqlite3-dev libdbd-sqlite3-perl libxml2 curl cmake \
		uwsgi uwsgi-plugin-psgi fail2ban nginx certbot postfix dovecot-imapd dovecot-pop3d postgrey spamassassin amavis clamav\
		opendmarc opendkim opendkim-tools libunbound-dev uuid-dev\
		selinux-utils setools policycoreutils-python-utils policycoreutils selinux-basics auditd \
		pdns-tools pdns-server pdns-backend-sqlite3 libmagic-dev autotools-dev dh-autoreconf pigz libdeflate-dev

# TODO do not run if perl5/bin/cpanm exists
.PHONY: prereq-perl
ifneq (exists, $(shell test -f $(THIS_DIR)/perl5/perlbrew/bin/cpanm && echo 'exists'))
prereq-perl: service-user
	sudo -u $(USER_NAME) HOME=$(THIS_DIR) perlbrew init
	sudo -u $(USER_NAME) HOME=$(THIS_DIR) bin/perlbrew download stable
	sudo -u $(USER_NAME) HOME=$(THIS_DIR) bin/perlbrew install $(shell sudo -u $(USER_NAME) ls -1 $(THIS_DIR)/perl5/perlbrew/dists/ | tail -n1 | sed -e s/.tar.gz// )
	sudo -u $(USER_NAME) HOME=$(THIS_DIR) bin/perlbrew switch $(shell sudo -u $(USER_NAME) ls -1 $(THIS_DIR)/perl5/perlbrew/dists/ | tail -n1 | sed -e s/.tar.gz// )
	sudo -u $(USER_NAME) HOME=$(THIS_DIR) bin/perlbrew install-cpanm
endif

.PHONY: perl-deps
perl-deps: prereq-perl
	#XXX for whatever insane reason, a cpanfile or Makefile.pl DOES NOT WORK!
	sudo -u $(USER_NAME) HOME=$(THIS_DIR) bin/cpanm -n \
	CGI::Cookie Capture::Tiny Carp Config::Simple DBD::SQLite DBI Date::Format \
	DateTime::Format::HTTP Digest::SHA File::Basename File::Copy File::Slurper \
	File::Touch HTML::SocialMeta HTTP::Body IO::String Imager::QRCode JSON::MaybeXS \
	List::Util Mojo::File POSIX Pod::Html Starman Text::Xslate URL::Encode UUID \
	Text::Unidecode WWW::Sitemap::XML WWW::SitemapIndex::XML CSS::Minifier::XS \
	JavaScript::Minifier::XS Digest::SHA Path::Tiny IO::Compress::Brotli \
	IO::Compress::Gzip IO::Compress::Deflate HTTP::Parser::XS Log::Dispatch \
	Log::Dispatch::FileRotate Digest::SHA MIME::Base32::XS URI FindBin::libs \
	Carp::Always HTTP::Tiny::UNIX Email::MIME Email::Sender::Simple POSIX::strptime \
	Log::Dispatch::DBI Email::MIME Email::Sender::Simple Ref::Util Proc::Daemon \
	Future Test::Future::Deferred Test::Future::AsyncAwait::Awaitable DNS::Unbound Net::IP \
	File::LibMagic Linux::Perl::inotify Archive::Tar::Builder PerlIO::gzip Trog::TOTP Starman

.PHONY: prereq-node
prereq-node: service-user
	sudo -u $(USER_NAME) curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | sudo -u $(USER_NAME) bash
	sudo -u $(USER_NAME) bin/nvm install node
	sudo -u $(USER_NAME) bin/nvm exec node npm i

.PHONY: prereq-frontend
prereq-frontend: dirs
	pushd www/scripts && curl -L --remote-name-all                        \
		"https://raw.githubusercontent.com/chalda-pnuzig/emojis.json/master/dist/list.min.json" \
		"https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/highlight.min.js" \
		"https://cdn.jsdelivr.net/npm/chart.js" \
		"https://raw.githubusercontent.com/hakimel/reveal.js/master/dist/reveal.js"; popd
	pushd www/styles && curl -L --remote-name-all \
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

.PHONY: fail2ban
fail2ban:
	cp fail2ban/tcms-jail.tmpl fail2ban/tcms-jail.conf
	sed -i 's#__LOGDIR__#$(shell pwd)#g' fail2ban/tcms-jail.conf
	sed -i 's#__DOMAIN__#$(SERVER_NAME)#g' fail2ban/tcms-jail.conf
	sudo rm /etc/fail2ban/jail.d/$(SERVER_NAME).conf; /bin/true
	sudo rm /etc/fail2ban/filter.d/$(SERVER_NAME).conf; /bin/true
	sudo ln -sr fail2ban/tcms-jail.conf   /etc/fail2ban/jail.d/$(SERVER_NAME).conf
	sudo ln -sr fail2ban/tcms-filter.conf /etc/fail2ban/filter.d/$(SERVER_NAME).conf
	sudo systemctl reload fail2ban

.PHONY: nginx
nginx: dirs
	sudo sed -i 's/#\? server_names_hash_bucket_size .*/server_names_hash_bucket_size 64;/' /etc/nginx/nginx.conf
	sed 's/\%SERVER_NAME\%/$(SERVER_NAME)/g' nginx/tcms.conf.tmpl > nginx/tcms.conf.intermediate
	sed 's/\%SERVER_SOCK\%/$(shell pwd | sed sed 's/\//\\\//g')/g' nginx/tcms.conf.intermediate > nginx/tcms.conf
	rm nginx/tcms.conf.intermediate
	chown $(USER_NAME):www-data run
	chmod 0770 run
	sudo mkdir -p '/var/www/$(SERVER_NAME)'
	sudo mkdir -p '/var/www/mail.$(SERVER_NAME)'
	sudo mkdir -p '/etc/letsencrypt/live/$(SERVER_NAME)'
	[ -e "/etc/nginx/sites-enabled/$$SERVER_NAME.conf" ] && sudo rm "/etc/nginx/sites-enabled/$$SERVER_NAME.conf"; /bin/true
	sudo ln -sr nginx/tcms.conf '/etc/nginx/sites-enabled/$(SERVER_NAME).conf'
	# Make a self-signed cert FIRST, because certbot has a chicken/egg problem
	sudo openssl req -x509 -config etc/openssl.conf -nodes -newkey rsa:4096 -subj '/CN=$(SERVER_NAME)' -addext 'subjectAltName=DNS:www.$(SERVER_NAME),DNS:mail.$(SERVER_NAME)' -keyout '/etc/letsencrypt/live/$(SERVER_NAME)/privkey.pem' -out '/etc/letsencrypt/live/$(SERVER_NAME)/fullchain.pem' -days 365
	sudo systemctl reload nginx
	# Now run certbot and get that http dcv. We have to do a "gamer move" so that certbot doesn't complain about live dir existing.
	sudo rm -rf '/etc/letsencrypt/live/$(SERVER_NAME)'
	sudo certbot certonly --webroot -w '/var/www/$(SERVER_NAME)/' -d '$(SERVER_NAME)' -d 'www.$(SERVER_NAME)' -w '/var/www/mail.$(SERVER_NAME)' -d 'mail.$(SERVER_NAME)'
	sudo systemctl reload nginx

.PHONY: mail
mail: dirs dkim dmarc
	# Dovecot
	sudo cp /etc/dovecot/conf.d/10-ssl.conf /etc/dovecot/conf.d/10-ssl.conf.orig
	sudo sed -i 's/^\(ssl_cert\s*=\).*/\1<\/etc\/letsencrypt\/live\/$(SERVER_NAME)\/fullchain.pem/g' /etc/dovecot/conf.d/10-ssl.conf
	sudo sed -i 's/^\(ssl_key\s*=\).*/\1\<\/etc\/letsencrypt\/live\/$(SERVER_NAME)\/privkey.pem/g' /etc/dovecot/conf.d/10-ssl.conf
	# Postfix
	sudo cp /etc/postfix/main.cf /etc/postfix/main.cf.orig
	sudo sed -i 's/^\(smtpd_tls_cert_file\s*=\).*/\1\/etc\/letsencrypt\/live\/$(SERVER_NAME)\/fullchain.pem/g' /etc/postfix/main.cf
	sudo sed -i 's/^\(smtpd_tls_key_file\s*=\).*/\1\/etc\/letsencrypt\/live\/$(SERVER_NAME)\/privkey.pem/g' /etc/postfix/main.cf
	# XXX we should not do these two.
	sudo sed -i 's/^\(myhostname\s*=\).*/\1$(SERVER_NAME)/g' /etc/postfix/main.cf
	sudo echo '$(SERVER_NAME)' > /etc/mailname
	# Configure postfix to put on its socks and shoes.  This all implicitly relies on good defaults in the opendkim/opendmarc packages.
	sudo postconf -e milter_default_action=accept
	sudo postconf -e milter_protocol=2
	sudo postconf -e smtpd_milters=local:opendkim/opendkim.sock,local:opendmarc/opendmarc.sock
	sudo postconf -e non_smtpd_milters=\$smtpd_milters
	sudo systemctl reload postfix
	# TODO setup various mail aliases and so forth, e.g. postmaster@, soa@, the various lists etc

.PHONY: dkim
dkim: dirs
	sudo mkdir -p /etc/opendkim/keys/$(SERVER_NAME)
	sudo opendkim-genkey --directory /etc/opendkim/keys/$(SERVER_NAME) -s mail -d $(SERVER_NAME)
	sudo openssl rsa -in /etc/opendkim/keys/$(SERVER_NAME)/mail.private -pubout > /tmp/mail.public
	sudo mv /tmp/mail.public /etc/opendkim/keys/$(SERVER_NAME)/mail.public
	sudo chown -R opendkim:opendkim /etc/opendkim
	sudo mail/mongle_dkim_config $(SERVER_NAME)
	sudo systemctl enable opendkim
	sudo systemctl start opendkim

.PHONY: dmarc
dmarc: dirs
	sudo mail/mongle_dmarc_config $(SERVER_NAME) mail.$(SERVER_NAME)
	sudo systemctl enable opendmarc
	sudo systemctl start opendmarc

.PHONY: disable-stub-resolver
disable-stub-resolver:
ifneq (exists, $(shell test -f /etc/systemd/resolved.conf.d/10-disable-stub-resolver.conf && echo 'exists'))
	sudo mkdir /etc/systemd/resolved.conf.d/; /bin/true
	sudo cp dns/10-disable-stub-resolver.conf /etc/systemd/resolved.conf.d/
	sudo chown -R systemd-resolve:systemd-resolve /etc/systemd/resolved.conf.d/
	sudo chmod 0660 /etc/systemd/resolved.conf.d/10-disable-stub-resolver.conf
	sudo systemctl restart systemd-resolved
endif

.PHONY: dns
dns: dirs disable-stub-resolver
	cp dns/tcms.tmpl dns/tcms.conf
	sed -i 's#__DIR__#$(shell pwd)#g' dns/tcms.conf
	sed -i 's#__DOMAIN__#$(SERVER_NAME)#g' dns/tcms.conf
	[[ -e /etc/powerdns/pdns.d/$(SERVER_NAME).conf ]] && sudo rm /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	sudo cp dns/tcms.conf /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	sudo chmod 0755 /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	# Build the zone database and initialize the zone for our domain
	rm dns/zones.db; /bin/true
	sqlite3 dns/zones.db < /usr/share/pdns-backend-sqlite3/schema/schema.sqlite3.sql
	bin/build_zone > dns/default.zone
	zone2sql --gsqlite --zone=dns/default.zone --zone-name=$(SERVER_NAME) > dns/default.zone.sql
	sqlite3 dns/zones.db < dns/default.zone.sql
	# Bind mount our dns/ folder so that pdns can see it in chroot
	sudo mkdir /var/spool/powerdns/$(SERVER_NAME); /bin/true
	sudo chown pdns:pdns /var/spool/powerdns/$(SERVER_NAME); /bin/true
	sudo cp /etc/fstab /tmp/fstab.new
	sudo chown $(USER) /tmp/fstab.new
	echo "$(shell pwd)/dns /var/spool/powerdns/$(SERVER_NAME) none defaults,bind 0 0" >> /tmp/fstab.new
	sort < /tmp/fstab.new | uniq | grep -o '^[^#]*' > /tmp/fstab.newer
	sudo chown root:root /tmp/fstab.newer
	sudo mv /etc/fstab /etc/fstab.bak
	sudo mv /tmp/fstab.newer /etc/fstab
	sudo mount /var/spool/powerdns/$(SERVER_NAME)
	# Don't need no bind
	[[ -e /etc/powerdns/pdns.d/bind.conf ]] && sudo rm /etc/powerdns/pdns.d/bind.conf; /bin/true
	# Fix broken service configuration
	sudo dns/configure_pdns
	sudo chown $(USER_NAME):pdns dns/
	sudo chown $(USER_NAME):pdns dns/zones.db
	sudo mkdir -p /var/spool/powerdns/run/pdns/; /bin/true
	sudo chown -R pdns:pdns /var/spool/powerdns/run
	sudo cp dns/10-powerdns.conf /etc/rsyslog.d/10-powerdns.conf
	sudo systemctl daemon-reload
	sudo systemctl restart rsyslog
	sudo systemctl enable pdns
	sudo systemctl start pdns

.PHONY: githook
githook:
	cp git-hooks/pre-commit .git/hooks

.PHONY: firewall
firewall:
	# Remove dopey unauthenticated port for git from /etc/services
	sudo sed -i '/^git\s/d' /etc/services
	sudo cp ufw/git ufw/pdns_server /etc/ufw/applications.d
	sudo ufw/setup-rules

.PHONY: all
all: depend install install-service nginx mail dns firewall fail2ban githook
