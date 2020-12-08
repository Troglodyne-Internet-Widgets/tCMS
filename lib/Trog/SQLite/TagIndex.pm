package Trog::SQLite::TagIndex;

use strict;
use warnings;

no warnings 'experimental';
use feature qw{signatures};

use List::Util qw{uniq};
use Trog::SQLite;

=head1 Trog::SQLite::TagIndex

An SQLite3 index of posts by tag.
Used to speed up the flat-file data model.

=head1 FUNCTIONS

=cut

sub posts_for_tags ($limit=0, @tags) {
    my $dbh = _dbh();
    my $clause = @tags ? "WHERE tag IN (".join(',' ,(map {'?'} @tags)).")" : '';
    if ($limit) {
        $clause .= "LIMIT ?";
        push(@tags,$limit);
    }
    my $rows = $dbh->selectall_arrayref("SELECT id FROM posts $clause",{ Slice => {} }, @tags);
    return () unless ref $rows eq 'ARRAY' && @$rows;
    return map { $_->{id} } @$rows;
}

sub add_post ($post,$data_obj) {
    my $dbh = _dbh();
    return build_index($data_obj,[$post]);
}

sub remove_post ($post) {
    my $dbh = _dbh();
    return $dbh->do("DELETE FROM posts_index WHERE post_id=?", undef, $post->{id});
}

sub build_index($data_obj,$posts=[]) {
    my $dbh = _dbh();
    $posts = $data_obj->read({ limit => 0, acls => ['admin'] }) unless @$posts;

    my @tags = uniq map { @{$_->{tags}} } @$posts;
    Trog::SQLite::bulk_insert($dbh,'tag', ['name'], 'IGNORE', @tags); 
    my $t = $dbh->selectall_hashref("SELECT id,name FROM tag", 'name');
    foreach my $k (keys(%$t)) { $t->{$k} = $t->{$k}->{id} };

    Trog::SQLite::bulk_insert($dbh,'posts_index',[qw{post_id tag_id}], 'IGNORE', map {
        my $subj = $_;
        map { ( $subj->{id}, $t->{$_} ) } @{$subj->{tags}}
    } @$posts );
}

# Ensure the db schema is OK, and give us a handle
sub _dbh {
    my $file   = 'schema/flatfile.schema';
    my $dbname = "data/posts.db";
    return Trog::SQLite::dbh($file,$dbname);
}

1;
