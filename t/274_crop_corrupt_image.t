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
system(qw(convert rose: test.gif));

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test.gif'],
    finished_callback => sub {

        # Now we've imported it,
        # remove the data to give a corrupt image
        system("echo '' > $slist->{data}[0][2]->{filename}");
        $slist->crop(
            page              => $slist->{data}[0][2]{uuid},
            x                 => 10,
            y                 => 10,
            w                 => 10,
            h                 => 10,
            finished_callback => sub {
                fail('caught errors from crop');
                Gtk3->main_quit;
            },
            error_callback => sub {
                pass('caught errors from crop');
                Gtk3->main_quit;
            }
        );
    }
);
Gtk3->main;

#########################

unlink 'test.gif', <$dir/*>;
rmdir $dir;
Gscan2pdf::Document->quit();
