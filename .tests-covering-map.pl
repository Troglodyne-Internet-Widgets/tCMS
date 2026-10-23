#!/usr/bin/env perl
use 5.040;
use warnings FATAL => 'all';
use re '/aa';

=head1 NAME

.tests-covering-map.pl - which tests reach the files that no test loads, for
tests-covering

=head1 DESCRIPTION

git-hooks/pre-commit asks tests-covering which tests a commit can break.
tests-covering follows the Perl that each test loads, and asks this map about
every other file in the diff.  See "THE MAP" in L<Perl::Tests::Covering>.

The map answers C<q{}>, which is C<NO_TESTS>, for the files of tCMS that
C<prove -l t/> never reads:

=over

=item Documentation

Markdown, such as F<Readme.md> and F<design.md>, POD in F<.pod> files outside
F<lib/>, F<CHANGELOG> and F<LICENSE>.

=item The build and the install

F<Makefile.PL>, F<Installer.mk>, F<package.json> and F<package-lock.json>.
C<make> and C<npm> read them, and no test does.

=item The tools and the hooks

The C<perltidy> and C<perlcritic> configuration and the files that it reads,
F<.mailmap>, F<.gitignore>, F<.gitattributes>, this map, F<git-hooks/> and
F<.github/>.

=item The author tests

F<xt/>, which the hooks do not run.

=back

Anything else, it leaves unexplained, and the hook then runs every test.  A
file that a test reads without loading it, such as a template or a fixture,
wants a rule here that names the tests that read it.

=cut

# Read by the tools, by make or by people, and by no test.
my %NO_TESTS = map { $_ => 1 } qw{
  CHANGELOG LICENSE
  Makefile.PL Installer.mk package.json package-lock.json
  .perltidyrc .perlcriticrc .perlcriticrc.compat .pod_stopwords .preferred_modules.ini .preferred_binaries.ini
  .mailmap .gitignore .gitattributes .tests-covering-map.pl
};

return sub {
    my ($path) = @_;

    return q{} if $NO_TESTS{$path};
    return q{} if $path =~ m{\A(?:git-hooks|[.]github|xt)/}sx;
    return q{} if $path =~ m{[.]md\z}sx;
    return q{} if $path =~ m{[.]pod\z}sx && $path !~ m{\Alib/}sx;

    return;
};
