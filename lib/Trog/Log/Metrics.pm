package Trog::Log::Metrics;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures state};

use Trog::SQLite;

=head1 Trog::Log::Metrics

A means for acquiring time-series representations of the data recorded by Trog::Log::DBI,
and for reasoning about the various things that it's Urchin-compatible data can give you.

=cut

sub _dbh {
	return Trog::SQLite::dbh( 'schema/log.schema', "logs/log.db" );
}

=head2 requests_per(ENUM period{second,minute,hour,day,month,year}, INTEGER num_periods, [TIME_T before], INTEGER[] @codes)

Returns a data structure of the following form

    {
        labels => [TIME_STR, TIME_STR, ...],
        data   => [INT, INT,...]
    }

Describing the # of requests for the requested $num_periods $period(s) before $before.

'month' and 'year' are approximations for performance reasons; 30 day and 365 day periods.

Optionally filter by response code(s).

=cut

sub requests_per ($period, $num_periods, $before, @codes) {
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
		my $bind = join(',', (map { '?' } @codes));
		$whereclause = "WHERE code IN ($bind)";
		push(@input, @codes);
	}
	push(@input, $interval, $before, $num_periods);

    my $query = "SELECT count(*) FROM all_requests $whereclause GROUP BY date / ? HAVING date < ? LIMIT ?";

    my @results = map { $_->[0] } @{ _dbh()->selectall_arrayref($query, undef, @input) };
	my $np = @results < $num_periods ? @results : $num_periods;
	my @labels = reverse map { "$_ $period(s) ago" } (1..$np);

	return {
		labels => \@labels,
		data   => \@results,
	};
}

1;
