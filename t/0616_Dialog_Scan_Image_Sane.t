use warnings;
use strict;
use Test::More tests => 2;
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
Log::Log4perl->easy_init($ERROR);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Frontend::Image_Sane->setup($logger);

my $dialog = Gscan2pdf::Dialog::Scan::Image_Sane->new(
    title           => 'title',
    'transient-for' => $window,
    'logger'        => $logger
);

$dialog->{reloaded_signal} = $dialog->signal_connect(
    'reloaded-scan-options' => sub {
        $dialog->signal_handler_disconnect( $dialog->{reloaded_signal} );

        ######################################

        # Setting a profile means setting a series of options; setting the
        # first, waiting for it to finish, setting the second, and so on. If one
        # of the settings is already applied, and therefore does not fire a
        # signal, then there is a danger that the rest of the profile is not
        # set.

        $dialog->add_profile(
            'g51',
            Gscan2pdf::Scanner::Profile->new_from_data(
                {
                    backend => [
                        {
                            'page-height' => '297'
                        },
                        {
                            'y' => '297'
                        },
                        {
                            'resolution' => '51'
                        },
                    ]
                }
            )
        );
        $dialog->add_profile(
            'c50',
            Gscan2pdf::Scanner::Profile->new_from_data(
                {
                    backend => [
                        {
                            'page-height' => '297'
                        },
                        {
                            'y' => '297'
                        },
                        {
                            'resolution' => '50'
                        },
                    ]
                }
            )
        );

        # need a new main loop because of the timeout
        my $loop = Glib::MainLoop->new;
        my $flag = FALSE;
        $dialog->{profile_signal} = $dialog->signal_connect(
            'changed-profile' => sub {
                my ( $widget, $profile ) = @_;
                $dialog->signal_handler_disconnect( $dialog->{profile_signal} );
                my $options      = $dialog->get('available-scan-options');
                my $opt          = $options->by_name('resolution');
                my $optwidget    = $widget->{option_widgets}{resolution};
                my $widget_value = $optwidget->get_value;
                is( $widget_value, 51, 'correctly updated widget' );
                $flag = TRUE;
                $loop->quit;
            }
        );
        $dialog->set( 'profile', 'g51' );
        $loop->run unless ($flag);

        # need a new main loop because of the timeout
        $loop                     = Glib::MainLoop->new;
        $flag                     = FALSE;
        $dialog->{profile_signal} = $dialog->signal_connect(
            'changed-profile' => sub {
                my ( $widget, $profile ) = @_;
                $dialog->signal_handler_disconnect( $dialog->{profile_signal} );
                is_deeply(
                    $dialog->get('current-scan-options')->get_data,
                    { backend => [ { 'br-y' => '200' } ] },
                    'fired signal and set profile'
                );
                $flag = TRUE;
                $loop->quit;
            }
        );
        $dialog->set( 'profile', 'c50' );
        $loop->run unless ($flag);

        Gtk3->main_quit;
    }
);
$dialog->{signal} = $dialog->signal_connect(
    'changed-device-list' => sub {
        $dialog->signal_handler_disconnect( $dialog->{signal} );
        $dialog->set( 'device', 'test:0' );
    }
);
$dialog->set( 'device-list',
    [ { 'name' => 'test:0' }, { 'name' => 'test:1' } ] );
Gtk3->main;

Gscan2pdf::Frontend::Image_Sane->quit;
__END__
