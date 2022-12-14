use warnings;
use strict;
use File::Basename;    # Split filename into dir, file, ext
use IPC::System::Simple qw(system);
use Test::More tests => 2;

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
system(qw(convert xc:black black.pnm));

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['black.pnm'],
    finished_callback => sub {
        $slist->analyse(
            list_of_pages     => [ $slist->{data}[0][2]{uuid} ],
            finished_callback => sub {
                is( $slist->{data}[0][2]{mean}, 0, 'Found dark page' );
                is( dirname("$slist->{data}[0][2]{filename}"),
                    "$dir", 'using session directory' );
                Gtk3->main_quit;
            }
        );
    }
);
Gtk3->main;

#########################

unlink 'black.pnm', <$dir/*>;
rmdir $dir;
Gscan2pdf::Document->quit();
