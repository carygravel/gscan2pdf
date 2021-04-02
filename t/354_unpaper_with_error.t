use warnings;
use strict;
use IPC::Cmd qw(can_run);
use IPC::System::Simple qw(system);
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
    my $unpaper = Gscan2pdf::Unpaper->new;

    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($FATAL);
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
    my $filename = 'test.png';
    system(
        qw(convert -size 2100x2970 +matte -depth 1 -border 2x2 -bordercolor black),
        '-family', 'DejaVu Sans',
        qw(-pointsize 12 -density 300),
        "label:'The quick brown fox'", $filename
    );

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);
    $slist->set_paper_sizes( \%paper_sizes );

    $slist->import_files(
        paths             => [$filename],
        finished_callback => sub {

            # inject error before unpaper
            chmod 0500, $dir;    # no write access

            $slist->unpaper(
                page           => $slist->{data}[0][2]{uuid},
                options        => { command => $unpaper->get_cmdline },
                error_callback => sub {
                    pass('caught error injected before unpaper');
                    chmod 0700, $dir;    # allow write access

                    $slist->unpaper(
                        page            => $slist->{data}[0][2]{uuid},
                        options         => { command => $unpaper->get_cmdline },
                        queued_callback => sub {

                            # inject error during unpaper
                            chmod 0500, $dir;    # no write access
                        },
                        error_callback => sub {
                            pass('unpaper caught error injected in queue');
                            chmod 0700, $dir;    # allow write access
                            Gtk3->main_quit;
                        }
                    );

                }
            );
        }
    );
    Gtk3->main;

#########################

    unlink $filename, <$dir/*>;
    rmdir $dir;

    Gscan2pdf::Document->quit();
}
