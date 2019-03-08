use warnings;
use strict;
use Test::More tests => 1;
use Gtk3 -init;    # Could just call init separately

BEGIN {
    use Gscan2pdf::Document;
}

#########################

SKIP: {
    skip 'pdftk not installed', 1 unless `which pdftk`;

    Gscan2pdf::Translation::set_domain('gscan2pdf');

    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($WARN);
    my $logger = Log::Log4perl::get_logger;
    Gscan2pdf::Document->setup($logger);

    # Create test image
    system('convert rose: test.jpg');

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);

    $slist->import_files(
        paths             => ['test.jpg'],
        finished_callback => sub {
            $slist->save_pdf(
                path              => 'test.pdf',
                options           => { 'user-password' => '123' },
                list_of_pages     => [ $slist->{data}[0][2]{uuid} ],
                finished_callback => sub {
                    is(
                        `pdfinfo test.pdf 2>&1`,
                        "Command Line Error: Incorrect password\n",
                        'created encrypted PDF'
                    );
                    Gtk3->main_quit;
                }
            );
        }
    );
    Gtk3->main;

#########################

    unlink 'test.jpg', 'test.pdf';
    Gscan2pdf::Document->quit();
}
