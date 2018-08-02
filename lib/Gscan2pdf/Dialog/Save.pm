package Gscan2pdf::Dialog::Save;

use warnings;
use strict;
use Glib 1.220 qw(TRUE FALSE);      # To get TRUE and FALSE
use Gscan2pdf::Dialog;
use Gscan2pdf::Document;
use Gscan2pdf::EntryCompletion;
use Gscan2pdf::Translation '__';    # easier to extract strings with xgettext
use Date::Calc qw(Today Today_and_Now);
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Readonly;
Readonly my $ENTRY_WIDTH_DATE     => 10;
Readonly my $ENTRY_WIDTH_DATETIME => 19;

our $VERSION = '2.1.4';
my $EMPTY           = q{};
my $DATE_FORMAT     = '%04d-%02d-%02d';
my $DATETIME_FORMAT = '%04d-%02d-%02d %02d:%02d:%02d';

use Glib::Object::Subclass Gscan2pdf::Dialog::, properties => [
    Glib::ParamSpec->scalar(
        'meta-datetime',                             # name
        'Array of datetime metadata',                # nick
        'Year, month, day, hour, minute, second',    # blurb
        [qw/readable writable/]                      # flags
    ),
    Glib::ParamSpec->boolean(
        'select-datetime',                                  # name
        'Select datetime',                                  # nickname
        'TRUE = show datetime entry, FALSE = now/today',    # blurb
        FALSE,                                              # default
        [qw/readable writable/]                             # flags
    ),
    Glib::ParamSpec->boolean(
        'include-time',                                     # name
        'Specify the time as well as date',                 # nickname
        'Whether to allow the time, as well as the date, to be entered', # blurb
        FALSE,                     # default
        [qw/readable writable/]    # flags
    ),
    Glib::ParamSpec->string(
        'meta-title',              # name
        'Title metadata',          # nick
        'Title metadata',          # blurb
        $EMPTY,                    # default
        [qw/readable writable/]    # flags
    ),
    Glib::ParamSpec->scalar(
        'meta-title-suggestions',                 # name
        'Array of title metadata suggestions',    # nick
        'Used by entry completion widget',        # blurb
        [qw/readable writable/]                   # flags
    ),
    Glib::ParamSpec->string(
        'meta-author',                            # name
        'Author metadata',                        # nick
        'Author metadata',                        # blurb
        $EMPTY,                                   # default
        [qw/readable writable/]                   # flags
    ),
    Glib::ParamSpec->scalar(
        'meta-author-suggestions',                 # name
        'Array of author metadata suggestions',    # nick
        'Used by entry completion widget',         # blurb
        [qw/readable writable/]                    # flags
    ),
    Glib::ParamSpec->string(
        'meta-subject',                            # name
        'Subject metadata',                        # nick
        'Subject metadata',                        # blurb
        $EMPTY,                                    # default
        [qw/readable writable/]                    # flags
    ),
    Glib::ParamSpec->scalar(
        'meta-subject-suggestions',                 # name
        'Array of subject metadata suggestions',    # nick
        'Used by entry completion widget',          # blurb
        [qw/readable writable/]                     # flags
    ),
    Glib::ParamSpec->string(
        'meta-keywords',                            # name
        'Keyword metadata',                         # nick
        'Keyword metadata',                         # blurb
        $EMPTY,                                     # default
        [qw/readable writable/]                     # flags
    ),
    Glib::ParamSpec->scalar(
        'meta-keywords-suggestions',                # name
        'Array of keyword metadata suggestions',    # nick
        'Used by entry completion widget',          # blurb
        [qw/readable writable/]                     # flags
    ),
];

sub SET_PROPERTY {
    my ( $self, $pspec, $newval ) = @_;
    my $name = $pspec->get_name;
    $self->{$name} = $newval;
    if ( $name eq 'border_width' ) {
        $self->get('vbox')->set( 'border-width', $newval );
    }
    elsif ( $name eq 'include_time' ) {
        $self->on_toggle_include_time($newval);
    }
    elsif ( $name =~ /^meta_([^_]+)(_suggestions)?$/xsm ) {
        my $key = $1;
        if ( defined $self->{"meta-$key-widget"} ) {
            if ( defined $2 ) {
                $self->{"meta-$key-widget"}->add_to_suggestions($newval);
            }
            else {
                if ( $key eq 'datetime' ) {
                    $newval = $self->datetime2string( @{$newval} );
                }
                $self->{"meta-$key-widget"}->set_text($newval);
            }
        }
    }
    return;
}

