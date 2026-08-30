use strict;
use warnings;

use Test::More;
use Test::Fatal qw{exception};
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw{tempdir};

BEGIN {
    # FindBin::libs adds lib/ to @INC based on the script location.
    # We stub it here so tests work from any directory.
    package FindBin::libs;
    sub import { }
    $INC{'FindBin/libs.pm'} = 1;
}

require_ok('Trog::Config') or BAIL_OUT("Can't load SUT");

# Reset memoized state between tests via the state variable trick:
# Trog::Config::get() uses a lexical `state $cf`.  We can't reset it directly,
# but we CAN swap the package-level path variables to point at our temp files
# and force a new load by temporarily swapping $home_cfg / $default.

subtest 'get — default config' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/config";

    # Trog::Config looks at config/$name, so put files in config/ subdir.
    my $cfg_text = "[general]\n    data_model=DUMMY\n    title=TestCMS\n";
    open my $fh, '>', "$dir/config/default.cfg" or die $!;
    print $fh $cfg_text;
    close $fh;

    # Point Trog::Config at our temp directory by running a fresh perl subprocess
    # so the state variable is clean.
    my $out = qx{PERL5LIB=lib:$ENV{PERL5LIB} perl -Ilib -e '
        use FindBin;
        use lib "$FindBin::Bin/lib";
        BEGIN {
            package FindBin::libs;
            sub import {}
            \$INC{"FindBin/libs.pm"} = 1;
        }
        use Trog::Config;
        \$Trog::Config::home_cfg = "nonexistent.cfg";
        \$Trog::Config::default  = "default.cfg";
        chdir("$dir") or die "chdir failed";
        my \$cfg = Trog::Config::get();
        print \$cfg->param("general.title"), "\n";
    ' 2>&1};
    chomp $out;
    is( $out, 'TestCMS', 'get() reads title from default config' );
};

subtest 'get — main config preferred over default' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    mkdir "$dir/config";

    open my $fh, '>', "$dir/config/main.cfg" or die $!;
    print $fh "[general]\n    data_model=FlatFile\n    title=MainCMS\n";
    close $fh;

    open $fh, '>', "$dir/config/default.cfg" or die $!;
    print $fh "[general]\n    data_model=DUMMY\n    title=DefaultCMS\n";
    close $fh;

    my $out = qx{PERL5LIB=lib:$ENV{PERL5LIB} perl -Ilib -e '
        BEGIN {
            package FindBin::libs;
            sub import {}
            \$INC{"FindBin/libs.pm"} = 1;
        }
        use Trog::Config;
        chdir("$dir") or die "chdir failed";
        my \$cfg = Trog::Config::get();
        print \$cfg->param("general.title"), "\n";
    ' 2>&1};
    chomp $out;
    is( $out, 'MainCMS', 'main.cfg takes precedence over default.cfg' );
};

subtest 'get — dies when no config found' => sub {
    my $dir = tempdir( CLEANUP => 1 );

    my $out = qx{PERL5LIB=lib:$ENV{PERL5LIB} perl -Ilib -e '
        BEGIN {
            package FindBin::libs;
            sub import {}
            \$INC{"FindBin/libs.pm"} = 1;
        }
        use Trog::Config;
        chdir("$dir") or die "chdir failed";
        eval { Trog::Config::get() };
        print \$\@ ? "died" : "survived";
    ' 2>&1};
    chomp $out;
    is( $out, 'died', 'get() dies when no config file is available' );
};

done_testing;
