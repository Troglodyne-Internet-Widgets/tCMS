package Trog::Component::EmojiPicker;

use strict;
use warnings;

no warnings qw{experimental};
use feature qw{signatures state};

use Trog::Renderer;

sub render () {
    state %categorized;

    if ( !%categorized ) {
        my $file = 'www/scripts/list.min.json';
        die "Run make prereq-frontend first" unless -f $file;

        my $raw    = File::Slurper::read_binary($file);
        my $emojis = Cpanel::JSON::XS::decode_json($raw);
        foreach my $emoji ( @{ $emojis->{emojis} } ) {
            $categorized{ $emoji->{category} } //= [];
            push( @{ $categorized{ $emoji->{category} } }, $emoji->{emoji} );
        }
    }

    return Trog::Renderer->render(
        contenttype => 'text/html',
        component   => 1,
        template    => 'emojis.tx',
        data        => {
            categories => \%categorized,
        },
    );
}

1;
