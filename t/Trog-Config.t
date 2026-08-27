use strict;
use warnings;

use Test::More;
use Cwd();
use File::Path();
use File::Temp();
use Path::Tiny();
use FindBin;

use lib "$FindBin::Bin/../lib";

# $Trog::Config::default is read exactly once below, which is enough for perl
# to suspect a typo.
no warnings qw{once};

require_ok('Trog::Config') or BAIL_OUT("Can't find SUT");

# Every path in this app is cwd-relative, so exercise it the way the app sees
# it: from inside an instance root.  CLEANUP => 0 plus an explicit END, because
# a tempdir cannot tidy itself up while we are standing inside it.
our $ROOT   = File::Temp::tempdir( 'tcms-config-XXXXXX', TMPDIR => 1, CLEANUP => 0 );
our $OLDCWD = Cwd::getcwd();

END {
    chdir($OLDCWD) if $OLDCWD;
    File::Path::remove_tree($ROOT) if $ROOT && -d $ROOT;
}

File::Path::make_path("$ROOT/config");
chdir($ROOT) or die $!;

subtest 'the defaults are where the app actually keeps them' => sub {

    # The whole bug this test exists for: get() used to hardcode the 'config/'
    # prefix internally, so $home_cfg was a bare basename and every writer that
    # used it put the file somewhere get() would never look.
    is( $Trog::Config::home_cfg, 'config/main.cfg',    'home_cfg is a usable path' );
    is( $Trog::Config::default,  'config/default.cfg', 'and so is the default' );

    like( $Trog::Config::home_cfg, qr{^config/}, 'home_cfg is under config/' );
    unlike( $Trog::Config::home_cfg, qr{^/}, 'and is relative, so it follows the instance root' );
};

subtest 'a config written to home_cfg is the one that gets read back' => sub {
    Path::Tiny->new('config/default.cfg')->spew_utf8("[general]\ndata_model=FlatFile\ntitle=Stock\n");

    # This is the round trip that was broken: write where the writers write,
    # read where the readers read, and check they agree.
    require Config::Simple;
    my $written = Config::Simple->new( syntax => 'ini' );
    $written->param( 'general.data_model', 'FlatFile' );
    $written->param( 'general.title',      'Instance' );
    $written->param( 'general.hostname',   'spec.example.com' );
    ok( $written->write($Trog::Config::home_cfg), 'wrote to home_cfg' );

    ok( -f 'config/main.cfg', 'which landed under config/, not the instance root' );
    ok( !-f 'main.cfg',       'and not loose in the root where nothing would read it' );

    my $read = Trog::Config::get();
    is( $read->param('general.title'),    'Instance',         'get() picked up the written config' );
    is( $read->param('general.hostname'), 'spec.example.com', 'including a key the defaults never had' );
};

subtest 'the shipped defaults are left alone' => sub {
    # get() is memoized, so this is the same object as above -- which is the
    # point: bin/tcms-hostname used to call save() on it, and save() writes back
    # to whichever file it was constructed from.
    is( Path::Tiny->new('config/default.cfg')->slurp_utf8,
        "[general]\ndata_model=FlatFile\ntitle=Stock\n",
        'default.cfg is untouched' );
};

done_testing();
