.PHONY: install
install:
	export WD=`realpath "$$PWD/../.."`
	[ -n "$$WD" ] || ( echo "cannot determine path to TCMS directory" && /bin/false )
	[ -n "$$PERSON" ] || ( echo "Please set the PERSON environment variable before running (user to run tcms as)" && /bin/false )
	sed -e s/__USER__/$$PERSON/g config.json.tmpl > config.json.tmp1
	sed -e 's|__WD__|'$$WD'|g' config.json.tmp1 > config.json
	rm config.json.tmp1
	/bin/false
	sudo curl -X PUT --data-binary @config.json --unix-socket /var/run/control.unit.sock http://localhost/config

.PHONY: restart
restart:
	sudo curl -X GET --data-binary @config.json --unix-socket /var/run/control.unit.sock http://localhost/control/applications/tcms/restart
