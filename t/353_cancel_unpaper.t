use warnings;
use strict;
use IPC::Cmd qw(can_run);
use IPC::System::Simple qw(system capture);
use Test::More tests => 2;

BEGIN {
    use Gscan2pdf::Document;
    use Gscan2pdf::Unpaper;
    use Gtk3 -init;    # Could just call init separately
}

#########################

SKIP: {
    skip 'unpaper not installed', 2 unless can_run('unpaper');
    Gscan2pdf::Translation::set_domain('gscan2pdf');
    my $unpaper =
      Gscan2pdf::Unpaper->new( { 'output-pages' => 2, layout => 'double' } );

    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($WARN);
    my $logger = Log::Log4perl::get_logger;
    Gscan2pdf::Document->setup($logger);

    # Create test image
    system(
        qw(convert +matte -depth 1 -border 2x2 -bordercolor black), '-family', 'DejaVu Sans', qw(-pointsize 12 -density 300),
        'label:The quick brown fox',
        '1.pnm'
    );
    system(
        qw(convert +matte -depth 1 -border 2x2 -bordercolor black), '-family', 'DejaVu Sans', qw(-pointsize 12 -density 300),
        'label:The slower lazy dog',
        '2.pnm'
    );
    system(qw(convert -size 100x100 xc:black black.pnm));
    system(qw(convert 1.pnm black.pnm 2.pnm +append test.pnm));

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);

    $slist->import_files(
        paths             => ['test.pnm'],
        finished_callback => sub {
            my $md5sum =
              capture("md5sum $slist->{data}[0][2]{filename} | cut -c -32");
            $slist->unpaper(
                page              => $slist->{data}[0][2]{uuid},
                options           => { command => $unpaper->get_cmdline },
                finished_callback => sub { ok 0, 'Finished callback' }
            );
            $slist->cancel(
                sub {
                    is(
                        $md5sum,
                        capture(
                            "md5sum $slist->{data}[0][2]{filename} | cut -c -32"
                        ),
                        'image not modified'
                    );
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

    is( system(qw(identify test.jpg)),
        0, 'can create a valid JPG after cancelling previous process' );

    unlink 'test.pnm', '1.pnm', '2.pnm', 'black.pnm', 'test.jpg';
    Gscan2pdf::Document->quit();
}
