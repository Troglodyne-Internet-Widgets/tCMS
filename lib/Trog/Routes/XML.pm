package Trog::Routes::XML;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Encode qw{encode_utf8};

use Trog::Log qw{:all};
use Trog::Config;
use Trog::Data;
use Trog::Renderer;
use Trog::Routes::HTML();

our %routes = (
    '/sitemap' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
    },
    '/sitemap_index.xml' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
        data     => { xml => 1 },
    },
    '/sitemap_index.xml.gz' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
        data     => { xml => 1, compressed => 1 },
    },
    '/sitemap/static.xml' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
        data     => { xml => 1, map => 'static' },
    },
    '/sitemap/static.xml.gz' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
        data     => { xml => 1, compressed => 1, map => 'static' },
    },
    '/sitemap/(.*).xml' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
        data     => { xml => 1 },
        captures => ['map'],
    },
    '/sitemap/(.*).xml.gz' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::sitemap,
        data     => { xml => 1, compressed => 1 },
        captures => ['map'],
    },
    '/styles/rss-style.xsl' => {
        method   => 'GET',
        callback => \&Trog::Routes::XML::rss_style,
    },
);

=head2 sitemap

Return the sitemap index unless the static or a set of dynamic routes is requested.
We have a maximum of 99,990,000 posts we can make under this model
As we have 10,000 * 10,000 posts which are indexable via the sitemap format.
1 top level index slot (10k posts) is taken by our static routes, the rest will be /posts.

Passing ?xml=1 will result in an appropriate sitemap.xml instead.
This is used to generate the static sitemaps as expected by search engines.

Passing compressed=1 will gzip the output.

=cut

sub sitemap ($query) {

    state $data;
    $data //= Trog::Data->new(Trog::Config::get());

    state $etag = "sitemap-" . time();
    my ( @to_map, $is_index, $route_type );
    my $warning = '';
    $query->{map} //= '';
    if ( $query->{map} eq 'static' ) {

        # Return the map of static routes — scan all HTML routes excluding captures, auth, noindex, nomap
        $route_type = 'Static Routes';
        my %html_routes = %Trog::Routes::HTML::routes;
        @to_map     = grep { !defined $html_routes{$_}->{captures} && !$html_routes{$_}->{auth} && !$html_routes{$_}->{noindex} && !$html_routes{$_}->{nomap} } keys(%html_routes);
    }
    elsif ( !$query->{map} ) {

        # Return the index instead.
        # Count only public posts to avoid generating empty sitemap pages for private/unlisted content.
        @to_map = ('static');
        my @public_posts = $data->get( limit => 0, acls => ['public'] );
        my $tot   = scalar @public_posts;
        my $size  = 50000;
        my $pages = int( $tot / $size ) + ( ( $tot % $size ) ? 1 : 0 );

        # Truncate pages at 10k due to standard
        my $clamped = $pages > 49999 ? 49999 : $pages;
        $warning = "More posts than possible to represent in sitemaps & index!  Old posts have been truncated." if $pages > 49999;

        foreach my $page ( $clamped .. 1 ) {
            push( @to_map, "$page" );
        }
        $is_index = 1;
    }
    else {
        $route_type = "Posts: Page $query->{map}";

        # Return the map of the particular range of dynamic posts
        $query->{limit} = 50000;
        $query->{page}  = $query->{map};
        @to_map         = Trog::Routes::HTML::_post_helper( $query, [], ['public'] );
    }

    if ( $query->{xml} ) {
        DEBUG("RENDER SITEMAP XML");
        my $sm;
        my $xml_date = time();
        my $fmt      = "xml";
        $fmt .= ".gz" if $query->{compressed};
        if ( !$query->{map} ) {
            require WWW::SitemapIndex::XML;
            $sm = WWW::SitemapIndex::XML->new();
            foreach my $url (@to_map) {
                $sm->add(
                    loc     => "http://$query->{domain}/sitemap/$url.$fmt",
                    lastmod => $xml_date,
                );
            }
        }
        else {
            require WWW::Sitemap::XML;
            $sm = WWW::Sitemap::XML->new();
            my $changefreq = $query->{map} eq 'static' ? 'monthly' : 'daily';
            foreach my $url (@to_map) {
                my $true_uri = "http://$query->{domain}$url";
                if ( ref $url eq 'HASH' ) {
                    my $is_user_page = grep { $_ eq 'about' } @{ $url->{tags} };
                    $true_uri = "http://$query->{domain}/posts/$url->{id}";
                    $true_uri = "http://$query->{domain}/users/$url->{title}" if $is_user_page;
                }
                my %out = (
                    loc        => $true_uri,
                    lastmod    => $xml_date,
                    mobile     => 1,
                    changefreq => $changefreq,
                    priority   => 1.0,
                );

                if ( ref $url eq 'HASH' ) {

                    #add video & preview image if applicable
                    $out{images} = [
                        {
                            loc     => "http://$query->{domain}$url->{href}",
                            caption => $url->{data},
                            title   => substr( $url->{title}, 0, 100 ),
                        }
                      ]
                      if $url->{is_image};

                    # Truncate descriptions
                    my $desc    = substr( $url->{data}, 0, 2048 ) || '';
                    my $href    = $url->{href}                    || '';
                    my $preview = $url->{preview}                 || '';
                    my $domain  = $query->{domain}                || '';
                    $out{videos} = [
                        {
                            content_loc   => "http://$domain$href",
                            thumbnail_loc => "http://$domain$preview",
                            title         => substr( $url->{title}, 0, 100 ) || '',
                            description   => $desc,
                        }
                      ]
                      if $url->{is_video};
                }

                $sm->add(%out);
            }
        }
        my $xml = $sm->as_xml();
        require IO::String;
        my $buf = IO::String->new();
        my $ct  = 'application/xml';
        $xml->toFH( $buf, 0 );
        seek $buf, 0, 0;

        if ( $query->{compressed} ) {
            require IO::Compress::Gzip;
            my $compressed = IO::String->new();
            IO::Compress::Gzip::gzip( $buf => $compressed );
            $ct  = 'application/gzip';
            $buf = $compressed;
            seek $compressed, 0, 0;
        }

        #XXX This is one of the few exceptions where we don't use finish_render, as it *requires* gzip.
        return [ 200, [ "Content-type" => $ct, 'ETag' => $etag ], $buf ];
    }

    @to_map = sort @to_map unless $is_index;
    my $styles = ['sitemap.css'];

    $query->{title}      = "$query->{domain} : Sitemap";
    $query->{template}   = 'sitemap.tx';
    $query->{to_map}     = \@to_map;
    $query->{is_index}   = $is_index;
    $query->{route_type} = $route_type;
    $query->{etag}       = $etag;

    return Trog::Routes::HTML::index( $query, undef, $styles );
}

