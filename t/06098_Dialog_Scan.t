use warnings;
use strict;
use Test::More tests => 1;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;             # Could just call init separately
use Image::Sane ':all';     # To get SANE_* enums
use Sub::Override;    # Override Frontend::Image_Sane to test functionality that
                      # we can't with the test backend
use Storable qw(freeze);    # For cloning the options cache
use Gscan2pdf::Dialog::Scan::Image_Sane;

#########################

my $window = Gtk3::Window->new;

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;

# The overrides must occur before the thread is spawned in setup.
my $override = Sub::Override->new;
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
                            'name'  => 'mock_device',
                            'label' => 'mock_device'
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

# the full test of options from test backend
my $raw_options = [
    undef,
    {
        'cap'             => 0,
        'max_values'      => 0,
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 1,
        'desc'            => '',
        'title'           => 'Scan Mode',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'mode',
        'val'        => 'Gray',
        'index'      => 2,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
          'Selects the scan mode (e.g., lineart, monochrome, or color).',
        'type'          => SANE_TYPE_STRING,
        'constraint'    => [ 'Gray', 'Color' ],
        'title'         => 'Mode',
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'depth',
        'val'        => '8',
        'index'      => 3,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Number of bits per sample, typical values are 1 for "line-art" and 8 for multibit scans.',
        'type'            => SANE_TYPE_INT,
        'constraint'      => [ '1', '8', '16' ],
        'title'           => 'Depth',
        'constraint_type' => SANE_CONSTRAINT_WORD_LIST
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'hand-scanner',
        'val'        => '0',
        'index'      => 4,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Simulate a hand-scanner.  Hand-scanners do not know the image height a priori.  Instead, they return a height of -1.  Setting this option allows to test whether a frontend can handle this correctly.  This option also enables a fixed width of 11 cm.',
        'title'           => 'Hand scanner',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => '37',
        'max_values' => '1',
        'name'       => 'three-pass',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 5,
        'desc' =>
'Simulate a three-pass scanner. In color mode, three frames are transmitted.',
        'title'           => 'Three pass',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'           => '37',
        'max_values'    => '1',
        'name'          => 'three-pass-order',
        'index'         => 6,
        'unit'          => SANE_UNIT_NONE,
        'desc'          => 'Set the order of frames in three-pass color mode.',
        'title'         => 'Three pass order',
        'type'          => SANE_TYPE_STRING,
        'constraint'    => [ 'RGB', 'RBG', 'GBR', 'GRB', 'BRG', 'BGR' ],
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'resolution',
        'val'        => '50',
        'index'      => 7,
        'unit'       => SANE_UNIT_DPI,
        'desc'       => 'Sets the resolution of the scanned image.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '1',
            'max'   => '1200',
            'quant' => '1'
        },
        'title'         => 'Resolution',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'source',
        'val'        => 'Flatbed',
        'index'      => 8,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'If Automatic Document Feeder is selected, the feeder will be \'empty\' after 10 scans.',
        'type'          => SANE_TYPE_STRING,
        'constraint'    => [ 'Flatbed', 'Automatic Document Feeder' ],
        'title'         => 'Source',
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap'             => '0',
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 9,
        'desc'            => '',
        'title'           => 'Special Options',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'test-picture',
        'val'        => 'Solid black',
        'index'      => 10,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Select the kind of test picture. Available options: Solid black: fills the whole scan with black. Solid white: fills the whole scan with white. Color pattern: draws various color test patterns depending on the mode. Grid: draws a black/white grid with a width and height of 10 mm per square.',
        'type' => SANE_TYPE_STRING,
        'constraint' =>
          [ 'Solid black', 'Solid white', 'Color pattern', 'Grid' ],
        'title'         => 'Test picture',
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap'        => '37',
        'max_values' => '1',
        'name'       => 'invert-endianess',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 11,
        'desc' =>
'Exchange upper and lower byte of image data in 16 bit modes. This option can be used to test the 16 bit modes of frontends, e.g. if the frontend uses the correct endianness.',
        'title'           => 'Invert endianess',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'read-limit',
        'val'        => '0',
        'index'      => 12,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
          'Limit the amount of data transferred with each call to sane_read().',
        'title'           => 'Read limit',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => '37',
        'max_values' => '1',
        'name'       => 'read-limit-size',
        'index'      => 13,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'The (maximum) amount of data transferred with each call to sane_read().',
        'title'      => 'Read limit size',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '1',
            'max'   => '65536',
            'quant' => '1'
        },
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'             => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values'      => '1',
        'name'            => 'read-delay',
        'val'             => '0',
        'index'           => 14,
        'unit'            => SANE_UNIT_NONE,
        'desc'            => 'Delay the transfer of data to the pipe.',
        'title'           => 'Read delay',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => '37',
        'max_values' => '1',
        'name'       => 'read-delay-duration',
        'index'      => 15,
        'unit'       => SANE_UNIT_MICROSECOND,
        'desc' =>
