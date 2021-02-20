use warnings;
use strict;
use Encode;
use IPC::Cmd qw(can_run);
use Test::More tests => 4;

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;    # Could just call init separately
}

#########################

SKIP: {
    skip 'gocr not installed', 4 unless can_run('gocr');

    Gscan2pdf::Translation::set_domain('gscan2pdf');
    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($WARN);
    my $logger = Log::Log4perl::get_logger;
    Gscan2pdf::Document->setup($logger);

    # Create test image
    system(
'convert +matte -depth 1 -family "DejaVu Sans" -pointsize 12 -density 300 label:"öÖäÄüÜß" test.pnm'
    );

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);

    $slist->import_files(
        paths             => ['test.pnm'],
        finished_callback => sub {
            $slist->gocr(
                page              => $slist->{data}[0][2]{uuid},
                finished_callback => sub {
                    is( Encode::is_utf8( $slist->{data}[0][2]{hocr}, 1 ),
                        1, "gocr returned UTF8" );
                    for my $c (qw( ö ä ü ))
                    {    # ignoring ß, as gocr doesn't recognise it
                        my $c2 = decode_utf8($c);
                        like( $slist->{data}[0][2]{hocr},
                            qr/$c2/, "gocr returned $c" );
                    }
                    Gtk3->main_quit;
                }
            );
        }
    );
    Gtk3->main;

    unlink 'test.pnm';
    Gscan2pdf::Document->quit();
}
