package Theme;

use v5.36;
use re '/aa';

=head1 Theme

An example of the bare minimum your themes' routes.pm need.
Copy and alter things below as needed.

Themes are loaded by Trog::Themes::routes(), which requires the active theme's
routes.pm and expects it to have populated the package variables below, along
with %Theme::routes if the theme wants routes of its own.

Everything here is optional -- Trog::Routes::HTML falls back to generic tCMS
defaults for anything a theme leaves unset -- but a site that sets none of it
will identify itself as "Another tCMS Site" to search engines and social media.

=head2 VARIABLES

=over 4

=item $default_title

Fallback <title> for pages which have no post of their own to name them.

=item $default_image

The image handed to social media scrapers as the site's preview, relative to
the theme directory.

=item $display_name

What the site calls itself, e.g. in the og:site_name meta tag.

=item $description

Fallback meta description, used when the page has no post body to summarize.

=item $default_tags

Comma separated keywords for the meta keywords tag.

=item $twitter_account, $fb_app_id

Set these if you want the relevant twitter: and fb: meta tags emitted.
Left empty, HTML::SocialMeta is handed nothing to put in them.

=back

=cut

our $default_title = 'tCMS';
our $default_image = 'img/icon/favicon-48.png';
our $display_name  = 'tCMS';
our $description   = 'tCMS is a content management system written in perl.';
our $default_tags  = 'tcms';

our $twitter_account = '';
our $fb_app_id       = '';

1;
