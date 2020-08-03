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

our $VERSION = '2.8.2';
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

        # Taken from
        # https://github.com/tesseract-ocr/tesseract/blob/master/doc/tesseract.1.asc#languages
        my %iso639 = (
            afr            => 'Afrikaans',
            amh            => 'Amharic',
            ara            => 'Arabic',
            asm            => 'Assamese',
            aze            => 'Azerbaijani',
            'aze-cyrl'     => 'Azerbaijani (Cyrillic)',
            bel            => 'Belarusian',
            ben            => 'Bengali',
            bod            => 'Tibetan Standard',
            bos            => 'Bosnian',
            bre            => 'Breton',
            bul            => 'Bulgarian',
            cat            => 'Catalan',
            ceb            => 'Cebuano',
            ces            => 'Czech',
            'chi-sim'      => 'Simplified Chinese',
            'chi-sim-vert' => 'Chinese - Simplified (vertical)',
            'chi-tra'      => 'Traditional Chinese',
            'chi-tra-vert' => 'Traditional Chinese (vertical)',
            chr            => 'Cherokee',
            cos            => 'Corsican',
            cym            => 'Welsh',
            dan            => 'Danish',
            'dan-frak'     => 'Danish (Fraktur)',
            deu            => 'German',
            'deu-frak'     => 'German (Fraktur)',
            div            => 'Divehi',
            dzo            => 'Dzongkha',
            ell            => 'Greek',
            eng            => 'English',
            enm            => 'English, Middle (1100-1500)',
            epo            => 'Esperanto',
            equ            => 'equations',
            est            => 'Estonian',
            eus            => 'Basque',
            fao            => 'Faroese',
            fas            => 'Persian',
            fil            => 'Filipino',
            fin            => 'Finish',
            fra            => 'French',
            frk            => 'German (Fraktur)',
            frm            => 'French, Middle (ca.1400-1600)',
            fry            => 'Frisian (Western)',
            gla            => 'Gaelic (Scots)',
            gle            => 'Irish',
            'gle-uncial'   => 'Irish (Uncial)',
            glg            => 'Galician',
            grc            => 'Greek, Ancient (to 1453)',
            guj            => 'Gujarati',
            hat            => 'Haitian',
            heb            => 'Hebrew',
            hin            => 'Hindi',
            hrv            => 'Croatian',
            hun            => 'Hungarian',
            hye            => 'Armenian',
            iku            => 'Inuktitut',
            ind            => 'Indonesian',
            isl            => 'Icelandic',
            ita            => 'Italian',
            'ita-old'      => 'Italian - Old',
            jav            => 'Javanese',
            jpn            => 'Japanese',
            'jpn-vert'     => 'Japanese (vertical)',
            kan            => 'Kannada',
            kat            => 'Georgian',
            'kat-old'      => 'Old Georgian',
            kaz            => 'Kazakh',
            khm            => 'Khmer',
            kir            => 'Kyrgyz',
            kmr            => 'Kurmanji (Latin)',
            kor            => 'Korean',
            'kor-vert'     => 'Korean (vertical)',
            lao            => 'Lao',
            lat            => 'Latin',
            lav            => 'Latvian',
            lit            => 'Lithuanian',
            ltz            => 'Luxembourgish',
            mal            => 'Malayalam',
            mar            => 'Marathi',
            mkd            => 'Macedonian',
            mlt            => 'Maltese',
            mon            => 'Mongolian',
            mri            => 'Maori',
            msa            => 'Malay',
            mya            => 'Burmese',
            nep            => 'Nepali',
            nld            => 'Dutch',
            nor            => 'Norwegian',
            oci            => 'Occitan (post 1500)',
            ori            => 'Oriya',
            pan            => 'Punjabi',
            pol            => 'Polish',
            por            => 'Portuguese',
            pus            => 'Pashto',
            que            => 'Quechua',
            ron            => 'Romanian',
            rus            => 'Russian',
            san            => 'Sanskrit',
            sin            => 'Sinhalese',
            slk            => 'Slovak',
            'slk-frak'     => 'Slovak (Fraktur)',
            slv            => 'Slovenian',
            snd            => 'Sindhi',
            spa            => 'Spanish',
            spa_old        => 'Spanish (Castilian - Old)',
            sqi            => 'Albanian',
            srp            => 'Serbian',
            srp_latn       => 'Serbian - Latin',
            sun            => 'Sundanese',
            swa            => 'Swahili',
            swe            => 'Swedish',
            'swe-frak'     => 'Swedish (Fraktur)',
            syr            => 'Syriac',
            tam            => 'Tamil',
            tat            => 'Tatar',
            tel            => 'Telugu',
            tgk            => 'Tajik',
            tgl            => 'Tagalog',
            tha            => 'Thai',
            tir            => 'Tigrinya',
            ton            => 'Tonga',
            tur            => 'Turkish',
            uig            => 'Uighur',
            ukr            => 'Ukranian',
            urd            => 'Urdu',
            uzb            => 'Uzbek',
            uzb_cyrl       => 'Uzbek - Cyrilic',
            vie            => 'Vietnamese',
            yid            => 'Yiddish',
            yor            => 'Yoruba',
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
