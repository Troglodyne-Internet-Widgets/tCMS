package Trog::Email;

use strict;
use warnings;

no warnings qw{experimental};
use feature qw{signatures};

use Email::MIME;
use Email::Sender::Simple;

use Trog::Auth;
use Trog::Log qw{:all};
use Trog::Renderer;

sub contact ( $user, $from, $subject, $data ) {
    my $email = Trog::Auth::email4user($user);
    die "No contact email set for user $user!" unless $email;

    my $render = Trog::Renderer->render(
        contenttype => 'multipart/related',
        code        => 200,
        template    => $data->{template},
        data        => {
            method => 'EMAIL',

            # Important - this will prevent caching
            route => '',
            %$data,
        },
    );

    my $text = $render->{text}[2][0];
    my $html = $render->{html}[2][0];

    my @parts = (
        Email::MIME->create(
            attributes => {
                content_type => "text/plain",
                disposition  => "attachment",
                charset      => 'UTF-8',
            },
            body => $text,
        ),
        Email::MIME->create(
            attributes => {
                content_type => "text/html",
                disposition  => "attachment",
                charset      => "UTF-8",
            },
            body => $html,
        ),
    );

    my $mail = Email::MIME->create(
        header_str => [
            From    => $from,
            To      => [$email],
            Subject => $subject,
        ],
        parts => \@parts,
    );

    Email::Sender::Simple->try_to_send($mail) or do {
        FATAL("Could not send email from $from to $email!");
    };
    return 1;
}

1;
