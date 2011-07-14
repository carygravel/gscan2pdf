# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Gscan2pdf.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 1;
BEGIN {
  use Gscan2pdf;
  use Gscan2pdf::Document;
};

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

SKIP: {
 skip 'gocr not installed', 1 unless (system("which gocr > /dev/null 2> /dev/null") == 0);

 use Log::Log4perl qw(:easy);
 Log::Log4perl->easy_init($DEBUG);
 our $logger = Log::Log4perl::get_logger;
 my $prog_name = 'gscan2pdf';
 use Locale::gettext 1.05;    # For translations
 our $d = Locale::gettext->domain($prog_name);
 Gscan2pdf->setup($d, $logger);

 # Create test image
 system('convert +matte -depth 1 -pointsize 12 -density 300 label:"The quick brown fox" test.pnm');

 my $slist = Gscan2pdf::Document->new;
 $slist->get_file_info( 'test.pnm', sub {}, sub {}, sub {
  $slist->import_file( $Gscan2pdf::_self->{data_queue}->dequeue, 1, 1, sub {}, sub {}, sub {
   $slist->gocr( $slist->{data}[0][2], sub {}, sub {}, sub {
    like( $slist->{data}[0][2]{hocr}, qr/The quick brown fox/, 'gocr returned sensible text' );
    Gtk2->main_quit;
   });
  })
 });
 Gtk2->main;

 unlink 'test.pnm';
 Gscan2pdf->kill();
}
