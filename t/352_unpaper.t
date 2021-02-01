use warnings;
use strict;
use File::Basename;    # Split filename into dir, file, ext
use IPC::Cmd qw(can_run);
use IPC::System::Simple qw(system);
use Test::More tests => 3;

BEGIN {
    use Gscan2pdf::Document;
    use Gscan2pdf::Unpaper;
    use Gtk3 -init;    # Could just call init separately
}

SKIP: {
    skip 'unpaper not installed', 3 unless can_run('unpaper');
    Gscan2pdf::Translation::set_domain('gscan2pdf');
    my $unpaper = Gscan2pdf::Unpaper->new;

    use Log::Log4perl qw(:easy);

    Log::Log4perl->easy_init($WARN);
    my $logger = Log::Log4perl::get_logger;
    Gscan2pdf::Document->setup($logger);

    my %paper_sizes = (
        A4 => {
            x => 210,
            y => 297,
            l => 0,
            t => 0,
        },
        'US Letter' => {
            x => 216,
            y => 279,
            l => 0,
            t => 0,
        },
        'US Legal' => {
            x => 216,
            y => 356,
            l => 0,
            t => 0,
        },
    );

    # Create test image
    system(
        qw(convert -size 2550x3507 +matte -depth 1 -border 2x2 -bordercolor black -pointsize 12 -density 300),
        'label:The quick brown fox',
        'test.pnm'
    );

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);
    $slist->set_paper_sizes( \%paper_sizes );

    $slist->import_files(
        paths             => ['test.pnm'],
        finished_callback => sub {
            is( $slist->{data}[0][2]{xresolution},
                72, 'non-standard size pnm imports with 72 PPI' );
            $slist->{data}[0][2]{xresolution} = 300;
            is( $slist->{data}[0][2]{xresolution},
                300,
                'simulated having imported non-standard pnm with 300 PPI' );
            $slist->unpaper(
                page              => $slist->{data}[0][2]{uuid},
                options           => { command => $unpaper->get_cmdline },
                finished_callback => sub {
                    is( $slist->{data}[0][2]{xresolution},
                        300, 'Resolution of processed image' );
                    Gtk3->main_quit;
                }
            );
        }
    );
    Gtk3->main;

    unlink 'test.pnm', <$dir/*>;
    rmdir $dir;
    Gscan2pdf::Document->quit();
}
