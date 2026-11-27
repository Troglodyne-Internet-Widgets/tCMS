package Trog::Email;

# ABSTRACT: Send templated mail to the users of tCMS

use 5.040;
use re '/aasx';
use warnings FATAL => 'all';

use Email::MIME;
use Email::Sender::Simple;

use Trog::Auth;
use Trog::Log qw{:all};
use Trog::Renderer;

=head1 Trog::Email

Sending mail out of tCMS.

=head1 Termination Conditions

Dies when asked to mail a user who has no contact email set on their profile.
Failure to actually send is logged as FATAL rather than thrown, as by then the
message has already been built and there is nothing the caller can do about it.

=head1 FUNCTIONS

=head2 contact($user, $from, $subject, $data)

Send a templated message to the contact email of a user.

The template is rendered twice, once as text and once as HTML, and both are
attached to a multipart message, so that the client of the recipient can pick
whichever it prefers.

=over 4

=item user - Str - the name of the user to mail

=item from - Str - the address that the mail comes from

=item subject - Str - the subject of the mail

=item data - HashRef - its key C<template> names the template to render.
Everything in it, C<template> too, is passed through to that template as its
data.

=back

Returns 1, also when the mail could not be sent.  That failure is logged as
FATAL.

Dies when the user has no contact email.

    Trog::Email::contact(
        $user,
        "root\@$domain",
        "$domain: Password reset URL for $user",
        { uri => "https://$domain/auth_change_request/$token", template => 'password_reset.tx' }
    );

=cut

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
