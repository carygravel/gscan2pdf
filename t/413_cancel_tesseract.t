use warnings;
use strict;
use IPC::System::Simple qw(system);
use Test::More tests => 2;

BEGIN {
    use Gscan2pdf::Document;
    use Gscan2pdf::Tesseract;
    use Gtk3 -init;    # Could just call init separately
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($ERROR);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

SKIP: {
    skip 'Tesseract not installed', 2
      unless Gscan2pdf::Tesseract->setup($logger);

    # Create test image
    system(
        qw(convert +matte -depth 1 -colorspace Gray -pointsize 12 -density 300),
        'label:The quick brown fox',
        'test.tif'
    );

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);

    $slist->import_files(
        paths             => ['test.tif'],
        finished_callback => sub {
            $slist->tesseract(
                page              => $slist->{data}[0][2]{uuid},
                language          => 'eng',
                finished_callback => sub { ok 0, 'Finished callback' }
            );
            $slist->cancel(
                sub {
                    is( $slist->{data}[0][2]{hocr}, undef, 'no OCR output' );
                    $slist->save_image(
                        path              => 'test.jpg',
                        list_of_pages     => [ $slist->{data}[0][2]{uuid} ],
                        finished_callback => sub { Gtk3->main_quit }
                    );
                }
            );
        }
    );
    Gtk3->main;

    is( system('identify test.jpg'),
        0, 'can create a valid JPG after cancelling previous process' );

    unlink 'test.tif', 'test.jpg';
}

Gscan2pdf::Document->quit();
