use warnings;
use strict;
use Test::More tests => 7;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;

BEGIN {
    use_ok('Gscan2pdf::Dialog::MultipleMessage');
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
my $window = Gtk3::Window->new;

ok(
    my $dialog = Gscan2pdf::Dialog::MultipleMessage->new(
        title           => 'title',
        'transient-for' => $window
    ),
    'Created dialog'
);
isa_ok( $dialog, 'Gscan2pdf::Dialog::MultipleMessage' );

$dialog->add_message(
    page             => 1,
    process          => 'scan',
    type             => 'error',
    text             => 'message',
    'store-response' => TRUE
);
is( $dialog->{grid_rows}, 2, '1 message' );

$dialog->add_message(
    page    => 2,
    process => 'scan',
    type    => 'warning',
    text    => 'message2'
);
is( $dialog->{grid_rows}, 3, '2 messages' );

$dialog->{grid}->get_child_at( 4, 1 )->set_active(TRUE);
is_deeply( [ $dialog->list_messages_to_ignore('ok') ],
    ['message'], 'list_messages_to_ignore' );

$dialog->add_message(
    page             => 1,
    process          => 'scan',
    type             => 'error',
    text             => "my message3\n",
    'store-response' => TRUE
);
$dialog->{grid}->get_child_at( 4, 3 )->set_active(TRUE);
is_deeply(
    [ $dialog->list_messages_to_ignore('ok') ],
    [ 'message', 'my message3' ],
    'chop trailing whitespace'
);

__END__
