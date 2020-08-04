package Gscan2pdf::Tesseract;

use 5.008005;
use strict;
use warnings;
use Carp;
use Encode;
use File::Temp;    # To create temporary files
use File::Basename;
use Gscan2pdf::Document;    # for slurp
use version;
use English qw( -no_match_vars );    # for $PROCESS_ID
use Gscan2pdf::Translation '__';     # easier to extract strings with xgettext
use Locale::Language;

our $VERSION = '2.8.2';
my $EMPTY = q{};
my $COMMA = q{,};

my ( %languages, %installable_languages, $installed, $setup, $version,
    $logger );

# Taken from
# https://github.com/tesseract-ocr/tesseract/blob/master/doc/tesseract.1.asc#languages
my @installable_languages =
  qw(afr amh ara asm aze aze-cyrl bel ben bod bos bre bul cat ceb ces chi-sim chi-sim-vert chi-tra chi-tra-vert chr cos cym dan dan-frak deu deu-frak div dzo ell eng enm epo equ est eus fao fas fil fin fra frk frm fry gla gle gle-uncial glg grc guj hat heb hin hrv hun hye iku ind isl ita ita-old jav jpn jpn-vert kan kat kat-old kaz khm kir kmr kor kor-vert lao lat lav lit ltz mal mar mkd mlt mon mri msa mya nep nld nor oci ori pan pol por pus que ron rus san sin slk slk-frak slv snd spa spa_old sqi srp srp_latn sun swa swe swe-frak syr tam tat tel tgk tgl tha tir ton tur uig ukr urd uzb uzb_cyrl vie yid yor);
my %non_iso639_3 = (
    'aze-cyrl'     => 'Azerbaijani (Cyrillic)',
    'chi-sim'      => 'Simplified Chinese',
    'chi-sim-vert' => 'Chinese - Simplified (vertical)',
    'chi-tra'      => 'Traditional Chinese',
    'chi-tra-vert' => 'Traditional Chinese (vertical)',
    'dan-frak'     => 'Danish (Fraktur)',
    'deu-frak'     => 'German (Fraktur)',
    equ            => 'equations',
    'gle-uncial'   => 'Irish (Uncial)',
    'ita-old'      => 'Italian - Old',
    'jpn-vert'     => 'Japanese (vertical)',
    'kat-old'      => 'Old Georgian',
    'kor-vert'     => 'Korean (vertical)',
    osd            => 'Orientation, script, direction',
    'slk-frak'     => 'Slovak (Fraktur)',
    spa_old        => 'Spanish (Castilian - Old)',
    srp_latn       => 'Serbian - Latin',
    'swe-frak'     => 'Swedish (Fraktur)',
    uzb_cyrl       => 'Uzbek - Cyrilic',
);
my %non_iso639_1 = ( zh => 'chi-sim', );

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
    if ( not $version )                 { return }
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
        my @codes;
        my ( undef, $out, $err ) =
          Gscan2pdf::Document::exec_command( [ 'tesseract', '--list-langs' ] );
        @codes = split /\n/xsm, $err ? $err : $out;
        if ( $codes[0] =~ /^List[ ]of[ ]available[ ]languages/xsm ) {
            shift @codes;
        }
        for my $code (@codes) {
            my $name = code2language( $code, 'term' );
            if ( not defined $name ) {
                $name = $non_iso639_3{$code};
            }
            if ( not defined $name ) {
                $name = $code;
            }
            $logger->info("Found tesseract language $code ($name)");
            $languages{$code} = $name;
        }
    }
    return \%languages;
}

sub installable_languages {
    if ( not %installable_languages ) {
        %installable_languages = %non_iso639_3;
        for my $code (@installable_languages) {
            my $language = code2language( $code, 'term' );
            if ( not defined $language ) {
                $language = $non_iso639_3{$code};
            }
            $installable_languages{$code} = $language;
        }
    }
    return \%installable_languages;
}

sub _iso639_1to3 {
    my ($code1) = @_;
    my $code3 = $non_iso639_1{$code1};
    if ($code3) { return $code3 }
    return language_code2code( $code1, 'alpha-2', 'term' );
}

sub locale_installed {
    my ( $class, $locale ) = @_;
    my $code1     = lc substr $locale, 0, 2;
    my $code3     = _iso639_1to3($code1);
    my $languages = languages();
    if ( not defined $code3 ) {
        return
          sprintf( __("You are using locale '%s'."), $locale ) . q{ }
          . __(
'gscan2pdf does not currently know which tesseract language package would be necessary for that locale.'
          )
          . q{ }
          . __('Please contact the developers to add support for that locale.');
    }
    if ( defined $languages->{$code3} ) {
        return 1;
    }
    $languages = installable_languages();
    if ( defined $languages->{$code3} ) {
        return
          sprintf( __("You are using locale '%s'."), $locale ) . q{ }
          . sprintf __(
"Please install tesseract package 'tesseract-ocr-%s' and restart gscan2pdf for OCR for %s with tesseract."
          ), $code3, $languages->{$code3};
    }
    return
        sprintf( __("You are using locale '%s'."), $locale ) . q{ }
      . sprintf __('There is no tesseract package for %s'),
      code2language( $code3, 'term' ) . '. '
      . 'If this is in error, please contact the gscan2pdf developers.';
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
