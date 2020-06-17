use warnings;
use strict;
use Test::More tests => 3;
use File::Basename;    # Split filename into dir, file, ext

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;    # Could just call init separately
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system('convert rose: test.pnm');

my $slist = Gscan2pdf::Document->new;
$slist->set_dir( File::Temp->newdir );
$slist->import_files(
    paths             => ['test.pnm'],
    finished_callback => sub {
        $slist->{data}[0][2]{hocr} = 'The quick brown fox';
        $slist->save_session('test.gs2p');
        is $slist->scans_saved, 1, 'pages tagged as saved';
        Gtk3->main_quit;
    }
);
Gtk3->main;

like(
    `file test.gs2p`,
    qr/test.gs2p: gzip compressed data(?:, original size 9728)?/,
    'Session file created'
);
cmp_ok( -s 'test.gs2p', '>', 0, 'Non-empty Session file created' );

#########################

Gscan2pdf::Document->quit();
unlink 'test.pnm';
