use warnings;
use strict;
use IPC::System::Simple qw(system);
use Test::More tests => 2;

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
system(qw(convert rose: test.pnm));

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test.pnm'],
    finished_callback => sub {

        # inject error before save_tiff
        chmod 0500, $dir;    # no write access

        $slist->save_tiff(
            path           => 'test.tiff',
            list_of_pages  => [ $slist->{data}[0][2]{uuid} ],
            error_callback => sub {
                pass('caught error injected before save_tiff');
                chmod 0700, $dir;    # allow write access

                $slist->save_tiff(
                    path            => 'test.tiff',
                    list_of_pages   => [ $slist->{data}[0][2]{uuid} ],
                    queued_callback => sub {

                        # inject error during save_tiff
                        chmod 0500, $dir;    # no write access
                    },
                    error_callback => sub {
                        pass('save_tiff caught error injected in queue');
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

unlink 'test.pnm', 'test.tiff';
Gscan2pdf::Document->quit();
