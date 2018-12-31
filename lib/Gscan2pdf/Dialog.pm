package Gscan2pdf::Dialog;

use warnings;
use strict;
use Gtk3;
use Glib 1.220 qw(TRUE FALSE);      # To get TRUE and FALSE
use Gscan2pdf::PageRange;
use Gscan2pdf::Translation '__';    # easier to extract strings with xgettext
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use Glib::Object::Subclass Gtk3::Dialog::,
  signals => {
    delete_event    => \&on_delete_event,
    key_press_event => \&on_key_press_event,
  },
  properties => [
    Glib::ParamSpec->boolean(
        'hide-on-delete',                                             # name
        'Hide on delete',                                             # nickname
        'Whether to destroy or hide the dialog when it is dismissed', # blurb
        FALSE,                                                        # default
        [qw/readable writable/]                                       # flags
    ),
    Glib::ParamSpec->enum(
        'page-range',                                                 # name
        'page-range',                                                 # nickname
        'Either selected or all',                                     # blurb
        'Gscan2pdf::PageRange::Range',
        'selected',                                                   # default
        [qw/readable writable/]                                       # flags
    ),
  ];

our $VERSION = '2.2.2';
my $EMPTY    = q{};
my $HEXREGEX = qr{^(.*)           # start of message
                  \b0x[[:xdigit:]]+\b # hex (e.g. address)
                  (.*)$           # rest of message
                 }xsm;
my $INTREGEX = qr{^(.*)           # start of message
                  \b[[:digit:]]+\b # integer
                  (.*)$           # rest of message
                 }xsm;

sub INIT_INSTANCE {
    my $self = shift;
    $self->set_position('center-on-parent');
    return $self;
}

sub on_delete_event {
    my ( $widget, $event ) = @_;
    if ( $widget->get('hide-on-delete') ) {
        $widget->hide;
        return Gtk3::EVENT_STOP;    # ensures that the window is not destroyed
    }
    $widget->destroy;
    return Gtk3::EVENT_PROPAGATE;
}

sub on_key_press_event {
    my ( $widget, $event ) = @_;
    if ( $event->keyval != Gtk3::Gdk::KEY_Escape ) {
        $widget->signal_chain_from_overridden($event);
        return Gtk3::EVENT_PROPAGATE;
    }
    if ( $widget->get('hide-on-delete') ) {
        $widget->hide;
    }
    else {
        $widget->destroy;
    }
    return Gtk3::EVENT_STOP;
}

# Add a frame and radio buttons to $vbox,
sub add_page_range {
    my ($self) = @_;
    my $frame = Gtk3::Frame->new( __('Page Range') );
    $self->get_content_area->pack_start( $frame, FALSE, FALSE, 0 );

    my $pr = Gscan2pdf::PageRange->new;
    $pr->set_active( $self->get('page-range') );
    $pr->signal_connect(
        changed => sub {
            $self->set( 'page-range', $pr->get_active );
        }
    );
    $frame->add($pr);
    return;
}

# Add buttons and link up their actions
sub add_actions {
    my ( $self, $button1, $callback1, $button2, $callback2 ) = @_;
    if ( defined $button2 ) {
        $self->add_buttons( $button1 => 'ok', $button2 => 'cancel' );
    }
    else {
        $self->add_buttons( $button1 => 'ok' );
    }
    $self->set_default_response('ok');
    $self->signal_connect(
        response => sub {
            my ( $widget, $response ) = @_;
            if ( $response eq 'ok' ) {
                $callback1->();
            }
            elsif ( defined $callback2 ) {
                $callback2->();
            }
        }
    );
    return;
}

sub dump_or_stringify {
    my ($val) = @_;
    return (
        defined $val
        ? ( ref($val) eq $EMPTY ? $val : Dumper($val) )
        : 'undef'
    );
}

# External tools sometimes throws warning messages including a number,
# e.g. hex address. As the number is very rarely the same, although the message
# itself is, filter out the number from the message

sub filter_message {
    my ($message) = @_;
    $message =~ s/\s+$//xsm;
    while ( $message =~ /$HEXREGEX/xsmo ) {
        $message =~ s/$HEXREGEX/$1%%x$2/xsmo;
    }
    while ( $message =~ /$INTREGEX/xsmo ) {
        $message =~ s/$INTREGEX/$1%%d$2/xsmo;
    }
    return $message;
}

1;

__END__
