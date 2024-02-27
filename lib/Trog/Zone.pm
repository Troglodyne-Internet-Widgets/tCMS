package Trog::Zone;

=head1 Trog::Zone

=head2 DESCRIPTION

Zonefile CRUD

=cut

use strict;
use warnings;

use feature qw{signatures};
no warnings qw{experimental};

use Trog::Config;
use Trog::Data;
use Trog::Vars;

use Net::IP;
use Ref::Util;

=head2 zone($domain) = @zonedata

Returns the zone data for the requested zone.
Like any other post in TCMS it's versioned.

=cut

sub zone($domain, $version=undef) {
    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);

    my @zonedata = $data->get( tags => ['zone'], acls => [qw{admin}], title => $domain  );
    @zonedata = grep { $_->{version} == $version } @zonedata if defined $version;
    return @zonedata;
}

=head2 addzone($domain, %options)

Add a post of 'zone' type.

=cut

my $valid_ip = sub {
    return Net::IP->new(shift);
};

my $valid_rev_ip = sub {
    return shift =~ m/\.in-addr\.arpa\.$/;
};

my $valid_rev_ip6 = sub {
    return shift =~ m/\.ip6\.arpa\.$/;
};

my $spec = {
    ip             => $valid_ip,
    ip6            => $valid_ip,
    ip_reversed    => $valid_rev_ip,
    ip6_reversed   => $valid_rev_ip6,
    nameservers    => \&Ref::Util::is_arrayref,
    subdomains     => \&Ref::Util::is_arrayref,
    cnames         => \&Ref::Util::is_arrayref,
    gsv_string     => $Trog::Vars::not_ref,
    dkim_pkey      => $Trog::Vars::not_ref,
    acme_challenge => $Trog::Vars::not_ref,
};

sub addzone($query) {
    my $domain = $query->{title};
    return unless $domain;
    my ($latest) = zone($domain);
    $latest //= {};

    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);

    %$latest = (
        %$latest,
        Trog::Vars::filter($query, $spec),
    );

    $data->add($latest);

    #TODO render and import into pdns

    return $latest;
}

sub delzone($domain) {
    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);

    my ($latest) = zone($domain);
    return unless $latest;
    return $data->delete($latest);    
}

1;
