#!/usr/bin/perl

#Migrate tCMS1 data to tCMS2 flat file data model

use strict;
use warnings;

use JSON::MaybeXS;
use File::Slurper();
use HTML::Parser;
use UUID::Tiny ':std';
use File::Copy;
use DateTime;

#Edit this to be whatever you need it to be
my $docroot = "/var/www/teodesian.net/doc";

my $dir = "/var/www/teodesian.net/doc/microblog/";

opendir(my $dh, $dir) or die;
my @days = grep { !/^\./ } readdir $dh;
closedir $dh;

my $ring = JSON::MaybeXS->new();
foreach my $day (@days) {

    opendir(my $dht, "$dir/$day") or die;
    my @times = grep { !/^\./ } readdir $dht;
    closedir $dht;

    my ($month,$date,$year) = split(/\./,$day);

    foreach my $time (@times) {

        my ($hour, $min, $sec) = split(/:/,$time);

        my $data;
        my $file = "$dir/$day/$time";

        print "Migrate $file\n";
        eval {
            my $content = File::Slurper::read_text($file);
            $data = $ring->decode($content);
            $data = json_remap($data);
        };
        $data = html_post($file) unless $data;

        my $dt = DateTime->new(
            year       => $year + 2000,
            month      => $month,
            day        => $date,
            hour       => $hour,
            minute     => $min,
            second     => $sec,
        );
        $data->{created} = $dt->epoch();

        $data->{id} = $data->{created};
        $data->{tags} = ['public','news'];
        $data->{version} = 0;

        open(my $fh, '>', "data/files/$data->{created}") or die;
        print $fh encode_json([$data]);
        close $fh;
    }
}

# Migrate blog posts
$dir = "$docroot/blog";

opendir(my $bh, $dir) or die;
my @blogs = grep { -f "$dir/$_" } readdir $bh;
closedir $bh;

my $offset = 0;

foreach my $post ( sort {
    my $anum = $a =~ m/^(\d*)-/;
    my $bnum = $b =~ m/^(\d*)-/;
    $b <=> $a
  }  @blogs) {
    my $postname = $post;
    $postname =~ s/^\d*-//g;
    $postname =~ s/\.post$//g;
    my $content = File::Slurper::read_text("$dir/$post");

    my $data = {
        title => $postname,
        data  => $content,
        tags  => ['blog','public'],
    };

    my (undef, undef, undef, undef, $uid, undef, undef, undef, undef, $ctime) = stat("$dir/$post");
    my $user = lc(getpwuid($uid));
    $user = scalar(grep { $user eq $_ } qw{/sbin/nologin www-data}) ? 'nobody' : $user;
    $data->{user} = $user;
    $ctime += $offset;
    $data->{created} = $ctime;
    $data->{id} = $ctime;
    $data->{href} = "/blog/$ctime";
    $data->{version} = 0;

    print "Migrate blog post '$post'\n";
    open(my $fh, '>', "data/files/$data->{created}") or die;
    print $fh encode_json([$data]);
    close $fh;

    $offset--;
}
exit 0;
my $vdir = "$docroot/fileshare/video";
opendir(my $vh, $vdir) or die;
my @vidyas = grep { -f "$vdir/$_" && $_ =~ m/\.m4v$/ } readdir $vh;
closedir $vh;

foreach my $vid ( @vidyas ) {
    my $postname = $vid;
    $postname =~ s/_/ /g;
    $postname =~ s/\.mv4$//g;

    my $data = {
        title => $postname,
        data  => "Description forthcoming",
        tags  => ['video','public'],
        preview => "/img/sys/testpattern.jpg",
    };

    my (undef, undef, undef, undef, $uid, undef, undef, undef, undef, $ctime) = stat("$vdir/$vid");
    my $user = lc(getpwuid($uid));
    $user = scalar(grep { $user eq $_ } qw{/sbin/nologin www-data}) ? 'nobody' : $user;
    $data->{user} = $user;
    $data->{created} = $ctime;
    $data->{id} = $ctime;
    $data->{href} = "/assets/$ctime-$vid";
    $data->{version} = 0;

    #Copy over the video
    File::Copy::copy("$vdir/$vid","www/assets/$ctime-$vid");

    print "Migrate video '$vid'\n";
    open(my $fh, '>', "data/files/$data->{created}") or die;
    print $fh encode_json([$data]);
    close $fh;
}

sub json_remap {
    my $json = shift;

    return {
       preview => $json->{"image"},
       data       => $json->{"comment"},
       user       => lc($json->{"poster"}),
       title      => $json->{"title"},
       audio_href => $json->{"audio"},
       href       => $json->{"url"},
       video_href => $json->{"video"},
    };
}

sub html_post {
    my $file = shift;
    my $is_first_link=1;
    my $data = { data => '', href => '' };

    my $p = HTML::Parser->new(
        handlers => [
            start => [
                sub {
                    my ($self,$attr,$text,$tagname) = @_;
                    if ( $tagname eq 'a' && $is_first_link) {
                        $data->{href} = $attr->{href};
                        return;
                    }
                    return if $is_first_link;
                    return if $tagname eq 'hr';
                    $data->{data} .= $text;
                },
                'self, attr, text,tagname'
            ],
            text  => [
                sub {
                    my ($self,$attr,$text,$tagname) = @_;
                    if ($is_first_link) {
                        $data->{title} .= $text;
                        return;
                    }
                    $data->{data} .= $text;
                },
                'self, attr, text,tagname'
            ],
            end   => [
                sub {
                    my ($self,$attr,$text,$tagname) = @_;
                    if ( $tagname eq 'a' && $is_first_link) {
                        $is_first_link=0;
                        return;
                    }
                    return if $is_first_link;
                    $data->{data} .= $text;
                },
                'self, attr, text,tagname'
            ],
        ],
    );
    $p->parse_file($file);

    #Get the user name from ownership
    my (undef, undef, undef, undef, $uid, undef, undef, undef, undef, $ctime) = stat($file);
    my $user = lc(getpwuid($uid));
    $user = scalar(grep { $user eq $_ } qw{/sbin/nologin www-data}) ? 'nobody' : $user;
    $data->{user} = $user;

    $data->{created} = $ctime;

    return $data;
}
