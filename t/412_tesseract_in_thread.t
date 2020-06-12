use warnings;
use strict;
use File::Basename;    # Split filename into dir, file, ext
use Test::More tests => 6;

BEGIN {
    use Gscan2pdf::Document;
    use_ok('Gscan2pdf::Tesseract');
    use Gtk3 -init;    # Could just call init separately
}

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($ERROR);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

SKIP: {
    skip 'Tesseract not installed', 5
      unless Gscan2pdf::Tesseract->setup($logger);

    # Create test image
    # Deliberately not setting -units to provoke
    # "Invalid resolution 0 dpi. Using 70 instead." warning from tesseract,
    # which should no longer occur, since v2.8.1 added --dpi to the tesseract
    # call
    system(
'convert +matte -depth 1 -colorspace Gray -pointsize 12 -density 300 label:"The quick brown fox" test.png'
    );

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);

    $slist->import_files(
        paths             => ['test.png'],
        finished_callback => sub {
            $slist->tesseract(
                page           => $slist->{data}[0][2]{uuid},
                language       => 'eng',
                error_callback => sub {
                    fail('error thrown running tesseract');
                },
                finished_callback => sub {
                    like( $slist->{data}[0][2]{hocr},
                        qr/T[hn]e/, 'Tesseract returned "The"' );
                    like( $slist->{data}[0][2]{hocr},
                        qr/quick/, 'Tesseract returned "quick"' );
                    like( $slist->{data}[0][2]{hocr},
                        qr/brown/, 'Tesseract returned "brown"' );
                    like( $slist->{data}[0][2]{hocr},
                        qr/f(o|0)x/, 'Tesseract returned "fox"' );
                    is( dirname("$slist->{data}[0][2]{filename}"),
                        "$dir", 'using session directory' );
                    Gtk3->main_quit;
                }
            );
        }
    );
    Gtk3->main;

    unlink 'test.png', <$dir/*>;
    rmdir $dir;
}

Gscan2pdf::Document->quit();
