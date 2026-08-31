package Trog::Component::EmojiPicker;

use v5.36;
use re '/aa';

use JSON::MaybeXS;
use Trog::Renderer;

=head1 Trog::Component::EmojiPicker

The emoji picker component.

=head1 Termination Conditions

Dies if the emoji list isn't on disk, as there's no sensible picker to show
without it.  It's a frontend dependency, so C<make prereq-frontend> is what
puts it there.

=head1 FUNCTIONS

=head2 render() = STRING

Render the picker as an HTML component.

The emoji list ships as a flat array, which is no use to a picker with tabs, so
it gets bucketed by category on the first call and memoized thereafter -- the
list can't change without a redeploy.

Returns the rendered body, rather than a PSGI triplet, as components are meant
to be composed into a page by their caller.

=cut

sub render () {
    state %categorized;

    if ( !%categorized ) {
        my $file = 'www/scripts/list.min.json';
        die "Run make prereq-frontend first" unless -f $file;

        my $raw    = File::Slurper::read_binary($file);
        my $emojis = JSON::MaybeXS::decode_json($raw);
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
