use warnings;
use strict;
use IPC::System::Simple qw(system);
use Test::More tests => 8;

BEGIN {
    use_ok('Gscan2pdf::Cuneiform');
    use Encode;
}

#########################

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;

SKIP: {
    skip 'Cuneiform not installed', 7
      unless Gscan2pdf::Cuneiform->setup($logger);

    # Create test image
    system(
        qw(convert +matte -depth 1),
        '-family',
        'DejaVu Sans',
        qw(-pointsize 12 -density 300),
        'label:The quick brown fox',
        'test.png'
    );

    my $got = Gscan2pdf::Cuneiform->hocr(
        file     => 'test.png',
        language => 'eng',
        logger   => $logger
    );

    like( $got, qr/The quick brown fox/, 'Cuneiform returned sensible text' );

    # Create colour test image
    system(
        qw(convert -fill lightblue),
        '-family',
        'DejaVu Sans',
        qw(-pointsize 12 -density 300),
        'label:The quick brown fox',
        'test.png'
    );

    $got = Gscan2pdf::Cuneiform->hocr(
        file      => 'test.png',
        language  => 'eng',
        logger    => $logger,
        threshold => 95
    );

    like(
        $got,
        qr/The quick brown fox/,
        'Cuneiform returned sensible text after thresholding'
    );

    # Create test image
    system(
        qw(convert +matte -depth 1),
        '-family',
        'DejaVu Sans',
        qw(-font DejaVu-Sans -pointsize 12 -density 300 label:'öÖäÄüÜß' test.png)
    );

    $got = Gscan2pdf::Cuneiform->hocr(
        file     => 'test.png',
        language => 'ger',
        logger   => $logger
    );
    is( Encode::is_utf8( $got, 1 ), 1, "Cuneiform returned UTF8" );
    for my $c (qw( ö ä ü )) {
        my $c2 = decode_utf8($c);
        like( $got, qr/$c2/, "Cuneiform returned $c" );
    }

    $got = Gscan2pdf::Cuneiform->hocr(
        file     => 'test.png',
        language => 'deu',
        logger   => $logger
    );
    my $c = decode_utf8('ö');
    like( $got, qr/$c/, "understands iso639" );

    unlink 'test.png';
}
