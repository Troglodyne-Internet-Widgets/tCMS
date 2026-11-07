package Trog::Jobs::App;

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Mojo::Base 'Mojolicious';    ## no critic (ProhibitUnusedImports) -- it makes this class a Mojolicious application

use Trog::Jobs();

=head1 NAME

Trog::Jobs::App - the Mojolicious application that runs the job queue of tCMS

=head1 DESCRIPTION

tCMS is run by tPSGI and has no Mojolicious application of its own.  Minion
needs one for its commands, so this is a small one that serves no page.  It
loads the queue of L<Trog::Jobs> and its tasks.  Start it with F<bin/tcms-jobs>,
from the root of the install:

    bin/tcms-jobs minion worker -j 1

=cut

sub startup ($self) {    ## no critic (ProhibitUnusedDefinitions) -- Mojolicious calls it
    $self->plugin( Minion => { SQLite => $Trog::Jobs::dsn } );
    Trog::Jobs::register_tasks( $self->minion );
    return;
}

1;
