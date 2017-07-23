test:
	[ -d t/lib/testmore ] || git clone https://github.com/shiflett/testmore.git t/lib/testmore
	prove --exec 'php' t/*.t

install:
	php bin/install

update:
	php bin/install --update
