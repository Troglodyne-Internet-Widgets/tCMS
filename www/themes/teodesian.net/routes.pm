package Theme;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use lib 'lib';
use Trog::Routes::HTML;

our $default_title = 'TEODESIAN.NET WHIPS THEM CHIPS ~';

our %routes = (
    '/links' => {
        method   => 'GET',
        callback => \&links,
    },
    '/' => {
        method   => "GET",
        data     => { tag => ['news'] },
        callback => \&Trog::Routes::HTML::posts
    },
);

my $processor = Text::Xslate->new(
    path => 'www/themes/teodesian.net/templates',
);

my %paths = (
    '/news' => 'Headline Nudes',
    '/'     => 'Headline Nudes',
);

sub path_to_tile ($path) {
    return $paths{$path} ? $paths{$path} : $path;
}

sub links ($query, $render_cb) {
    my $content = $processor->render('links.tx', {
        title => "Approved Propaganda from the ministry of family values",
        theme_dir => 'themes/teodesian.net',
    });
    return Trog::Routes::HTML::index($query, $render_cb, $content);
}

1;
