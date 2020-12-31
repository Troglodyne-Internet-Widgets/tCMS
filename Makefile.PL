use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  VERSION   => '0.01',
  PREREQ_PM => {
    'Mojo::File' => '0',
    'Date::Format' => '0',
    'WWW::SitemapIndex::XML' => '0',
    'WWW::Sitemap::XML' => '0',
    'HTTP::Body' => '0',
    'Pod::Html' => '0',
    'URL::Encode' => '0',
  },
  test => {TESTS => 't/*.t'}
);