sub _rss ( $query, $subtitle, $posts ) {

    require XML::RSS;
    my $rss  = XML::RSS->new( version => '2.0', stylesheet => '/styles/rss-style.xsl' );
    my $now  = DateTime->from_epoch( epoch => time() );
    my $port = $query->{port} ? ":$query->{port}" : '';
    $rss->channel(
        title         => "$query->{domain}",
        subtitle      => $subtitle,
        link          => "http://$query->{domain}$port/$query->{route}?format=xml",
        language      => 'en',                                                        #TODO localization
        description   => "$query->{domain} : $query->{route}",
        pubDate       => $now,
        lastBuildDate => $now,
    );

    $rss->image(
        title       => $query->{domain},
        url         => "/favicon.ico",
        link        => "http://$query->{domain}$port",
        width       => 32,
        height      => 32,
        description => "$query->{domain} favicon",
    );

    foreach my $post (@$posts) {
        my $url = "http://$query->{domain}$port$post->{local_href}";
        _post2rss( $rss, $url, $post );
        next unless ref $post->{aliases} eq 'ARRAY';
        foreach my $alias ( @{ $post->{aliases} } ) {
            $url = "http://$query->{domain}$port$alias";
            _post2rss( $rss, $url, $post );
        }
    }

    return Trog::Renderer->render(
        template => 'raw.tx',
        data     => {
            etag   => $query->{etag},
            body   => encode_utf8( $rss->as_string ),
            scheme => $query->{scheme},
        },
        headers => { 'Content-Disposition' => 'inline; filename="rss.xml"' },

        #XXX if you do the "proper" content-type of application/rss+xml, browsers download rather than display.
        contenttype => "text/xml",
        code        => 200,
    );
}

sub _post2rss ( $rss, $url, $post ) {
    $rss->add_item(
        title       => $post->{title},
        permaLink   => $url,
        link        => $url,
        enclosure   => { url => $url, type => "text/html" },
        description => "<![CDATA[$post->{data}]]>",
        pubDate     => DateTime->from_epoch( epoch => $post->{created} ),    #TODO format like Thu, 23 Aug 1999 07:00:00 GMT
        author      => $post->{user},                                        #TODO translate to "email (user)" format
    );
}

sub rss_style ($query) {
    $query->{port}       = ":$query->{port}" if $query->{port};
    $query->{title}      = qq{<xsl:value-of select="rss/channel/title"/>};
    $query->{no_doctype} = 1;

    # Due to this being html rather than XML, we can't use an include directive.
    $query->{header} = Trog::Renderer->render( template => 'header.tx', data => $query, contenttype => 'text/html', component => 1 );
    $query->{footer} = Trog::Renderer->render( template => 'footer.tx', data => $query, contenttype => 'text/html', component => 1 );

    return Trog::Renderer->render(
        template    => 'rss-style.tx',
        contenttype => 'text/xsl',
        data        => $query,
        code        => 200,
    );
}

1;
