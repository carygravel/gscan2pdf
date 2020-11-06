use warnings;
use strict;
use File::Temp;
use IPC::System::Simple qw(system);
use Test::More tests => 1;

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
system(qw(convert rose: test.tif));
system(qw(tiffcp test.tif test.tif test2.tif));

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test2.tif'],
    finished_callback => sub {
        is( $#{ $slist->{data} }, 1, 'imported 2 pages' );
        Gtk3->main_quit;
    }
);
Gtk3->main;

#########################

unlink 'test.tif', 'test2.tif', <$dir/*>;
rmdir $dir;
Gscan2pdf::Document->quit();
