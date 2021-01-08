use strict;
use warnings;

use Test2::V0;
use Test2::Tools::Explain;

use FindBin;

use Plack::Test;
use HTTP::Request::Common;

require "$FindBin::Bin/../www/server.psgi" or die 'Could not require server.psgi';

my $test = Plack::Test->create($tcms::app);

#TODO Need a testing routing table which I can dynamically include -- a testing theme is probably the way
my $r = $test->request(GET '/posts');
die;

subtest "HEAD requests handled correctly" => sub {
    my $res = $test->request(HEAD "/");
    cmp_ok($res->header('content-length'), '>', 0, "Headers sent correctly");
    is($res->code, 200, "Return code returned as expected");
    is($res->content, '', "No content actually returned by HEAD request");
};

done_testing();
