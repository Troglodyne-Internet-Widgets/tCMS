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
use Trog::SQLite;

use Net::IP;
use Ref::Util;

=head2 zone($domain) = @zonedata

Returns the zone data for the requested zone.
Like any other post in TCMS it's versioned.

=cut

sub zone ( $domain, $version = undef ) {
    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);

    my @zonedata = $data->get( tags => ['zone'], acls => [qw{admin}], title => $domain );
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

sub addzone ($query) {
    my $domain = $query->{title};
    return unless $domain;
    my ($latest) = zone($domain);
    $latest //= {};

    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);

    #XXX TODO make this instead use @records2add, complexity demon BAD
    my $processor = Text::Xslate->new( path => 'www/templates/text' );
    $query->{data} = $processor->render( 'zone.tx', $query );

    %$latest = (
        %$latest,
        Trog::Vars::filter( $query, $spec ),
    );

    $data->add($latest);

    #import into pdns
    my ( $ttl, $prio, $disabled ) = ( 300, 0, 0 );

    my $insert_sql  = q{insert into records (domain_id, name, type,content,ttl,prio,disabled) select id , ?, ?, ?, ?, ?, ? from domains where name=?};
    my @records2add = (
        [ $query->{title},                    'SOA',  "$query->{title} soa.$query->{title} $query->{version} 10800 3600 604800 10800" ],
        [ $query->{title},                    'A',    $query->{ip} ],
        [ $query->{title},                    'AAAA', $query->{ip6} ],
        [ $query->{ip_reversed},              'PTR',  $query->{title} ],
        [ $query->{ip6_reversed},             'PTR',  $query->{title} ],
        [ $query->{title},                    'MX',   "mail.$query->{title}" ],
        [ "_smtps._tcp.mail.$query->{title}", 'SRV',  "5 587 ." ],
        [ "_imaps._tcp.mail.$query->{title}", 'SRV',  "5 993 ." ],
        [ "_pop3s._tcp.mail.$query->{title}", 'SRV',  "5 995 ." ],
        [ "_dmarc.$query->{title}",           'TXT',  "v=DMARC1; p=reject; rua=mailto:postmaster\@$query->{title}; ruf=mailto:postmaster\@$query->{title}" ],
        [ "mail._domainkey.$query->{title}",  'TXT',  "v=DKIM1; h=sha256; k=rsa; t=y; p=$query->{dkim_pkey}" ],
        [ $query->{title},                    'TXT',  "v=spf1 +mx +a +ip4:$query->{ip} +ip6:$query->{ip6} -all" ],
        [ $query->{title},                    'TXT',  "google-site-verification=$query->{gsv_string}" ],
        [ "_acme-challenge.$query->{title}",  'TXT',  $query->{acme_challenge} ],
        [ $query->{title},                    'CAA',  '0 issue "letsencrypt.org"' ],
    );

    push( @records2add, ( map { [ "$_.$query->{title}", "CNAME", $query->{title} ] } @{ $query->{cnames} } ) );
    push( @records2add, ( map { [ $query->{title}, 'NS', $_ ] } @{ $query->{nameservers} } ) );
    foreach my $subdomain ( @{ $query->{subdomains} } ) {
        push( @records2add, [ "$subdomain->{name}.$query->{title}", 'A',    $subdomain->{ip} ] );
        push( @records2add, [ "$subdomain->{name}.$query->{title}", 'AAAA', $subdomain->{ip6} ] );
        push( @records2add, ( map { [ "$subdomain->{name}.$query->{title}", 'NS', $_ ] } @{ $subdomain->{nameservers} } ) );
    }

    my $dbh = _dbh();
    $dbh->begin_work();
    $dbh->do("DELETE FROM records") or _roll_and_die($dbh);
    foreach my $record (@records2add) {
        $dbh->do( $insert_sql, undef, @$record, $ttl, $prio, $disabled, $query->{title} ) or _roll_and_die($dbh);
    }
    $dbh->commit() or _roll_and_die($dbh);

    return $latest;
}

sub delzone ($domain) {
    my $conf = Trog::Config::get();
    my $data = Trog::Data->new($conf);

    my ($latest) = zone($domain);
    return unless $latest;
    return $data->delete($latest);
}

sub _dbh {
    return Trog::SQLite::dbh( undef, "dns/zones.db" );
}

sub _roll_and_die ($dbh) {
    my $err = $dbh->errstr;
    $dbh->rollback();
    die $err;
}

1;