'How long to wait after transferring each buffer of data through the pipe.',
        'title'      => 'Read delay duration',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '1000',
            'max'   => '200000',
            'quant' => '1000'
        },
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'read-return-value',
        'val'        => 'Default',
        'index'      => 16,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Select the return-value of sane_read(). "Default" is the normal handling for scanning. All other status codes are for testing how the frontend handles them.',
        'type'       => SANE_TYPE_STRING,
        'constraint' => [
            'Default',                'SANE_STATUS_UNSUPPORTED',
            'SANE_STATUS_CANCELLED',  'SANE_STATUS_DEVICE_BUSY',
            'SANE_STATUS_INVAL',      'SANE_STATUS_EOF',
            'SANE_STATUS_JAMMED',     'SANE_STATUS_NO_DOCS',
            'SANE_STATUS_COVER_OPEN', 'SANE_STATUS_IO_ERROR',
            'SANE_STATUS_NO_MEM',     'SANE_STATUS_ACCESS_DENIED'
        ],
        'title'         => 'Read return value',
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'ppl-loss',
        'val'        => '0',
        'index'      => 17,
        'unit'       => SANE_UNIT_PIXEL,
        'desc' =>
          'The number of pixels that are wasted at the end of each line.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '-128',
            'max'   => '128',
            'quant' => '1'
        },
        'title'         => 'Ppl loss',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'fuzzy-parameters',
        'val'        => '0',
        'index'      => 18,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Return fuzzy lines and bytes per line when sane_parameters() is called before sane_start().',
        'title'           => 'Fuzzy parameters',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'non-blocking',
        'val'        => '0',
        'index'      => 19,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
          'Use non-blocking IO for sane_read() if supported by the frontend.',
        'title'           => 'Non blocking',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'select-fd',
        'val'        => '0',
        'index'      => 20,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Offer a select filedescriptor for detecting if sane_read() will return data.',
        'title'           => 'Select fd',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'enable-test-options',
        'val'        => '0',
        'index'      => 21,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'Enable various test options. This is for testing the ability of frontends to view and modify all the different SANE option types.',
        'title'           => 'Enable test options',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'read-length-zero',
        'val'        => '0',
        'index'      => 22,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'sane_read() returns data \'x\' but length=0 on first call. This is helpful for testing slow device behavior that returns no data when background work is in process and zero length with SANE_STATUS_GOOD although data is NOT filled with 0.',
        'title'           => 'Read length zero',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'             => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values'      => '0',
        'name'            => 'print-options',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 23,
        'desc'            => 'Print a list of all options.',
        'title'           => 'Print options',
        'type'            => SANE_TYPE_BUTTON,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'             => '0',
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 24,
        'desc'            => '',
        'title'           => 'Geometry',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => SANE_NAME_SCAN_TL_X,
        'val'        => '0',
        'index'      => 25,
        'unit'       => SANE_UNIT_MM,
        'desc'       => 'Top-left x position of scan area.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '0',
            'max'   => '200',
            'quant' => '1'
        },
        'title'         => 'Top-left x',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => SANE_NAME_SCAN_TL_Y,
        'val'        => '0',
        'index'      => 26,
        'unit'       => SANE_UNIT_MM,
        'desc'       => 'Top-left y position of scan area.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '0',
            'max'   => '200',
            'quant' => '1'
        },
        'title'         => 'Top-left y',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => SANE_NAME_SCAN_BR_X,
        'val'        => '80',
        'index'      => 27,
        'unit'       => SANE_UNIT_MM,
        'desc'       => 'Bottom-right x position of scan area.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '0',
            'max'   => '200',
            'quant' => '1'
        },
        'title'         => 'Bottom-right x',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => SANE_NAME_SCAN_BR_Y,
        'val'        => '100',
        'index'      => 28,
        'unit'       => SANE_UNIT_MM,
        'desc'       => 'Bottom-right y position of scan area.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '0',
            'max'   => '200',
            'quant' => '1'
        },
        'title'         => 'Bottom-right y',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'page-width',
        'val'        => '200',
        'index'      => 29,
        'unit'       => SANE_UNIT_MM,
        'desc' =>
'Specifies the width of the media.  Required for automatic centering of sheet-fed scans.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '0',
            'max'   => '300',
            'quant' => '1'
        },
        'title'         => 'Page width',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'        => SANE_CAP_SOFT_DETECT + SANE_CAP_SOFT_SELECT,
        'max_values' => '1',
        'name'       => 'page-height',
        'val'        => '200',
        'index'      => 30,
        'unit'       => SANE_UNIT_MM,
        'desc'       => 'Specifies the height of the media.',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '0',
            'max'   => '300',
            'quant' => '1'
        },
        'title'         => 'Page height',
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap'             => 0,
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 31,
        'desc'            => '',
        'title'           => 'Bool test options',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'bool-soft-select-soft-detect',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 32,
        'desc' =>
