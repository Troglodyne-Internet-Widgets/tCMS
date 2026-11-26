package Trog::Log::Metrics;

# ABSTRACT: Time series of the requests that Trog::Log::DBI records

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Trog::Log;

=head1 Trog::Log::Metrics

A means for acquiring time-series representations of the data recorded by Trog::Log::DBI,
and for reasoning about the various things that it's Urchin-compatible data can give you.

=cut

=head2 requests_per($period, $num_periods, $before, @codes)

Count the requests in the log database for $num_periods periods of length
$period, before the time $before.  Optionally filter by response code(s).

'month' and 'year' are approximations for performance reasons: a month is 30
days, and a year is 31356000 seconds.

=over 4

=item period - Str - one of C<second>, C<minute>, C<hour>, C<day>, C<week>,
C<month> and C<year>

=item num_periods - Int - how many periods to count, at most

=item before - Int|undef - a Unix time; a false value means now

=item codes - List[Int] - the response codes to count; none means all

=back

Returns HashRef, of the following form:

    {
        labels => [ '3 day(s) ago', '2 day(s) ago', '1 day(s) ago' ],
        data   => [ 12, 40, 7 ],
    }

C<data> holds one count for each period that has requests, and no more than
$num_periods of them.  C<labels> holds one label for each count.

Dies when $period is not one of the names above.

    my $counts = Trog::Log::Metrics::requests_per( $in->{period}, $in->{num_periods}, $in->{before}, @$code );

=cut

sub requests_per ( $period, $num_periods, $before, @codes ) {
    $before ||= time;

    # Build our periods in seconds.
    state %period2time = (
        second => 1,
        minute => 60,
        hour   => 3600,
        day    => 86400,
        week   => 604800,
        month  => 2592000,
        year   => 31356000,
    );

    my $interval = $period2time{$period};
    die "Invalid time interval passed." unless $interval;

    my @input;
    my $whereclause = '';
    if (@codes) {
        my $bind = join( ',', ( map { '?' } @codes ) );
        $whereclause = "WHERE code IN ($bind)";
        push( @input, @codes );
    }
    push( @input, $interval, $before, $num_periods );

    ## no critic(ValuesAndExpressions::PreventSQLInjection)
    my $query = "SELECT count(*) FROM all_requests $whereclause GROUP BY date / ? HAVING date < ? LIMIT ?";

    my @results = map { $_->[0] } @{ Trog::Log::dbh()->selectall_arrayref( $query, undef, @input ) };
    my $np      = @results < $num_periods ? @results : $num_periods;
    my @labels  = reverse map { "$_ $period(s) ago" } ( 1 .. $np );

    return {
        labels => \@labels,
        data   => \@results,
    };
}

1;
