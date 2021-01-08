use strict;
use warnings;

use Test2::V0;
use Test2::Tools::Explain;

use FindBin;

use Plack::Test;
use HTTP::Request::Common;

require "$FindBin::Bin/../www/server.psgi" or die 'Could not require server.psgi';

my $test = Plack::Test->create($tcms::app);

my $res = $test->request(HEAD "/");
diag explain [$tcms::app],$res;