sub GET_PROPERTY {
    my ( $self, $pspec ) = @_;
    my $name = $pspec->get_name;
    if ( $name =~ /^meta_([^_]+)(_suggestions)?$/xsm ) {
        my $key = $1;
        if ( defined $self->{"meta-$key-widget"} ) {
            if ( defined $2 ) {
                $self->{$name} = $self->{"meta-$key-widget"}->get_suggestions;
            }
            else {
                $self->{$name} = $self->{"meta-$key-widget"}->get_text;
                if ( $key eq 'datetime' ) {
                    if ( $self->{'meta-now-widget'}->get_active ) {
                        $self->{$name} = [ Today_and_Now() ];
                    }
                    elsif ( defined $self->{$name}
                        and $self->{$name} ne $EMPTY )
                    {
                        $self->{$name} = [
                            Gscan2pdf::Document::text_to_datetime(
                                $self->{$name}
                            )
                        ];
                    }
                }
                elsif ( $self->{$name} ne $EMPTY ) {
                    $self->{"meta-$key-widget"}
                      ->add_to_suggestions( [ $self->{$name} ] );
                }
            }
        }
    }
    return $self->{$name};
}

sub on_toggle_include_time {
    my ( $self, $newval ) = @_;
    if ( defined $self->{mdwidgets} ) {
        if ($newval) {
            $self->{'meta-now-widget'}->get_child->set_text( __('Now') );
            $self->{'meta-now-widget'}
              ->set_tooltip_text( __('Use current date and time') );
            $self->{'meta-datetime-widget'}
              ->set_max_length($ENTRY_WIDTH_DATETIME);
            $self->{'meta-datetime-widget'}->set_text(
                $self->{'meta-datetime-widget'}->get_text . ' 00:00:00' );
        }
        else {
            $self->{'meta-now-widget'}->get_child->set_text( __('Today') );
            $self->{'meta-now-widget'}
              ->set_tooltip_text( __("Use today's date") );
            $self->{'meta-datetime-widget'}->set_max_length($ENTRY_WIDTH_DATE);
        }
    }
    return;
}

