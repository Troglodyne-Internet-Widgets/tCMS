package Trog::Vars;

use strict;
use warnings;

#1MB chunks
our $CHUNK_SEP  = 'tCMSep666YOLO42069';
our $CHUNK_SIZE = 1024000;

our %content_types = (
    text  => "text/plain",
    html  => "text/html",
    json  => "application/json",
    blob  => "application/octet-stream",
    xml   => "text/xml",
    xsl   => "text/xsl",
    css   => "text/css",
    rss   => "application/rss+xml"
);

our %byct = reverse %Trog::Vars::content_types;

our %cache_control = (
    revalidate => "no-cache, max-age=0",
    nocache    => "no-store",
    static     => "public, max-age=604800, immutable",
);

1;
