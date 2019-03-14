use warnings;
use strict;
use Test::More tests => 4;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;             # Could just call init separately
use Image::Sane ':all';     # To get SANE_* enums

BEGIN {
    use Gscan2pdf::Dialog::Scan::Image_Sane;
}

#########################

my $window = Gtk3::Window->new;

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Frontend::Image_Sane->setup($logger);

my $dialog = Gscan2pdf::Dialog::Scan::Image_Sane->new(
    title               => 'title',
    'transient-for'     => $window,
    'cycle-sane-handle' => TRUE,
    'logger'            => $logger,
);

$dialog->{signal} = $dialog->signal_connect(
    'reloaded-scan-options' => sub {
        $dialog->signal_handler_disconnect( $dialog->{signal} );

        # So that it can be used in hash
        my $resolution = SANE_NAME_SCAN_RESOLUTION;

        # need a new main loop because of the timeout
        my $loop = Glib::MainLoop->new;
        my $flag = FALSE;
        $dialog->{signal} = $dialog->signal_connect(
            'changed-scan-option' => sub {
                my ( $widget, $option, $value ) = @_;
                $dialog->signal_handler_disconnect( $dialog->{signal} );
                is_deeply(
                    $dialog->get('current-scan-options')->get_data,
                    { backend => [ { $resolution => 51 } ] },
                    'set resolution before scan'
                );
                $flag = TRUE;
                $loop->quit;
            }
        );
        my $options = $dialog->get('available-scan-options');
        $dialog->set_option( $options->by_name($resolution), 51 );
        $loop->run unless ($flag);

        # Prior to v1.5.2, cycling the SANE handle reset the profile to defaults
        # To test this, scan, check that the open-device process has fired,
        # and then that options are still the same.
        $loop = Glib::MainLoop->new;
        $flag = FALSE;
        my $open_signal;
        $open_signal = $dialog->signal_connect(
            'finished-process' => sub {
                my ( $widget, $process ) = @_;
                if ( $process eq 'open_device' ) {
                    $dialog->signal_handler_disconnect($open_signal);
                    pass 'open_device emitted';
                }
            }
        );
        $dialog->{signal} = $dialog->signal_connect(
            'changed-scan-option' => sub {
                my ( $widget, $option, $value ) = @_;
                $dialog->signal_handler_disconnect( $dialog->{signal} );
                is_deeply(
                    $dialog->get('current-scan-options')->get_data,
                    { backend => [ { $resolution => 51 } ] },
                    'set resolution after scan'
                );

                # The resolution widget should be defined by the time the
                # scan options have been updated
                isnt( $dialog->{option_widgets}{$resolution},
                    undef, 'resolution widget defined' );
                $flag = TRUE;
                $loop->quit;
            }
        );

        # clear up after ourselves
        $dialog->signal_connect(
            'new-scan' => sub {
                my ( $widget, $path, $page_number, $xres, $yres ) = @_;
                unlink $path;
            }
        );
        $dialog->scan;
        $loop->run unless ($flag);

        Gtk3->main_quit;
    }
);
$dialog->set( 'device', 'test' );
$dialog->scan_options;
Gtk3->main;

Gscan2pdf::Frontend::Image_Sane->quit;
__END__
