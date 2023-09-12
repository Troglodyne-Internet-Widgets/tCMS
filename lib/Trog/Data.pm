package Trog::Data;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

#It's just a factory

=head1 Trog::Data

This is a data model factory.

=head2 Trog::Data->new(Trog::Config) = $handle

Returns a new Trog::Data::* class appropriate to what is configured in the Trog::Config object passed.

=cut

sub new ( $class, $config ) {
    my $module = "Trog::Data::" . $config->param('general.data_model');
    my $req    = $module;
    $req =~ s/::/\//g;
    require "$req.pm";
    return $module->new($config);
}

1;