'(1/6) Bool test option that has soft select and soft detect (and advanced) capabilities. That\'s just a normal bool option.',
        'title'           => 'Bool soft select soft detect',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'bool-soft-select-soft-detect-emulated',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 33,
        'desc' =>
'(5/6) Bool test option that has soft select, soft detect, and emulated (and advanced) capabilities.',
        'title'           => 'Bool soft select soft detect emulated',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE +
          SANE_CAP_AUTOMATIC,
        'max_values' => '1',
        'name'       => 'bool-soft-select-soft-detect-auto',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 34,
        'desc' =>
'(6/6) Bool test option that has soft select, soft detect, and automatic (and advanced) capabilities. This option can be automatically set by the backend.',
        'title'           => 'Bool soft select soft detect auto',
        'type'            => SANE_TYPE_BOOL,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap'             => 0,
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 35,
        'desc'            => '',
        'title'           => 'Int test options',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'int',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 36,
        'desc'  => '(1/6) Int test option with no unit and no constraint set.',
        'title' => 'Int',
        'type'  => SANE_TYPE_INT,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'int-constraint-range',
        'index'      => 37,
        'unit'       => SANE_UNIT_PIXEL,
        'desc' =>
'(2/6) Int test option with unit pixel and constraint range set. Minimum is 4, maximum 192, and quant is 2.',
        'title'      => 'Int constraint range',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '4',
            'max'   => '192',
            'quant' => '2'
        },
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'int-constraint-word-list',
        'index'      => 38,
        'unit'       => SANE_UNIT_BIT,
        'desc' =>
          '(3/6) Int test option with unit bits and constraint word list set.',
        'title'      => 'Int constraint word list',
        'type'       => SANE_TYPE_INT,
        'constraint' => [
            '-42', '-8',  '0',     '17',
            '42',  '256', '65536', '16777216',
            '1073741824'
        ],
        'constraint_type' => SANE_CONSTRAINT_WORD_LIST
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => 255,
        'name'       => 'int-constraint-array',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 39,
        'desc' =>
'(4/6) Int test option with unit mm and using an array without constraints.',
        'title'           => 'Int constraint array',
        'type'            => SANE_TYPE_INT,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => 255,
        'name'       => 'int-constraint-array-constraint-range',
        'index'      => 40,
        'unit'       => SANE_UNIT_DPI,
        'desc' =>
'(5/6) Int test option with unit dpi and using an array with a range constraint. Minimum is 4, maximum 192, and quant is 2.',
        'title'      => 'Int constraint array constraint range',
        'type'       => SANE_TYPE_INT,
        'constraint' => {
            'min'   => '4',
            'max'   => '192',
            'quant' => '2'
        },
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => 255,
        'name'       => 'int-constraint-array-constraint-word-list',
        'index'      => 41,
        'unit'       => SANE_UNIT_PERCENT,
        'desc' =>
