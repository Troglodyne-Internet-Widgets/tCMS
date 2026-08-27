package Trog::Vars;

use strict;
use warnings;

use feature qw{signatures};
no warnings qw{experimental};


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
    rss   => "application/rss+xml",
    email => "multipart/related",
);

our %byct = reverse %Trog::Vars::content_types;

our %cache_control = (
    revalidate => "no-cache, max-age=0",
    nocache    => "no-store",
    static     => "public, max-age=604800, immutable",
);

# NOTE: the post schema and its validators used to be duplicated here as well
# as in Trog::DataModule, and filter() had no callers at all.  Both are gone --
# a post's shape is now an OpenAPIv3 schema, see Trog::DataModule::schema_for().

1;
