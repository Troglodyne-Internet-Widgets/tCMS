use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
  VERSION   => '0.01',
  PREREQ_PM => {
    'CGI::Cookie'            => '0',
    'Capture::Tiny'          => '0',
    'Carp'                   => '0',
    'Config::Simple'         => '0',
    'DBD::SQLite'            => '0',
    'DBI'                    => '0',
    'Date::Format'           => '0',
    'DateTime::Format::HTTP' => '0',
    'Digest::SHA'            => '0',
    'Errno'                  => '0',
    'File::Basename'         => '0',
    'File::Copy'             => '0',
    'File::Slurper'          => '0',
    'File::Touch'            => '0',
    'HTTP::Body'             => '0',
    'JSON::MaybeXS'          => '0',
    'List::Util'             => '0',
    'Mojo::File'             => '0',
    'POSIX'                  => '0',
    'Plack::Mime'            => '0',
    'Pod::Html'              => '0',
    'Starman'                => '0',
    'Text::Xslate'           => '0',
    'URL::Encode'            => '0',
    'UUID::Tiny'             => '0',
    'WWW::Sitemap::XML'      => '0',
    'WWW::SitemapIndex::XML' => '0',
  },
  test => {TESTS => 't/*.t'}
);
