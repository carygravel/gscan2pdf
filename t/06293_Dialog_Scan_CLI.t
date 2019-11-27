use warnings;
use strict;
use Test::More tests => 1;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;             # Could just call init separately
use Image::Sane ':all';     # To get SANE_* enums
use Sub::Override;          # Override Frontend::CLI to test functionality that
                            # we can't with the test backend

BEGIN {
    use Gscan2pdf::Dialog::Scan::CLI;
}

#########################

my $window = Gtk3::Window->new;

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($FATAL);
my $logger = Log::Log4perl::get_logger;

my $help_out = <<'EOS';
Usage: scanimage [OPTION]...

Start image acquisition on a scanner device and write PNM image data to standard output.

-d, --device-name=DEVICE   use a given scanner device (e.g. hp:/dev/scanner)
    --format=pnm|tiff      file format of output file
-i, --icc-profile=PROFILE  include this ICC profile into TIFF file
-L, --list-devices         show available scanner devices
-f, --formatted-device-list=FORMAT similar to -L, but the FORMAT of the output
                           can be specified: %d (device name), %v (vendor),
                           %m (model), %t (type), and %i (index number)
-b, --batch[=FORMAT]       working in batch mode, FORMAT is `out%d.pnm' or
                           `out%d.tif' by default depending on --format
    --batch-start=#        page number to start naming files with
    --batch-count=#        how many pages to scan in batch mode
    --batch-increment=#    increase number in filename by an amount of #
    --batch-double         increment page number by two for 2sided originals
                           being scanned in a single sided scanner
    --batch-prompt         ask for pressing a key before scanning a page
    --accept-md5-only      only accept authorization requests using md5
-p, --progress             print progress messages
-n, --dont-scan            only set options, don't actually scan
-T, --test                 test backend thoroughly
-h, --help                 display this help message and exit
-v, --verbose              give even more status messages
-B, --buffer-size          change default input buffersize
-V, --version              print version information

Options specific to device `fujitsu:libusb:002:004':
  Scan Mode:
    --source ADF Front|ADF Back|ADF Duplex [ADF Front]
        Selects the scan source (such as a document-feeder).
    --mode Gray|Color [Gray]
        Selects the scan mode (e.g., lineart, monochrome, or color).
    --resolution 100..600dpi (in steps of 1) [600]
        Sets the horizontal resolution of the scanned image.
    --y-resolution 50..600dpi (in steps of 1) [600]
        Sets the vertical resolution of the scanned image.
  Geometry:
    -l 0..224.846mm (in steps of 0.0211639) [0]
        Top-left x position of scan area.
    -t 0..863.489mm (in steps of 0.0211639) [0]
        Top-left y position of scan area.
    -x 0..224.846mm (in steps of 0.0211639) [215.872]
        Width of scan-area.
    -y 0..863.489mm (in steps of 0.0211639) [279.364]
        Height of scan-area.
    --pagewidth 0..224.846mm (in steps of 0.0211639) [215.872]
        Must be set properly to align scanning window
    --pageheight 0..863.489mm (in steps of 0.0211639) [279.364]
        Must be set properly to eject pages
  Enhancement:
    --rif[=(yes|no)] [no]
        Reverse image format
  Advanced:
    --dropoutcolor Default|Red|Green|Blue [Default]
        One-pass scanners use only one color during gray or binary scanning,
        useful for colored paper or ink
    --sleeptimer 0..60 (in steps of 1) [0]
        Time in minutes until the internal power supply switches to sleep mode
  Sensors and Buttons:

Type ``scanimage --help -d DEVICE'' to get list of all options for DEVICE.

List of available devices:
   fujitsu:libusb:002:004
EOS

my $help_err = <<'EOS';
scanimage: rounded value of br-x from 215.872 to 215.872
scanimage: big ugly error
EOS

my $override = Sub::Override->new;
$override->replace(
    'Gscan2pdf::Frontend::CLI::_watch_cmd' => sub {
        my (%options) = @_;
        if ( $options{started_callback} ) {
            $options{started_callback}->();
        }
        $options{finished_callback}->( $help_out, $help_err );
    }
);

Gscan2pdf::Frontend::CLI->setup($logger);

my $dialog = Gscan2pdf::Dialog::Scan::CLI->new(
    title           => 'title',
    'transient-for' => $window,
    'logger'        => $logger
);
$dialog->signal_connect(
    'process-error' => sub {
        my ( $widget, $process, $msg, $signal ) = @_;
        $logger->debug( 'process-error', $widget, $process, $msg, $signal );
        is( $msg, 'big ugly error', 'process-error ignored rounding' );
    }
);

$dialog->signal_connect(
    'reloaded-scan-options' => sub {
        Gtk3->main_quit;
    }
);

my $signal = $dialog->signal_connect(
    'changed-device-list' => sub {

        my $signal;
        $signal = $dialog->signal_connect(
            'changed-device' => sub {
                my ( $widget, $name ) = @_;
                $dialog->signal_handler_disconnect($signal);
            }
        );
        $dialog->set( 'device', 'fujitsu:libusb:002:004' );
    }
);

# give gtk a chance to hit the main loop before starting
Glib::Idle->add(
    sub {
        $dialog->set( 'device-list',
            [ { 'name' => 'fujitsu:libusb:002:004' } ] );
    }
);

Gtk3->main;

__END__