'(6/6) Int test option with unit percent and using an array with a word list constraint.',
        'title'      => 'Int constraint array constraint word list',
        'type'       => SANE_TYPE_INT,
        'constraint' => [
            '-42', '-8',  '0',     '17',
            '42',  '256', '65536', '16777216',
            '1073741824'
        ],
        'constraint_type' => SANE_CONSTRAINT_WORD_LIST
    },
    {
        'cap'             => 0,
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 42,
        'desc'            => '',
        'title'           => 'Fixed test options',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'fixed',
        'unit'       => SANE_UNIT_NONE,
        'index'      => 43,
        'desc' => '(1/3) Fixed test option with no unit and no constraint set.',
        'title'           => 'Fixed',
        'type'            => SANE_TYPE_FIXED,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'fixed-constraint-range',
        'index'      => 44,
        'unit'       => SANE_UNIT_MICROSECOND,
        'desc' =>
'(2/3) Fixed test option with unit microsecond and constraint range set. Minimum is -42.17, maximum 32767.9999, and quant is 2.0.',
        'title'      => 'Fixed constraint range',
        'type'       => SANE_TYPE_FIXED,
        'constraint' => {
            'min'   => '-42.17',
            'max'   => '32768',
            'quant' => '2'
        },
        constraint_type => SANE_CONSTRAINT_RANGE,
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'fixed-constraint-word-list',
        'index'      => 45,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
          '(3/3) Fixed test option with no unit and constraint word list set.',
        'title'           => 'Fixed constraint word list',
        'type'            => SANE_TYPE_FIXED,
        'constraint'      => [ '-32.7', '12.1', '42', '129.5' ],
        'constraint_type' => SANE_CONSTRAINT_WORD_LIST
    },
    {
        'cap'             => '0',
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 46,
        'desc'            => '',
        'title'           => 'String test options',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values'      => '1',
        'name'            => 'string',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 47,
        'desc'            => '(1/3) String test option without constraint.',
        'title'           => 'String',
        'type'            => SANE_TYPE_STRING,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'string-constraint-string-list',
        'index'      => 48,
        'unit'       => SANE_UNIT_NONE,
        'desc'       => '(2/3) String test option with string list constraint.',
        'title'      => 'String constraint string list',
        'type'       => SANE_TYPE_STRING,
        'constraint' => [
            'First entry',
            'Second entry',
'This is the very long third entry. Maybe the frontend has an idea how to display it'
        ],
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values' => '1',
        'name'       => 'string-constraint-long-string-list',
        'index'      => 49,
        'unit'       => SANE_UNIT_NONE,
        'desc' =>
'(3/3) String test option with string list constraint. Contains some more entries...',
        'title'      => 'String constraint long string list',
        'type'       => SANE_TYPE_STRING,
        'constraint' => [
            'First entry', 'Second entry', '3',  '4',
            '5',           '6',            '7',  '8',
            '9',           '10',           '11', '12',
            '13',          '14',           '15', '16',
            '17',          '18',           '19', '20',
            '21',          '22',           '23', '24',
            '25',          '26',           '27', '28',
            '29',          '30',           '31', '32',
            '33',          '34',           '35', '36',
            '37',          '38',           '39', '40',
            '41',          '42',           '43', '44',
            '45',          '46'
        ],
        constraint_type => SANE_CONSTRAINT_STRING_LIST,
    },
    {
        'cap'             => '0',
        'max_values'      => '0',
        'name'            => '',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 50,
        'desc'            => '',
        'title'           => 'Button test options',
        type              => SANE_TYPE_GROUP,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
    {
        'cap' => SANE_CAP_SOFT_DETECT +
          SANE_CAP_SOFT_SELECT +
          SANE_CAP_INACTIVE,
        'max_values'      => '0',
        'name'            => 'button',
        'unit'            => SANE_UNIT_NONE,
        'index'           => 51,
        'desc'            => '(1/1) Button test option. Prints some text...',
        'title'           => 'Button',
        'type'            => SANE_TYPE_BUTTON,
        'constraint_type' => SANE_CONSTRAINT_NONE
    },
];
$override->replace(
    'Gscan2pdf::Frontend::Image_Sane::_thread_get_options' => sub {
        my ( $self, $uuid ) = @_;
        $self->{return}->enqueue(
            {
                type    => 'finished',
                process => 'get-options',
                uuid    => $uuid,
                info    => freeze($raw_options),
                status  => SANE_STATUS_GOOD,
            }
        );
        return;
    }
);

# versions 2.0.2 - 2.6.7 didn't update the switch widget correctly when the
# option changed. Create tests for the widgets for all options types
$override->replace(
    'Gscan2pdf::Frontend::Image_Sane::_thread_set_option' => sub {
        my ( $self, $uuid, $index, $value ) = @_;
        $raw_options->[$index]{val} = $value;

        # Reload
        Gscan2pdf::Frontend::Image_Sane::_thread_get_options( $self, $uuid );
        return;
    }
);

Gscan2pdf::Frontend::Image_Sane->setup($logger);

my $dialog = Gscan2pdf::Dialog::Scan::Image_Sane->new(
    title           => 'title',
    'transient-for' => $window,
    'logger'        => $logger
);

$dialog->{signal} = $dialog->signal_connect(
    'changed-device-list' => sub {
        $dialog->signal_handler_disconnect( $dialog->{signal} );
        $dialog->set( 'device', 'mock_device' );
    }
);

$dialog->{reloaded_signal} = $dialog->signal_connect(
    'reloaded-scan-options' => sub {
        $dialog->signal_handler_disconnect( $dialog->{reloaded_signal} );

        ######################################

        # SANE_TYPE_BOOL
        my $loop1 = Glib::MainLoop->new;
        my $signal;
        $signal = $dialog->signal_connect(
            'changed-scan-option' => sub {
                my ( $self, $option, $value ) = @_;
                $dialog->signal_handler_disconnect($signal);
                my $widget = $self->{option_widgets}{$option};
                is $widget->get_active, $value, 'SANE_TYPE_BOOL';
                $loop1->quit;
            }
        );
        my $options = $dialog->get('available-scan-options');
        $dialog->set_option( $options->by_name('hand-scanner'), TRUE );
        $loop1->run;

        Gtk3->main_quit;
    }
);
$dialog->get_devices;

Gtk3->main;

Gscan2pdf::Frontend::Image_Sane->quit;
__END__
