use warnings;
use strict;
use Test::More tests => 1;

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;    # Could just call init separately
    use PDF::API2;
    use File::Copy;
    use utf8;
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system('convert rose: 1.pnm');

# number of pages
my $n = 3;

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

my @files;
for my $i ( 1 .. $n ) {
    copy( '1.pnm', "$i.pnm" ) if ( $i > 1 );
    push @files, "$i.pnm";
}
$slist->import_files(
    paths             => \@files,
    finished_callback => sub {
        my @pages;
        for my $i ( 1 .. $n ) {
            $slist->{data}[ $i - 1 ][2]{hocr} = 'hello world';
            push @pages, $slist->{data}[ $i - 1 ][2]{uuid};
        }
        $slist->save_pdf(
            path              => 'test.pdf',
            list_of_pages     => \@pages,
            finished_callback => sub { Gtk3->main_quit }
        );
    }
);
Gtk3->main;

is( `pdffonts test.pdf | grep -c Times-Roman` + 0,
    1, 'font embedded once in multipage PDF' );

#########################

for my $i ( 1 .. $n ) {
    unlink "$i.pnm";
}
unlink 'test.pdf';
Gscan2pdf::Document->quit();
