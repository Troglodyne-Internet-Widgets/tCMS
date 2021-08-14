package Trog::SQLite::TagIndex;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use List::Util qw{uniq};
use Trog::SQLite;

=head1 Trog::SQLite::TagIndex

An SQLite3 index of posts by tag and date.
Used to speed up the flat-file data model.

Also used to retrieve cached routes from posts.

=head1 FUNCTIONS

=cut

sub posts_for_tags (@tags) {
    my $dbh = _dbh();
    my $clause = @tags ? "WHERE tag IN (".join(',' ,(map {'?'} @tags)).")" : '';
    my $rows = $dbh->selectall_arrayref("SELECT DISTINCT id FROM posts $clause ORDER BY created DESC",{ Slice => {} }, @tags);
    return () unless ref $rows eq 'ARRAY' && @$rows;
    return map { $_->{id} } @$rows;
}

sub routes {
    my $dbh = _dbh();
    my $rows = $dbh->selectall_arrayref("SELECT id, route, method, callback FROM all_routes",{ Slice => {} });
    return () unless ref $rows eq 'ARRAY' && @$rows;

    my %routes = map { $_->{route} => $_ } @$rows;
    return %routes;
}

sub aliases {
    my $dbh = _dbh();
    my $rows = $dbh->selectall_arrayref("SELECT actual,alias FROM aliases", { Slice => {} });
    return () unless ref $rows eq 'ARRAY' && @$rows;
    my %aliases = map { $_->{alias} => $_->{actual} } @$rows;
    return %aliases;
}

sub add_post ($post,$data_obj) {
    my $dbh = _dbh();
    build_routes($data_obj,[$post]);
    return build_index($data_obj,[$post]);
}

sub remove_post ($post) {
    my $dbh = _dbh();
    $dbh->do("DELETE FROM routes WHERE route=?", undef, $post->{local_href});
    return $dbh->do("DELETE FROM posts_index WHERE post_id=?", undef, $post->{id});
}

sub build_index($data_obj,$posts=[]) {
    my $dbh = _dbh();
    $posts = $data_obj->read({ limit => 0, acls => ['admin'] }) unless @$posts;

    my @tags = uniq map { @{$_->{tags}} } @$posts;
    Trog::SQLite::bulk_insert($dbh,'tag', ['name'], 'IGNORE', @tags); 
    my $t = $dbh->selectall_hashref("SELECT id,name FROM tag", 'name');
    foreach my $k (keys(%$t)) { $t->{$k} = $t->{$k}->{id} };

    Trog::SQLite::bulk_insert($dbh,'posts_index',[qw{post_id post_time tag_id}], 'IGNORE', map {
        my $subj = $_;
        map { ( $subj->{id}, $subj->{created}, $t->{$_} ) } @{$subj->{tags}}
    } @$posts );
}

# It is important we use get() instead of read() because of incomplete data.
sub build_routes($data_obj,$posts=[]) {
    my $dbh = _dbh();
    @$posts = $data_obj->get( limit => 0, acls => ['admin'] ) unless @$posts;

    # Ensure the callbacks we need are installed
    Trog::SQLite::bulk_insert($dbh,'callbacks', [qw{callback}], 'IGNORE', (uniq map { $_->{callback} } @$posts) );

    my $m = $dbh->selectall_hashref("SELECT id, method FROM methods", 'method');
    foreach my $k (keys(%$m)) { $m->{$k} = $m->{$k}->{id} };
    my $c = $dbh->selectall_hashref("SELECT id, callback FROM callbacks", 'callback');
    foreach my $k (keys(%$c)) { $c->{$k} = $c->{$k}->{id} };
    @$posts = map {
        $_->{method_id}   = $m->{$_->{method}};
        $_->{callback_id} = $c->{$_->{callback}};
        $_
    } @$posts;

    my @routes = map { ($_->{local_href}, $_->{method_id}, $_->{callback_id} ) } @$posts;
    Trog::SQLite::bulk_insert($dbh,'routes', [qw{route method_id callback_id}], 'IGNORE', @routes); 

    # Now, compile the post aliases
    my %routes_actual = routes();
    foreach my $post (@$posts) {
        next unless @{$post->{aliases}};
        my $route = $post->{local_href};
        Trog::SQLite::bulk_insert($dbh, 'post_aliases', [qw{route_id alias}], 'IGNORE', map { ($routes_actual{$route}{id}, $_) } @{$post->{aliases}} );
    }
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/flatfile.schema';
    my $dbname = "data/posts.db";
    return Trog::SQLite::dbh($file,$dbname);
}

1;
