package Gscan2pdf::Dialog::MultipleMessage;

use warnings;
use strict;
use Gtk3;
use Glib 1.220 qw(TRUE FALSE);      # To get TRUE and FALSE
use Gscan2pdf::Translation '__';    # easier to extract strings with xgettext
use Gscan2pdf::Dialog;
use Glib::Object::Subclass Gscan2pdf::Dialog::;
use Readonly;
Readonly my $COL_MESSAGE  => 3;
Readonly my $COL_CHECKBOX => 4;

my %types;

our $VERSION = '2.5.1';

sub INIT_INSTANCE {
    my $self = shift;
    %types = (
        error   => __('Error'),
        warning => __('Warning'),
    );
    $self->set_position('center-on-parent');
    my $vbox = $self->get_content_area;
    $self->{grid}             = Gtk3::Grid->new;
    $self->{grid_rows}        = 0;
    $self->{stored_responses} = [];
    $self->{grid}
      ->attach( Gtk3::Label->new( __('Page') ), 0, $self->{grid_rows}, 1, 1 );
    $self->{grid}
      ->attach( Gtk3::Label->new( __('Process') ), 1, $self->{grid_rows}, 1,
        1 );
    $self->{grid}->attach( Gtk3::Label->new( __('Message type') ),
        2, $self->{grid_rows}, 1, 1 );
    $self->{grid}->attach(
        Gtk3::Label->new( __('Message') ),
        $COL_MESSAGE, $self->{grid_rows}++,
        1, 1
    );
    $vbox->pack_start( $self->{grid}, TRUE, TRUE, 0 );
    $self->{cb} =
      Gtk3::CheckButton->new_with_label( __("Don't show this message again") );
    $self->{cb}->signal_connect(
        toggled => sub {

            if ( $self->{cb}->get_active ) {
                for my $cb ( $self->_list_checkboxes ) {
                    $cb->set_active(TRUE);
                }
            }
        }
    );

    $vbox->pack_start( $self->{cb}, TRUE, TRUE, 0 );
    $self->add_actions( 'gtk-close', \&close_callback );
    return $self;
}

sub add_message {
    my ( $self, %options ) = @_;
    $self->{grid}->attach( Gtk3::Label->new( $options{page} ),
        0, $self->{grid_rows}, 1, 1 );
    $self->{grid}->attach( Gtk3::Label->new( $options{process} ),
        1, $self->{grid_rows}, 1, 1 );
    $self->{grid}->attach( Gtk3::Label->new( $types{ $options{type} } ),
        2, $self->{grid_rows}, 1, 1 );
    my $view   = Gtk3::TextView->new;
    my $buffer = $view->get_buffer;
    $options{text} =~ s/\s+$//xsm;
    $buffer->set_text( $options{text} );
    $view->set_editable(FALSE);
    $view->set_wrap_mode('word-char');
    $view->set( 'expand', TRUE );
    $self->{grid}->attach( $view, $COL_MESSAGE, $self->{grid_rows}++, 1, 1 );

    if ( $options{'store-response'} ) {
        $self->{grid}->attach( Gtk3::CheckButton->new, $COL_CHECKBOX,
            $self->{grid_rows} - 1,
            1, 1 );
        if ( $options{'stored-responses'} ) {
            $self->{stored_responses}[ $self->{grid_rows} - 1 ] =
              $options{'stored-responses'};
        }
    }
    if ( $self->{grid_rows} > 2 ) {
        $self->{cb}->set_label( __("Don't show these messages again") );
    }
    return;
}

sub _list_checkboxes {
    my ($self) = @_;
    my @cbs;
    for my $row ( 1 .. $self->{grid_rows} - 1 ) {
        my $cb = $self->{grid}->get_child_at( $COL_CHECKBOX, $row );
        if ( defined $cb ) {
            push @cbs, $cb;
        }
    }
    return @cbs;
}

sub list_messages_to_ignore {
    my ( $self, $response ) = @_;
    my (@list);
    for my $row ( 1 .. $self->{grid_rows} - 1 ) {
        my $cb = $self->{grid}->get_child_at( $COL_CHECKBOX, $row );
        if ( defined $cb and $cb->get_active ) {
            my $filter = TRUE;
            if ( $self->{stored_responses}[$row] ) {
                $filter = FALSE;
                for ( @{ $self->{stored_responses}[$row] } ) {
                    if ( $_ eq $response ) {
                        $filter = TRUE;
                        last;
                    }
                }
            }
            if ($filter) {
                my $buffer =
                  $self->{grid}->get_child_at( $COL_MESSAGE, $row )->get_buffer;
                push @list,
                  $buffer->get_text( $buffer->get_start_iter,
                    $buffer->get_end_iter, TRUE );
            }
        }
    }
    return @list;
}

sub close_callback {
}

1;

__END__
