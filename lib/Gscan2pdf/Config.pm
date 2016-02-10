package Gscan2pdf::Config;

use strict;
use warnings;
use Gscan2pdf::Document;
use Glib qw(TRUE FALSE);     # To get TRUE and FALSE
use Locale::gettext 1.05;    # For translations
use File::Copy;
use Try::Tiny;
use Data::Dumper;
use Config::General 2.40;
use JSON::PP;
use version;

BEGIN {
    use Exporter ();
    our ( $VERSION, @EXPORT_OK, %EXPORT_TAGS );

    $VERSION = '1.3.8';

    use base qw(Exporter);
    %EXPORT_TAGS = ();    # eg: TAG => [ qw!name1 name2! ],

    # your exported package globals go here,
    # as well as any optionally exported functions
    @EXPORT_OK = qw();
}

my $EMPTY = q{};
my $d;

sub read_config {
    my ( $filename, $logger ) = @_;
    my ( %SETTING, $conf );
    $logger->info("Reading config from $filename");
    if ( not -r $filename ) { system "touch $filename" }

    if ( not defined $d ) {
        $d = Locale::gettext->domain(Glib::get_application_name);
    }

    # from v1.3.3 onwards, the config file is saved as JSON
    my $config  = Gscan2pdf::Document::slurp($filename);
    my $version = '2';
    if ( $config =~ /^\s*"?version"?\s*[=:]\s*"?([\d.]+)"?/xsm ) {
        $version = $1;
    }
    $logger->info("Config file version $version");

    if ( version->parse($version) < version->parse('1.3.3') ) {
        try {
            $conf = Config::General->new(
                -ConfigFile  => $filename,
                -SplitPolicy => 'equalsign',
                -UTF8        => 1,
            );
        }
        catch {
            $logger->error(
                $d->get(
"Error: unable to load settings.\nBacking up settings\nReverting to defaults"
                )
            );
            move( $filename, "$filename.old" );
        }
        finally {
            if ( not @_ ) { %SETTING = $conf->getall }
        };
    }
    elsif ( length $config > 0 ) {
        $conf    = JSON::PP->new->ascii;
        $conf    = $conf->pretty->allow_nonref;
        %SETTING = %{ $conf->decode($config) };
    }
    $logger->debug( Dumper( \%SETTING ) );
    return %SETTING;
}

sub add_defaults {
    my ($SETTING) = @_;
    my %default_settings = (
        'window_width'      => 800,
        'window_height'     => 600,
        'window_maximize'   => TRUE,
        'thumb panel'       => 100,
        'Page range'        => 'all',
        'layout'            => 'single',
        'downsample'        => FALSE,
        'downsample dpi'    => 150,
        'threshold tool'    => 80,
        'unsharp radius'    => 0,
        'unsharp sigma'     => 1,
        'unsharp amount'    => 1,
        'unsharp threshold' => 0.05,
        'cache options'     => TRUE,
        'restore window'    => TRUE,
        'document date'     => time,
        'pdf compression'   => 'auto',
        'quality'           => 75,
        'pages to scan'     => 1,
        'unpaper on scan'   => FALSE,
        'OCR on scan'       => TRUE,
        'frontend'          => 'libsane-perl',
        'rotate facing'     => 0,
        'rotate reverse'    => 0,
        'default filename'  => '%a %y-%m-%d',
        'scan prefix'       => $EMPTY,
        'Blank threshold' => 0.005,    # Blank page standard deviation threshold
        'Dark threshold'  => 0.12,     # Dark page mean threshold
        'ocr engine' => 'tesseract',
        'OCR output' =>
          'replace',   # When a page is re-OCRed, replace old text with new text
        'auto-open-scan-dialog' => TRUE,
        'available-tmp-warning' => 10,
        'Paper'                 => {
            $d->get('A4') => {
                x => 210,
                y => 297,
                l => 0,
                t => 0,
            },
            $d->get('US Letter') => {
                x => 216,
                y => 279,
                l => 0,
                t => 0,
            },
            $d->get('US Legal') => {
                x => 216,
                y => 356,
                l => 0,
                t => 0,
            },
        },
        user_defined_tools => ['gimp %i'],

        # show the options marked with 1, hide those with 0
        # for the others, see the value of default-option-visibility
        'visible-scan-options' => {
            mode                => 1,
            compression         => 1,
            resolution          => 1,
            brightness          => 1,
            gain                => 1,
            contrast            => 1,
            threshold           => 1,
            speed               => 1,
            'batch-scan'        => 1,
            'wait-for-button'   => 1,
            'button-wait'       => 1,
            'calibration-cache' => 1,
            source              => 1,
            pagewidth           => 1,
            pageheight          => 1,
            'page-width'        => 1,
            'page-height'       => 1,
            'overscan-top'      => 1,
            'overscan-bottom'   => 1,
            adf_mode            => 1,
            'adf-mode'          => 1,
            'Paper size'        => 1,
            x                   => 1,
            y                   => 1,
            l                   => 1,
            t                   => 1,
        },
        'scan-reload-triggers' => qw(mode),
    );
    if (
        defined $SETTING->{frontend}
        and (  $SETTING->{frontend} eq 'scanimage-perl'
            or $SETTING->{frontend} eq 'scanadf-perl'
            or $SETTING->{frontend} eq 'scanimage.pl'
            or $SETTING->{frontend} eq
            'scanadf.pl' )    # these frontends are just for testing purposes
      )
    {
        delete $SETTING->{frontend};
    }
    for ( keys %default_settings ) {
        if ( not defined $SETTING->{$_} ) {
            $SETTING->{$_} = $default_settings{$_};
        }
    }
    return;
}

sub remove_invalid_paper {
    my ($hashref) = @_;
    for my $paper ( keys %{$hashref} ) {
        if ( $paper eq '<>' or $paper eq '</>' ) {
            delete $hashref->{$paper};
        }
        else {
            for (qw(x y t l)) {
                if ( ref( $hashref->{$paper} ) ne 'HASH'
                    or not defined $hashref->{$paper}{$_} )
                {
                    delete $hashref->{$paper};
                    last;
                }
            }
        }
    }
    return;
}

# Delete the options cache if there is a new version of SANE
sub check_sane_version {
    my ( $SETTING, $SANE, $LIBSANEPERL ) = @_;
    if (
        (
            defined $SETTING->{'SANE version'}
            and $SETTING->{'SANE version'} ne $SANE
        )
        or ( defined $SETTING->{'libsane-perl version'}
            and $SETTING->{'libsane-perl version'} ne $LIBSANEPERL )
      )
    {
        if ( defined $SETTING->{cache} ) { delete $SETTING->{cache} }
    }
    $SETTING->{'SANE version'}         = $SANE;
    $SETTING->{'libsane-perl version'} = $LIBSANEPERL;
    return;
}

sub write_config {
    my ( $rc, $logger, $SETTING ) = @_;
    my $conf = JSON::PP->new->ascii;
    $conf = $conf->pretty->allow_nonref;
    open my $fh, '>', $rc or die "Error: cannot open $rc\n";
    print {$fh} $conf->encode($SETTING) or die "Error: cannot write to $rc\n";
    close $fh or die "Error: cannot close $rc\n";
    $logger->info("Wrote config to $rc");
    return;
}

1;

__END__
