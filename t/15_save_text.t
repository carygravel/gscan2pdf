# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Gscan2pdf.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use Test::More tests => 3;
BEGIN {
  use_ok('Gscan2pdf');
  use_ok('Gscan2pdf::Document');
};

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

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
system('convert rose: test.pnm');

my $slist = Gscan2pdf::Document->new;
$slist->get_file_info( 'test.pnm', sub { $slist->import_file( $Gscan2pdf::_self->{data_queue}->dequeue, 1, 1, sub {
  $slist->{data}[0][2]{hocr} = 'The quick brown fox';
  $slist->save_text('test.txt', [ $slist->{data}[0][2] ], sub {Gtk2->main_quit}, sub {}, sub {});
}, sub {}, sub {} ) }, sub {}, sub{} );
Gtk2->main;

is( -s 'test.txt', 19, 'TXT created with expected size' );

#########################

unlink 'test.pnm', 'test.txt';
Gscan2pdf->kill();
