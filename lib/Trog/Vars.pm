package Trog::Vars;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

=head1 Trog::Vars

Constants shared between the data model, the renderer and the routes.

Nothing here is computed; it's all package variables so that callers can read
them directly rather than paying for a function call on every request.

=head2 VARIABLES

=over 4

=item %content_types

Maps the short names used in templates and route definitions (html, json, ...)
onto the Content-Type header they mean.

=item %byct

The reverse of %content_types, for going from a Content-Type back to the short
name -- which is how the renderer picks which Trog::Renderer subclass handles a
response.

=item %cache_control

Named Cache-Control policies.  'revalidate' for content which may have changed,
'nocache' for anything user specific, and 'static' for assets which are
immutable once published.

=back

=cut

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
