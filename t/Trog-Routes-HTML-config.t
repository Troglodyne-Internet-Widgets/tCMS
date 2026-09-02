use strict;
use warnings;

use Test::More;
use Cwd();
use File::Path();
use File::Temp();
use Path::Tiny();
use FindBin;

use lib "$FindBin::Bin/../lib";

# The config editor is built out of config/default.cfg rather than a hardcoded
# list of fields, so what it can edit is whatever that file describes.  These
# tests stand inside an instance root, since every path in this app is
# cwd-relative -- and they stand there before the SUT is loaded, because reading
# the configuration is memoized and would otherwise be the one in this checkout.
our $ROOT   = File::Temp::tempdir( 'tcms-config-route-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
our $OLDCWD = Cwd::getcwd();

END {
    chdir($OLDCWD)                 if $OLDCWD;
    File::Path::remove_tree($ROOT) if $ROOT && -d $ROOT;
}

File::Path::make_path("$ROOT/config");
File::Path::make_path("$ROOT/www/themes/spec");
chdir($ROOT) or die $!;

Path::Tiny->new('config/default.cfg')->spew_utf8(<<'CFG');
[general]
    # FlatFile or SQLite.
    data_model=FlatFile
    # Which directory under www/themes to render with.
    theme=
    title=Stock
    hostname=stock.example.com
[security]
    allow_embeds_from=vimeo.com *.vimeo.com youtube.com *.youtube.com www.youtube-nocookie.com
CFG

# What this instance is actually running with, which is not what ships -- and
# one setting it deliberately cleared.
Path::Tiny->new('config/main.cfg')->spew_utf8(<<'CFG');
[general]
theme=spec
hostname=spec.example.com
title=
CFG

require_ok('Trog::Routes::HTML') or BAIL_OUT("Can't find SUT");

my %field;
my $sections = Trog::Routes::HTML::_config_sections();
foreach my $section (@$sections) {
    $field{ $_->{name} } = $_ foreach @{ $section->{fields} };
}

subtest 'the form is the shape of the defaults' => sub {
    is_deeply( [ map { $_->{section} } @$sections ], [qw{general security}],    'a details block per section, in file order' );
    is_deeply( [ map { $_->{title} } @$sections ],   [ 'General', 'Security' ], 'each with a legible summary' );

    is_deeply(
        [ map { $_->{name} } @{ $sections->[0]{fields} } ],
        [qw{general.data_model general.theme general.title general.hostname}],
        'and the keys that section describes, in order'
    );
    is( $field{'general.data_model'}{title},   'Data Model',          'a key gets a legible label' );
    is( $field{'general.data_model'}{comment}, 'FlatFile or SQLite.', '...and the comment above it for help' );
};

subtest 'fields carry what the instance is running with' => sub {
    is( $field{'general.hostname'}{value},   'spec.example.com', 'a setting this instance overrode shows its value' );
    is( $field{'general.data_model'}{value}, 'FlatFile',         '...and one it never touched falls back to the default' );

    # Blanking a setting is how you turn it off, so the defaults must not creep
    # back in and get re-saved on the next commit.
    is( $field{'general.title'}{value}, '', '...while one cleared on purpose stays cleared' );
};

subtest 'the settings which are a choice are menus' => sub {

    # default.cfg can say general.theme exists; it cannot say it has to be one
    # of the themes on disk, so that part is not read off the file.
    my $themes = $field{'general.theme'}{options};
    is_deeply( [ map { $_->{value} } @$themes ], [ '', 'spec' ], 'the theme menu is what is installed, plus none' );
    is( $themes->[0]{label}, 'default', 'the empty theme is named rather than blank' );
    is_deeply( [ map { $_->{selected} } @$themes ], [ 0, 1 ], 'and the running theme is the selected one' );

    ok( scalar @{ $field{'general.data_model'}{options} }, 'the data model is a menu too' );
    ok( !$field{'general.title'}{options},                 'while a free text setting is not' );
    ok( $field{'security.allow_embeds_from'}{multiline},   'a long value gets a textarea' );
    ok( !$field{'general.hostname'}{multiline},            '...and a short one does not' );
};

subtest 'saving only writes what the defaults describe' => sub {
    require Config::Simple;
    my $conf = Config::Simple->new( syntax => 'ini' );

    Trog::Routes::HTML::_config_apply(
        $conf,
        {
            'general.title' => 'Renamed',
            'general.theme' => '',

            # Neither of these is in the schema: one is a leftover from the
            # form this replaced, the other is somebody trying it on.
            'theme'          => 'nope',
            'general.pwnage' => 'nope',
        }
    );

    is( $conf->param('general.title'), 'Renamed', 'a posted setting is saved' );
    is( $conf->param('general.theme'), '',        'including one cleared back to empty' );
    is_deeply( [ $conf->param('general.pwnage') ], [], 'a key the defaults never named is ignored' );
    is_deeply( [ $conf->param('theme') ],          [], '...as is the bare name the old form used' );
};

done_testing();
