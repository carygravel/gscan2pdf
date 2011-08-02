# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Gscan2pdf.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 1;
BEGIN {
  use Gscan2pdf;
  use Gscan2pdf::Document;
  use Gscan2pdf::Cuneiform;
};

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

SKIP: {
 skip 'Cuneiform not installed', 1 unless Gscan2pdf::Cuneiform->setup;

 # Thumbnail dimensions
 our $widtht  = 100;
 our $heightt = 100;

 use Log::Log4perl qw(:easy);
 Log::Log4perl->easy_init($DEBUG);
 our $logger = Log::Log4perl::get_logger;
 my $prog_name = 'gscan2pdf';
 use Locale::gettext 1.05;    # For translations
 our $d = Locale::gettext->domain($prog_name);
 Gscan2pdf->setup($d, $logger);

 # Create test image
 system('convert +matte -depth 1 -pointsize 12 -density 300 label:"The quick brown fox" test.bmp');

 my $slist = Gscan2pdf::Document->new;
 $slist->get_file_info( 'test.bmp', undef, undef, undef, sub {
  my ($info) = @_;
  $slist->import_file( $info, 1, 1, undef, undef, undef, sub {
   $slist->cuneiform( $slist->{data}[0][2], 'eng', undef, undef, undef, undef, undef, undef, sub {
    is( $slist->{data}[0][2]{hocr}, undef, 'no OCR output' );
    Gtk2->main_quit;
   });
   $slist->{cancelled} = 1;
  })
 });
 Gtk2->main;

 unlink 'test.bmp';
 Gscan2pdf->quit();
}