use warnings;
use strict;
use Test::More tests => 1;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;             # Could just call init separately
use Image::Sane ':all';     # To get SANE_* enums
use Sub::Override;    # Override Frontend::Image_Sane to test functionality that
                      # we can't with the test backend
use Storable qw(freeze);    # For cloning the options cache

BEGIN {
    use Gscan2pdf::Dialog::Scan::Image_Sane;
}

#########################

my $window = Gtk3::Window->new;

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;

# The overrides must occur before the thread is spawned in setup.
my $override = Sub::Override->new;

# A user with several devices visible to SANE had the problem that the only
# working device was further down the list and the blacklist logic in
# main::process_error_callback() only worked until the next get_devices() call.
$override->replace(
    'Gscan2pdf::Frontend::Image_Sane::_thread_get_devices' => sub {
        my ( $self, $uuid ) = @_;
        $self->{return}->enqueue(
            {
                type    => 'finished',
                process => 'get-devices',
                uuid    => $uuid,
                info    => freeze(
                    [
                        {
                            'name'  => 'mock_device bad1',
                            'label' => 'mock_device bad1'
                        },
                        {
                            'name'  => 'mock_device bad2',
                            'label' => 'mock_device bad2'
                        },
                        {
                            'name'  => 'mock_device good',
                            'label' => 'mock_device good'
                        }
                    ]
                ),
                status => SANE_STATUS_GOOD,
            }
        );
        return;
    }
);
$override->replace(
    'Gscan2pdf::Frontend::Image_Sane::_thread_open_device' => sub {
        my ( $self, $uuid, $device_name ) = @_;
        if ( $device_name =~ /bad/ ) {
            $self->{return}->enqueue(
                {
                    type    => 'error',
                    uuid    => $uuid,
                    status  => SANE_STATUS_ACCESS_DENIED,
                    message => 'Error opening device',
                    process => 'open-device',
                }
            );
            return;
        }
        $self->{return}->enqueue(
            {
                type    => 'finished',
                process => 'open-device',
                uuid    => $uuid,
                info    => freeze( \$device_name ),
                status  => SANE_STATUS_GOOD,
            }
        );
        return;
    }
);

Gscan2pdf::Frontend::Image_Sane->setup($logger);

my $dialog = Gscan2pdf::Dialog::Scan::Image_Sane->new(
    title           => 'title',
    'transient-for' => $window,
    'logger'        => $logger
);

$dialog->signal_connect(
    'changed-device-list' => sub {
        my ( $widget, $device_list ) = @_;
        $dialog->set( 'device', $device_list->[0]{name} );
    }
);
$dialog->signal_connect(
    'changed-device' => sub {
        my ( $widget, $device ) = @_;
        $logger->debug("changed-device with $device");
        if ( $device =~ /good/ ) {
            is( $device, 'mock_device good',
                'successfully opened good device' );
            Gtk3->main_quit;
        }
    }
);
$dialog->get_devices;

Gtk3->main;

Gscan2pdf::Frontend::Image_Sane->quit;
__END__
