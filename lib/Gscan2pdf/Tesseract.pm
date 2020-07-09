package Gscan2pdf::Tesseract;

use 5.008005;
use strict;
use warnings;
use Carp;
use Encode;
use File::Temp;    # To create temporary files
use File::Basename;
use Gscan2pdf::Document;             # for slurp
use version;
use English qw( -no_match_vars );    # for $PROCESS_ID

our $VERSION = '2.8.0';
my $EMPTY = q{};
my $COMMA = q{,};

my ( %languages, $installed, $setup, $version, $logger );

sub setup {
    ( my $class, $logger ) = @_;
    return $installed if $setup;

    ( undef, my $exe ) =
      Gscan2pdf::Document::exec_command( [ 'which', 'tesseract' ] );
    return if ( not defined $exe or $exe eq $EMPTY );
    $installed = 1;

    # Only support 3.02.01 or better, so that
    # we can use --list-langs and not bother with tessdata
    ( undef, my $out, my $err ) =
      Gscan2pdf::Document::exec_command( [ 'tesseract', '-v' ] );
    if ( $err =~ /^tesseract[ ]([\d.]+)/xsm ) {
        $version = $1;
    }
    elsif ( $out =~ /^tesseract[ ]([\d.]+)/xsm ) {
        $version = $1;
    }
    if ( not $version ) { return }
    if ( $version !~ /^\d+[.]\d+$/xsm ) { $version = 'v' . $version }
    $version = version->parse($version);
    if ( $version > version->parse('v3.02.00') ) {
        $logger->info("Found tesseract version $version.");
        $setup = 1;
        return $installed;
    }

    $logger->error("Tesseract version $version found.");
    $logger->error('Versions older than 3.02 are not supported');
    return;
}

sub languages {
    if ( not %languages ) {
        my %iso639 = (
            ara        => 'Arabic',
            bul        => 'Bulgarian',
            cat        => 'Catalan',
            ces        => 'Czech',
            chr        => 'Cherokee',
            chi_tra    => 'Chinese (Traditional)',
            chi_sim    => 'Chinese (Simplified)',
            dan        => 'Danish',
            'dan-frak' => 'Danish (Fraktur)',
            deu        => 'German',
            'deu-f'    => 'German (Fraktur)',
            'deu-frak' => 'German (Fraktur)',
            ell        => 'Greek',
            eng        => 'English',
            fin        => 'Finish',
            fra        => 'French',
            heb        => 'Hebrew',
            hin        => 'Hindi',
            hun        => 'Hungarian',
            ind        => 'Indonesian',
            ita        => 'Italian',
            jpn        => 'Japanese',
            kor        => 'Korean',
            lav        => 'Latvian',
            lit        => 'Lituanian',
            nld        => 'Dutch',
            nor        => 'Norwegian',
            pol        => 'Polish',
            por        => 'Portuguese',
            que        => 'Quechua',
            ron        => 'Romanian',
            rus        => 'Russian',
            slk        => 'Slovak',
            'slk-frak' => 'Slovak (Fraktur)',
            slv        => 'Slovenian',
            spa        => 'Spanish',
            srp        => 'Serbian (Latin)',
            swe        => 'Swedish',
            'swe-frak' => 'Swedish (Fraktur)',
            tha        => 'Thai',
            tlg        => 'Tagalog',
            tur        => 'Turkish',
            ukr        => 'Ukranian',
            vie        => 'Vietnamese',
        );

        my @codes;
        my ( undef, $out, $err ) =
          Gscan2pdf::Document::exec_command( [ 'tesseract', '--list-langs' ] );
        @codes = split /\n/xsm, $err ? $err : $out;
        if ( $codes[0] =~ /^List[ ]of[ ]available[ ]languages/xsm ) {
            shift @codes;
        }

        for (@codes) {
            $logger->info("Found tesseract language $_");
            if ( defined $iso639{$_} ) {
                $languages{$_} = $iso639{$_};
            }
            else {
                $languages{$_} = $_;
            }
        }
    }
    return \%languages;
}

sub hocr {
    my ( $class, %options ) = @_;
    my ( $tif, $cmd, $name, $path, $txt );
    if ( not $setup ) { Gscan2pdf::Tesseract->setup( $options{logger} ) }

    if ( $version >= version->parse('v3.03.00') ) {
        $name = 'stdout';
        $path = $EMPTY;
    }
    else {
        # Temporary filename for output
        my $suffix = '.html';
        $txt = File::Temp->new( SUFFIX => $suffix );
        ( $name, $path, undef ) = fileparse( $txt, $suffix );
    }

    if ( defined $options{threshold} and $options{threshold} ) {

        # Temporary filename for new file
        $tif = File::Temp->new( SUFFIX => '.tif' );
        my $image = Image::Magick->new;
        $image->Read( $options{file} );

        my $x;
        if ( defined $options{threshold} and $options{threshold} ) {
            $logger->info("thresholding at $options{threshold} to $tif");
            $image->BlackThreshold( threshold => "$options{threshold}%" );
            $image->WhiteThreshold( threshold => "$options{threshold}%" );
            $x = $image->Set( alpha => 'Off' );
            $x = $image->Quantize( colors => 2 );
            $x = $image->Write( depth => 1, filename => $tif );
        }
        else {
            $logger->info("writing temporary image $tif");
            $x = $image->Write( filename => $tif );
        }
        if ("$x") { $logger->warn($x) }
    }
    else {
        $tif = $options{file};
    }
    if ( $version > version->parse('v3.05.00') ) {
        $cmd = [
            'tesseract', $tif,
            $path . $name,      '--dpi', $options{dpi}, '-l',
            $options{language}, '-c',
            'tessedit_create_hocr=1',

        ];
    }
    else {
        $cmd = [
            'tesseract',        $tif, $path . $name, '-l',
            $options{language}, '-c', 'tessedit_create_hocr=1',
        ];
    }

    my ( undef, $out, $err ) =
      Gscan2pdf::Document::exec_command( $cmd, $options{pidfile} );
    my $warnings = ( $out ? $name ne 'stdout' : $EMPTY ) . $err;
    my $leading  = 'Tesseract Open Source OCR Engine';
    my $trailing = 'with Leptonica';
    $warnings =~ s/$leading v\d[.]\d\d $trailing\n//xsm;
    $warnings =~ s/^Page[ ][01]\n//xsm;

    if ( $name eq 'stdout' ) {
        return Encode::decode_utf8($out), $warnings;
    }
    return Gscan2pdf::Document::slurp($txt), $warnings;
}

1;

__END__
