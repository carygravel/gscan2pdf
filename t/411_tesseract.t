use warnings;
use strict;
use Test::More tests => 14;

BEGIN {
    use_ok('Gscan2pdf::Tesseract');
    use Encode;
}

#########################

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;

SKIP: {
    skip 'Tesseract not installed', 13
      unless Gscan2pdf::Tesseract->setup($logger);

    # Create b&w test image
    system(
'convert +matte -depth 1 -colorspace Gray -pointsize 12 -density 300 label:"The quick brown fox" test.png'
    );

    my ( $got, $messages ) = Gscan2pdf::Tesseract->hocr(
        file     => 'test.png',
        language => 'eng',
        logger   => $logger,
        dpi      => 300,
    );

    like( $got, qr/T[hn]e/,  'Tesseract returned "The"' );
    like( $got, qr/quick/,   'Tesseract returned "quick"' );
    like( $got, qr/brown/,   'Tesseract returned "brown"' );
    like( $got, qr/f(o|0)x/, 'Tesseract returned "fox"' );

    # Create colour test image
    system(
'convert -fill lightblue -pointsize 12 -density 300 label:"The quick brown fox" test.png'
    );

    ( $got, $messages ) = Gscan2pdf::Tesseract->hocr(
        file      => 'test.png',
        language  => 'eng',
        logger    => $logger,
        threshold => 95,
        dpi       => 300,
    );

    like( $got, qr/The/,     'After thresholding, Tesseract returned "The"' );
    like( $got, qr/quick/,   'After thresholding, Tesseract returned "quick"' );
    like( $got, qr/brown/,   'After thresholding, Tesseract returned "brown"' );
    like( $got, qr/f(o|0)x/, 'After thresholding, Tesseract returned "fox"' );

    my $languages = Gscan2pdf::Tesseract->languages;
    skip 'German language pack for Tesseract not installed', 5
      unless ( defined $languages->{'deu'} );

    # Create b&w test image
    system(
"convert +matte -depth 1 -colorspace Gray -pointsize 12 -density 300 label:'süß tränenüberströmt' test.png"
    );

    ( $got, $messages ) = Gscan2pdf::Tesseract->hocr(
        file     => 'test.png',
        language => 'deu',
        logger   => $logger,
        dpi      => 300,
    );
    is( Encode::is_utf8( $got, 1 ), 1, "Tesseract returned UTF8" );
    for my $c (qw( ö ä ü ß )) {
        my $c2 = decode_utf8($c);
        like( $got, qr/$c2/, "Tesseract returned $c" );
    }

    unlink 'test.png';
}

__END__
