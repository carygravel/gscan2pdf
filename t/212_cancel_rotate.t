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
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system(qw(convert -units PixelsPerInch -density 70 rose: test.jpg));

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test.jpg'],
    finished_callback => sub {
        $slist->rotate(
            angle             => 90,
            page              => $slist->{data}[0][2]{uuid},
            finished_callback => sub { ok 0, 'Finished callback' }
        );
        $slist->cancel(
            sub {
                is(
                    -s 'test.jpg',
                    -s "$slist->{data}[0][2]{filename}",
                    'image not rotated'
                );
                $slist->save_image(
                    path              => 'test2.jpg',
                    list_of_pages     => [ $slist->{data}[0][2]{uuid} ],
                    finished_callback => sub { Gtk3->main_quit }
                );
            }
        );
    }
);
Gtk3->main;

is( system(qw(identify test2.jpg)),
    0, 'can create a valid JPG after cancelling previous process' );

#########################

unlink 'test.jpg', 'test2.jpg';
Gscan2pdf::Document->quit();