sub add_metadata {
    my ( $self, $defaults ) = @_;
    my ($vbox) = $self->get('vbox');

    # it needs its own box to be able to hide it if necessary
    my $hboxmd = Gtk3::HBox->new;
    $vbox->pack_start( $hboxmd, FALSE, FALSE, 0 );

    # Frame for metadata
    my $frame = Gtk3::Frame->new( __('Document Metadata') );
    $hboxmd->pack_start( $frame, TRUE, TRUE, 0 );
    my $hboxm = Gtk3::VBox->new;
    $hboxm->set_border_width( $self->get('border-width') );
    $frame->add($hboxm);

    # grid to align widgets
    my $grid = Gtk3::Grid->new;
    my $row  = 0;
    $hboxm->pack_start( $grid, TRUE, TRUE, 0 );

    # Date/time
    my $dtframe = Gtk3::Frame->new( __('Date/Time') );
    $grid->attach( $dtframe, 0, $row++, 2, 1 );
    $dtframe->set_hexpand(TRUE);
    my $vboxdt = Gtk3::VBox->new;
    $vboxdt->set_border_width( $self->get('border-width') );
    $dtframe->add($vboxdt);

    # the first radio button has to set the group,
    # which is undef for the first button
    # Now button
    $self->{'meta-now-widget'} =
      Gtk3::RadioButton->new_with_label( undef, __('Now') );
    $self->{'meta-now-widget'}
      ->set_tooltip_text( __('Use current date and time') );
    $vboxdt->pack_start( $self->{'meta-now-widget'}, TRUE, TRUE, 0 );

    # Specify button
    my $bspecify_dt =
      Gtk3::RadioButton->new_with_label_from_widget( $self->{'meta-now-widget'},
        __('Specify') );
    $bspecify_dt->set_tooltip_text( __('Specify date and time') );
    $vboxdt->pack_start( $bspecify_dt, TRUE, TRUE, 0 );
    my $hboxe = Gtk3::HBox->new;
    $bspecify_dt->signal_connect(
        clicked => sub {
            if ( $bspecify_dt->get_active ) {
                $hboxe->show;
                $self->set( 'select-datetime', TRUE );
            }
            else {
                $hboxe->hide;
                $self->set( 'select-datetime', FALSE );
            }
        }
    );

    my $datetime = $self->get('meta-datetime');
    $self->{'meta-datetime-widget'} = Gtk3::Entry->new;
    if ( defined $datetime and $datetime ne $EMPTY ) {
        $self->{'meta-datetime-widget'}
          ->set_text( $self->datetime2string( @{$datetime} ) );
    }
    $self->{'meta-datetime-widget'}->set_activates_default(TRUE);
    $self->{'meta-datetime-widget'}->set_tooltip_text( __('Year-Month-Day') );
    $self->{'meta-datetime-widget'}->set_alignment(1.);    # Right justify
    $self->{'meta-datetime-widget'}
      ->signal_connect( 'insert-text' => \&insert_text_handler, $self );
    $self->{'meta-datetime-widget'}->signal_connect(
        'focus-out-event' => sub {
            my $text = $self->{'meta-datetime-widget'}->get_text;
            if ( defined $text and $text ne $EMPTY ) {
                $self->{'meta-datetime-widget'}->set_text(
                    $self->datetime2string(
                        Gscan2pdf::Document::text_to_datetime($text)
                    )
                );
            }
            return FALSE;
        }
    );
    my $button = Gtk3::Button->new;
    $button->set_image( Gtk3::Image->new_from_stock( 'gtk-edit', 'button' ) );
    $button->signal_connect(
        clicked => sub {
            my $window_date = Gscan2pdf::Dialog->new(
                'transient-for' => $self,
                title           => __('Select Date'),
                border_width    => $self->get('border-width')
            );
            my $vbox_date = $window_date->get('vbox');
            $window_date->set_resizable(FALSE);
            my $calendar = Gtk3::Calendar->new;

            # Editing the entry and clicking the edit button bypasses the
            # focus-out-event, so update the date now
            my ( $year, $month, $day, $hour, $min, $sec ) =
              Gscan2pdf::Document::text_to_datetime(
                $self->{'meta-datetime-widget'}->get_text );

            $calendar->select_day($day);
            $calendar->select_month( $month - 1, $year );
            my $calendar_s;
            $calendar_s = $calendar->signal_connect(
                day_selected => sub {
                    ( $year, $month, $day ) = $calendar->get_date;
                    $month += 1;
                    $self->{'meta-datetime-widget'}->set_text(
                        $self->datetime2string(
                            $year, $month, $day, $hour, $min, $sec
                        )
                    );
                }
            );
            $calendar->signal_connect(
                day_selected_double_click => sub {
                    ( $year, $month, $day ) = $calendar->get_date;
                    $month += 1;
                    $self->{'meta-datetime-widget'}->set_text(
                        $self->datetime2string(
                            $year, $month, $day, $hour, $min, $sec
                        )
                    );
                    $window_date->destroy;
                }
            );
            $vbox_date->pack_start( $calendar, TRUE, TRUE, 0 );

            my $today = Gtk3::Button->new( __('Today') );
            $today->signal_connect(
                clicked => sub {
                    ( $year, $month, $day ) = Today();

                    # block and unblock signal, and update entry manually
                    # to remove possibility of race conditions
                    $calendar->signal_handler_block($calendar_s);
                    $calendar->select_day($day);
                    $calendar->select_month( $month - 1, $year );
                    $calendar->signal_handler_unblock($calendar_s);
                    $self->{'meta-datetime-widget'}->set_text(
                        $self->datetime2string(
                            $year, $month, $day, $hour, $min, $sec
                        )
                    );
                }
            );
            $vbox_date->pack_start( $today, TRUE, TRUE, 0 );

            $window_date->show_all;
        }
    );
    $button->set_tooltip_text( __('Select date with calendar') );
    $vboxdt->pack_start( $hboxe, TRUE, TRUE, 0 );
    $hboxe->pack_end( $button,                         FALSE, FALSE, 0 );
    $hboxe->pack_end( $self->{'meta-datetime-widget'}, FALSE, FALSE, 0 );

    # Don't show these widgets when the window is shown
    $hboxe->set_no_show_all(TRUE);
    $self->{'meta-datetime-widget'}->show;
    $button->show;
    $bspecify_dt->set_active( $self->get('select-datetime') );

    my @label = (
        { title    => __('Title') },
        { author   => __('Author') },
        { subject  => __('Subject') },
        { keywords => __('Keywords') },
    );
    my %widgets = ( box => $hboxmd, );
    for my $entry (@label) {
        my ( $name, $label ) = %{$entry};
        my $hbox = Gtk3::HBox->new;
        $grid->attach( $hbox, 0, $row, 1, 1 );
        $label = Gtk3::Label->new($label);
        $hbox->pack_start( $label, FALSE, TRUE, 0 );
        $hbox = Gtk3::HBox->new;
        $grid->attach( $hbox, 1, $row++, 1, 1 );
        $self->{"meta-$name-widget"} =
          Gscan2pdf::EntryCompletion->new( $self->get("meta-$name"),
            $self->get("meta-$name-suggestions") );
        $hbox->pack_start( $self->{"meta-$name-widget"}, TRUE, TRUE, 0 );
    }
    $self->{mdwidgets} = \%widgets;
    $self->on_toggle_include_time( $self->get('include-time') );
    return;
}

# helper function to return correctly formatted date or datetime string
sub datetime2string {
    my ( $self, @datetime ) = @_;
    return $self->get('include-time')
      ? sprintf $DATETIME_FORMAT, @datetime
      : sprintf $DATE_FORMAT, @datetime[ 0 .. 2 ];
}

sub insert_text_handler {
    my ( $widget, $string, $len, $position, $self ) = @_;

    # only allow integers and -
    if (
        ( not $self->get('include-time') and $string =~ /^[\d\-]+$/smx )
        or

        # only allow integers, space, : and -
        ( $self->get('include-time') and $string =~ /^[\d\- :]+$/smx )
      )
    {
        $widget->signal_handlers_block_by_func( \&insert_text_handler );
        $widget->insert_text( $string, $len, $position++ );
        $widget->signal_handlers_unblock_by_func( \&insert_text_handler );
    }
    $widget->signal_stop_emission_by_name('insert-text');
    return $position;
}

sub dump_or_stringify {
    my ($val) = @_;
    return (
        defined $val
        ? ( ref($val) eq $EMPTY ? $val : Dumper($val) )
        : 'undef'
    );
}

1;

__END__
