package Theme;

use lib 'lib';
use Trog::Routes::HTML;

my %routes = {
    '/links' => {
        method   => 'GET',
        callback => \&links,
    },
};

my $processor = Text::Xslate->new(
    path => 'www/themes/teodesian.net/templates',
);

sub links ($query, $input, $render_cb) {
    my $content = $processor->render('links.tx', {
        title => "Approved Propaganda from the ministry of family values",
        theme_dir => 'www/themes/teodesian.net',
    });
    return Trog::Routes::HTML::index($query, $input, $render_cb, $content);
}

1;
