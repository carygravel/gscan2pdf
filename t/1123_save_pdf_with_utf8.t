use warnings;
use strict;
use Test::More tests => 1;

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;    # Could just call init separately
    use PDF::API2;
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system('convert rose: test.pnm');

my %options;
$options{font} = `fc-list :lang=ru file | grep ttf 2> /dev/null | head -n 1`;
chomp $options{font};
$options{font} =~ s/: $//;

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test.pnm'],
    finished_callback => sub {
        use utf8;
        $slist->{data}[0][2]{hocr} =
          'пени способствовала сохранению';
        $slist->save_pdf(
            path              => 'test.pdf',
            list_of_pages     => [ $slist->{data}[0][2]{uuid} ],
            options           => \%options,
            finished_callback => sub { Gtk3->main_quit }
        );
    }
);
Gtk3->main;

like(
    `pdftotext test.pdf -`,
    qr/пени способствовала сохранению/,
    'PDF with expected text'
);

#########################

unlink 'test.pnm', 'test.pdf';
Gscan2pdf::Document->quit();
