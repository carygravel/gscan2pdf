use warnings;
use strict;
use Date::Calc qw(Date_to_Time);
use File::stat;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Test::More tests => 3;

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;         # Could just call init separately
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
my $pnm  = 'test.pnm';
my $djvu = 'test.djvu';
system('convert rose: test.pnm');

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

my %metadata =
  ( datetime => [ 2016, 2, 10, 0, 0, 0 ], title => 'metadata title' );
$slist->import_files(
    paths             => [$pnm],
    finished_callback => sub {
        $slist->save_djvu(
            path          => $djvu,
            list_of_pages => [ $slist->{data}[0][2]{uuid} ],
            metadata      => \%metadata,
            options       => {
                set_timestamp => TRUE,
            },
            finished_callback => sub { Gtk3->main_quit }
        );
    }
);
Gtk3->main;

my $info = `djvused $djvu -e 'print-meta'`;
like( $info, qr/metadata title/, 'metadata in DjVu' );
like( $info, qr/2016-02-10/,     'metadata ModDate in DjVu' );
my $sb = stat($djvu);
is( $sb->mtime, Date_to_Time( 2016, 2, 10, 0, 0, 0 ), 'timestamp' );

#########################

unlink $pnm, $djvu;
Gscan2pdf::Document->quit();
