use warnings;
use strict;
use File::Basename;    # Split filename into dir, file, ext
use IPC::System::Simple qw(system);
use Test::More tests => 1;

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;    # Could just call init separately
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($FATAL);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system(qw(convert rose: test.png));

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths           => ['test.png'],
    queued_callback => sub {

        # inject error during import_file
        chmod 0500, $dir;    # no write access
    },
    error_callback => sub {
        pass('import_file caught error injected in queue');
        Gtk3->main_quit;
    },
    finished_callback => sub {
        fail('import_file caught error injected in queue');
        Gtk3->main_quit;
    },
);
Gtk3->main;
chmod 0700, $dir;            # allow write access

#########################

unlink 'test.png', <$dir/*>;
rmdir $dir;
Gscan2pdf::Document->quit();
