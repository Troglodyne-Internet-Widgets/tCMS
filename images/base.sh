#!/bin/sh

ctr=$(buildah from alpine:latest)
mnt=$(buildah mount "$ctr")

mkdir -p "$mnt/tmp/tcms"
cp Makefile.PL "$mnt/tmp/tcms/"

buildah run -- $ctr sh <<EOF
  apk update
  apk add perl perl-xml-libxml perl-moose perl-datetime perl-dbi perl-dbd-sqlite perl-capture-tiny perl-date-format

	# needed for install
	apk add curl make musl-dev perl-dev gcc mlocate perl-app-cpanminus
	cpanm -n --no-wget --curl --installdeps /tmp/tcms/
	apk del curl make musl-dev perl-dev gcc mlocate perl-app-cpanminus
EOF

rm -rf \
	"$mnt/tmp/tcms"       \
	"$mnt/var/cache"      \
	"$mnt/root/.cpanm"    \
	"$mnt/usr/share/man/" \
  "$mnt/usr/local/share/man"

find "$mnt/usr/lib/perl5" -name '*.pod' -delete

mkdir -p "$mnt/srv/tcms"
cp -R bin/ config/ data/ www/ lib "$mnt/srv/tcms";

buildah config                              \
  --workingdir "/srv/tcms/"                 \
	--entrypoint '["/usr/local/bin/starman"]' \
	--cmd "/srv/tcms/www/server.psgi"         \
	--port 5000                               \
	--label "Name=tCMS"                       \
	--author "George Baugh"                   \
	"$ctr"
buildah commit --rm "$ctr" tcms
