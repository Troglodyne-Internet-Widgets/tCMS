use strict;
use warnings;

use Test::More;
use FindBin;

# policy/ has to be on @INC *before* Perl::Critic loads: it finds policies by
# scanning @INC once, at load time, so adding the directory afterwards leaves
# it unable to see ours.
use lib "$FindBin::Bin/../policy";

# The policy is a development tool, not part of tCMS proper -- it lives in
# policy/ and is never installed.  Anyone without Perl::Critic can still run
# the rest of the suite.
BEGIN {
    plan skip_all => 'Perl::Critic not installed' unless eval { require Perl::Critic; 1 };
}

my $policy = 'Troglodyne::ProhibitPipeOpen';
require_ok("Perl::Critic::Policy::$policy") or BAIL_OUT("Can't find SUT");

# -profile => '' so the repo's own .perlcriticrc, which perlcritic would
# otherwise find by walking up from cwd, doesn't drag in every other policy and
# fail these snippets for want of POD.
# Note the hyphen: -single_policy is silently ignored and you get all 222
# policies instead.  -profile => '' so the repo's own .perlcriticrc, which
# perlcritic would otherwise find by walking up from cwd, doesn't drag in every
# other policy and fail these snippets for want of POD.
my $critic = Perl::Critic->new( -profile => q{}, '-single-policy' => $policy, -severity => 1 );

sub violations {
    my ($source) = @_;
    return scalar $critic->critique( \"use strict;\nuse warnings;\n$source\n" );
}

subtest 'opens that spawn something are caught' => sub {
    my %cases = (
        'three-arg read'    => q{open( my $fh, '-|', 'ls', '-l' );},
        'three-arg write'   => q{open( my $fh, '|-', 'mail', $to );},
        'bare two-arg fork' => q{open( my $fh, '-|' );},
        'two-arg trailing'  => q{open( FH, 'ls -l |' );},
        'two-arg leading'   => q{open( FH, '| mail bob' );},
        'qw-quoted mode'    => q{open( my $fh, q{-|}, 'ls' );},
    );
    foreach my $name ( sort keys %cases ) {
        is( violations( $cases{$name} ), 1, "$name is a violation" );
    }
};

subtest 'ordinary file opens are left alone' => sub {
    my %cases = (
        'read'              => q{open( my $fh, '<', $path );},
        'write'             => q{open( my $fh, '>', $path );},
        'append'            => q{open( my $fh, '>>', $path );},
        'interpolated path' => q{open( my $fh, '>', "$dir/thing" );},
        'in-memory'         => q{open( my $fh, '<', \$scalar );},
        'opendir'           => q{opendir( my $dh, $dir );},
        'bitwise or'        => q{my $x = $a | $b;},
        'a sub named open'  => q{$obj->open( '-|', 'ls' );},
    );
    foreach my $name ( sort keys %cases ) {
        is( violations( $cases{$name} ), 0, "$name is not a violation" );
    }
};

subtest 'the annotation is what signs it off' => sub {
    is(
        violations(q{open( my $fh, '-|', 'ls' );  ## no critic (Troglodyne::ProhibitPipeOpen)}),
        0,
        'an explicit no-critic suppresses it'
    );
};

done_testing();
