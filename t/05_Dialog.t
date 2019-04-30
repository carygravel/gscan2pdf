use warnings;
use strict;
use Test::More tests => 20;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;
use Scalar::Util;

BEGIN {
    use_ok('Gscan2pdf::Dialog');
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
my $window = Gtk3::Window->new;

ok(
    my $dialog =
      Gscan2pdf::Dialog->new( title => 'title', 'transient-for' => $window ),
    'Created dialog'
);
isa_ok( $dialog, 'Gscan2pdf::Dialog' );

is( $dialog->get('title'),         'title', 'title' );
is( $dialog->get('transient-for'), $window, 'transient-for' );
ok( $dialog->get('hide-on-delete') == FALSE, 'default destroy' );
is( $dialog->get('page-range'), 'selected', 'default page-range' );

$dialog = Gscan2pdf::Dialog->new;
$dialog->signal_emit( 'delete_event', undef );
Scalar::Util::weaken($dialog);
is( $dialog, undef, 'destroyed on delete_event' );

$dialog = Gscan2pdf::Dialog->new( 'hide-on-delete' => TRUE );
$dialog->signal_emit( 'delete_event', undef );
Scalar::Util::weaken($dialog);
isnt( $dialog, undef, 'hidden on delete_event' );

$dialog = Gscan2pdf::Dialog->new;
my $event = Gtk3::Gdk::Event->new('key-press');
$event->keyval(Gtk3::Gdk::KEY_Escape);
$dialog->signal_emit( 'key_press_event', $event );
Scalar::Util::weaken($dialog);
is( $dialog, undef, 'destroyed on escape' );

$dialog = Gscan2pdf::Dialog->new( 'hide-on-delete' => TRUE );
$dialog->signal_emit( 'key_press_event', $event );
Scalar::Util::weaken($dialog);
isnt( $dialog, undef, 'hidden on escape' );

$dialog = Gscan2pdf::Dialog->new;
$dialog->signal_connect_after(
    key_press_event => sub {
        my ( $widget, $event ) = @_;
        is( $event->keyval, Gtk3::Gdk::KEY_Delete,
            'other key press events still propagate' );
    }
);
$event = Gtk3::Gdk::Event->new('key-press');
$event->keyval(Gtk3::Gdk::KEY_Delete);
$dialog->signal_emit( 'key_press_event', $event );

is_deeply(
    Gscan2pdf::Dialog::munge_message(
            "(gimp:26514): GLib-GObject-WARNING : g_object_set_valist: "
          . "object class 'GeglConfig' has no property named 'cache-size'\n"
          . "(gimp:26514): GEGL-gegl-operation.c-WARNING : Cannot change name of operation class 0xE0FD30 from \"gimp:point-layer-mode\" to \"gimp:dissolve-mode\""
    ),
    [
"(gimp:26514): GLib-GObject-WARNING : g_object_set_valist: object class 'GeglConfig' has no property named 'cache-size'",
'(gimp:26514): GEGL-gegl-operation.c-WARNING : Cannot change name of operation class 0xE0FD30 from "gimp:point-layer-mode" to "gimp:dissolve-mode"'
    ],
    'split gimp messages'
);

is_deeply(
    Gscan2pdf::Dialog::munge_message(
'[image2 @ 0xc596e0] Using AVStream.codec to pass codec parameters to muxers is deprecated, use AVStream.codecpar instead.'
          . "\n"
          . '[image2 @ 0x1338180] Encoder did not produce proper pts, making some up.'
          . "\n"
    ),
    [
'[image2 @ 0xc596e0] Using AVStream.codec to pass codec parameters to muxers is deprecated, use AVStream.codecpar instead.',
'[image2 @ 0x1338180] Encoder did not produce proper pts, making some up.'
    ],
    'split unpaper messages'
);

is_deeply(
    Gscan2pdf::Dialog::munge_message('Exception 400: memory allocation failed'),
    "Exception 400: memory allocation failed"
      . "\n\nThis error is normally due to ImageMagick "
      . 'exceeding its resource limits. These can be extended by '
      . 'editing its policy file, which on my system is found at '
      . '/etc/ImageMagick-6/policy.xml Please see '
      . 'https://imagemagick.org/script/resources.php for more '
      . 'information',
    'extend imagemagick Exception 400'
);

is(
    Gscan2pdf::Dialog::filter_message(
'[image2 @ 0x1338180] Encoder did not produce proper pts, making some up.'
    ),
    '[image2 @ %%x] Encoder did not produce proper pts, making some up.',
    'Filter out memory address from unpaper warning'
);

is(
    Gscan2pdf::Dialog::filter_message(
'[image2 @ 0xc596e0] Using AVStream.codec to pass codec parameters to muxers is deprecated, use AVStream.codecpar instead.'
          . "\n"
          . '[image2 @ 0x1338180] Encoder did not produce proper pts, making some up.'
    ),
'[image2 @ %%x] Using AVStream.codec to pass codec parameters to muxers is deprecated, use AVStream.codecpar instead.'
      . "\n"
      . '[image2 @ %%x] Encoder did not produce proper pts, making some up.',
    'Filter out double memory address from unpaper warning'
);

is(
    Gscan2pdf::Dialog::filter_message(
        'Error processing with tesseract: Detected 440 diacritics'
    ),
    'Error processing with tesseract: Detected %%d diacritics',
    'Filter out integer from tesseract warning'
);

is(
    Gscan2pdf::Dialog::filter_message(
'Error processing with tesseract: Warning. Invalid resolution 0 dpi. Using 70 instead.'
    ),
'Error processing with tesseract: Warning. Invalid resolution %%d dpi. Using %%d instead.',
    'Filter out 1 and 2 digit integers from tesseract warning'
);

is(
    Gscan2pdf::Dialog::filter_message(
"[image2 @ 0x1338180] Encoder did not produce proper pts, making some up. \n "
    ),
    '[image2 @ %%x] Encoder did not produce proper pts, making some up.',
    'Filter out trailing whitespace'
);

__END__
