SHELL := /bin/bash
SERVER_NAME := $(shell bin/tcms-hostname)

.PHONY: depend
depend:
	[ -f "/etc/debian_version" ] && make -f Installer.mk prereq-debs; /bin/true;
	make -f Installer.mk prereq-perl prereq-frontend

.PHONY: install
install:
	test -d www/themes || mkdir -p www/themes
	test -d data/files || mkdir -p data/files
	test -d www/assets || mkdir -p www/assets
	test -d www/statics || mkdir -p www/statics
	test -d totp/ || mkdir -p totp
	test -d ~/.tcms || mkdir ~/.tcms
	test -d logs/ && mkdir -p logs/; /bin/true
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

.PHONY: prereq-debian
prereq-debian: prereq-debs prereq-perl prereq-frontend prereq-node

.PHONY: prereq-debs
prereq-debs:
	sudo apt-get update
	sudo apt-get install -y sqlite3 nodejs npm libsqlite3-dev libdbd-sqlite3-perl cpanminus starman libxml2 curl cmake \
		uwsgi uwsgi-plugin-psgi fail2ban nginx certbot postfix dovecot-imapd dovecot-pop3d postgrey spamassassin amavis clamav\
		opendmarc opendkim opendkim-tools libunbound-dev \
	    libtext-xslate-perl libplack-perl libconfig-tiny-perl libdatetime-format-http-perl libjson-maybexs-perl          \
	    libuuid-tiny-perl libcapture-tiny-perl libconfig-simple-perl libdbi-perl libfile-slurper-perl libfile-touch-perl \
	    libfile-copy-recursive-perl libxml-rss-perl libmodule-install-perl libio-string-perl uuid-dev                    \
	    libmoose-perl libmoosex-types-datetime-perl libxml-libxml-perl liblist-moreutils-perl libclone-perl libpath-tiny-perl \
		selinux-utils setools policycoreutils-python-utils policycoreutils selinux-basics auditd \
		pdns-tools pdns-server pdns-backend-sqlite3 libmagic-dev

.PHONY: prereq-perl
prereq-perl:
	sudo cpanm -n --installdeps .

.PHONY: prereq-node
prereq-node:
	npm i

.PHONY: prereq-frontend
prereq-frontend:
	mkdir -p www/scripts; pushd www/scripts && curl -L --remote-name-all                        \
		"https://raw.githubusercontent.com/chalda-pnuzig/emojis.json/master/dist/list.min.json" \
		"https://raw.githubusercontent.com/highlightjs/cdn-release/main/build/highlight.min.js" \
		"https://cdn.jsdelivr.net/npm/chart.js"; popd
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

.PHONY: fail2ban
fail2ban:
	cp fail2ban/tcms-jail.tmpl fail2ban/tcms-jail.conf
	sed -i 's#__LOGDIR__#$(shell pwd)#g' fail2ban/tcms-jail.conf
	sed -i 's#__DOMAIN__#$(shell bin/tcms-hostname)#g' fail2ban/tcms-jail.conf
	sudo rm /etc/fail2ban/jail.d/$(shell bin/tcms-hostname).conf; /bin/true
	sudo rm /etc/fail2ban/filter.d/$(shell bin/tcms-hostname).conf; /bin/true
	sudo ln -sr fail2ban/tcms-jail.conf   /etc/fail2ban/jail.d/$(shell bin/tcms-hostname).conf
	sudo ln -sr fail2ban/tcms-filter.conf /etc/fail2ban/filter.d/$(shell bin/tcms-hostname).conf
	sudo systemctl reload fail2ban

.PHONY: nginx
nginx:
	[ -n "$$SERVER_NAME" ] || ( echo "Please set the SERVER_NAME environment variable before running (e.g. test.test)" && /bin/false )
	sed 's/\%SERVER_NAME\%/$(SERVER_NAME)/g' nginx/tcms.conf.tmpl > nginx/tcms.conf.intermediate
	sed 's/\%SERVER_SOCK\%/$(shell pwd)/g' nginx/tcms.conf.intermediate > nginx/tcms.conf
	rm nginx/tcms.conf.intermediate
	mkdir run
	chown $(USER):www-data run
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
mail: dkim dmarc
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
	sudo service postfix reload
	# TODO setup various mail aliases and so forth, e.g. postmaster@, soa@, the various lists etc

.PHONY: dkim
dkim:
	sudo mkdir -p /etc/opendkim/keys/$(SERVER_NAME)
	sudo opendkim-genkey --directory /etc/opendkim/keys/$(SERVER_NAME) -s mail -d $(SERVER_NAME)
	sudo openssl rsa -in /etc/opendkim/keys/$(SERVER_NAME)/mail.private -pubout > /tmp/mail.public
	sudo mv /tmp/mail.public /etc/opendkim/keys/$(SERVER_NAME)/mail.public
	sudo chown -R opendkim:opendkim /etc/opendkim
	sudo mail/mongle_dkim_config $(SERVER_NAME)
	sudo service opendkim enable
	sudo service opendkim start

.PHONY: dmarc
dmarc:
	sudo mail/mongle_dmarc_config $(SERVER_NAME) mail.$(SERVER_NAME)
	sudo service opendmarc enable
	sudo service opendmarc start

.PHONY: dns
dns:
	cp dns/tcms.tmpl dns/tcms.conf
	sed -i 's#__DIR__#$(shell pwd)#g' dns/tcms.conf
	sed -i 's#__DOMAIN__#$(SERVER_NAME)#g' dns/tcms.conf
	[[ -e /etc/powerdns/pdns.d/$(SERVER_NAME).conf ]] && sudo rm /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	sudo cp dns/tcms.conf /etc/powerdns/pdns.d/$(SERVER_NAME).conf
	sudo mkdir /etc/systemd/resolved.conf.d/; /bin/true
	sudo cp dns/10-disable-stub-resolver.conf /etc/systemd/resolved.conf.d/
	sudo chown -R systemd-resolve:systemd-resolve /etc/systemd/resolved.conf.d/
	sudo chmod 0660 /etc/systemd/resolved.conf.d/10-disable-stub-resolver.conf
	sudo systemctl restart systemd-resolved
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
	sort < /tmp/fstab.new | uniq | grep -o '^[^#]*' > /tmp/fstab.new
	sudo chown root:root /tmp/fstab.new
	sudo mv /etc/fstab /etc/fstab.bak
	sudo mv /tmp/fstab.new /etc/fstab
	sudo mount /var/spool/powerdns/$(SERVER_NAME)
	# Don't need no bind
	[[ -e /etc/powerdns/pdns.d/bind.conf ]] && sudo rm /etc/powerdns/pdns.d/bind.conf
	# Fix broken service configuration
	sudo bin/configure_pdns
	sudo cp dns/10-powerdns.conf /etc/rsyslog.d/10-powerdns.conf 
	sudo systemctl daemon-reload
	sudo service rsyslog restart
	sudo service pdns enable
	sudo service pdns start

.PHONY: all
all: prereq-debian install fail2ban nginx mail
