package Trog::Vars;

use strict;
use warnings;

use feature qw{signatures};
no warnings qw{experimental};

use Ref::Util();
use List::Util qw{any};

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

our $not_ref = sub {
    return !Ref::Util::is_ref(shift);
};

our $valid_cb = sub {
    my $subname = shift;
    my ($modname) = $subname =~ m/^([\w|:]+)::\w+$/;

    # Modules always return 0 if they succeed!
    eval { require $modname; } and do {
        WARN("Post uses a callback whos module ($modname) cannot be found!");
        return 0;
    };

    no strict 'refs';
    my $ref = eval '\&' . $subname;
    use strict;
    return Ref::Util::is_coderef($ref);
};

our $hashref_or_string = sub {
    my $subj = shift;
    return Ref::Util::is_hashref($subj) || $not_ref->($subj);
};

# Shared Post schema
our %schema = (
    ## Parameters which must be in every single post
    'title'      => $not_ref,
    'callback'   => $valid_cb,
    'tags'       => \&Ref::Util::is_arrayref,
    'version'    => $not_ref,
    'visibility' => $not_ref,
    'aliases'    => \&Ref::Util::is_arrayref,
    'tiled'      => $not_ref,

    # title links here
    'href' => $not_ref,

    # Link to post locally
    'local_href' => $not_ref,

    # Post body
    'data' => $not_ref,

    # How do I edit this post?
    'form' => $not_ref,

    # Post is restricted to visibility to these ACLs if not public/unlisted
    'acls' => \&Ref::Util::is_arrayref,
    'id'   => $not_ref,

    # Author of the post
    'user'    => $not_ref,
    'created' => $not_ref,
);

=head2 filter($data,[$schema]) = %$data_filtered

Filter the provided data through the default schema, and optionally a user-provided schema.

Remove unwanted params to keep data slim & secure.

=cut

sub filter ($data, $user_schema={}) {
    %$user_schema = (
        %schema,
        %$user_schema,
    );

    # Filter all the irrelevant data
    foreach my $key ( keys(%$data) ) {
        # We need to have the key in the schema, and it validate.
        delete $data->{$key} unless List::Util::any { ( $_ eq $key ) && ( $user_schema->{$key}->( $data->{$key} ) ) } keys(%$user_schema);
    }
    return %$data;
}

1;
