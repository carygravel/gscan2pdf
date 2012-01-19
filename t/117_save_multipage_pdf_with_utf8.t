# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Gscan2pdf.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use warnings;
use strict;
use Test::More tests => 1;

BEGIN {
 use Gscan2pdf;
 use Gscan2pdf::Document;
 use PDF::API2;
 use File::Copy;
}

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

# Thumbnail dimensions
our $widtht  = 100;
our $heightt = 100;

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
our $logger = Log::Log4perl::get_logger;
my $prog_name = 'gscan2pdf';
use Locale::gettext 1.05;    # For translations
our $d = Locale::gettext->domain($prog_name);
Gscan2pdf->setup( $d, $logger );

# Create test image
system('convert rose: 1.pnm');

# number of pages
my $n = 3;
my @pages;

my %options;
$options{font} = `fc-list : file | grep times.ttf`;
chomp $options{font};
$options{font} =~ s/: $//;

my $slist = Gscan2pdf::Document->new;
for my $i ( 1 .. $n ) {
 copy( '1.pnm', "$i.pnm" ) if ( $i > 1 );
 $slist->get_file_info(
  "$i.pnm", undef, undef, undef,
  sub {
   my ($info) = @_;
   $slist->import_file(
    $info, 1, 1, undef, undef, undef,
    sub {
     use utf8;
     $slist->{data}[ $i - 1 ][2]{hocr} =
       'пени способствовала сохранению';
     push @pages, $slist->{data}[ $i - 1 ][2];
     $slist->save_pdf( 'test.pdf', \@pages, undef, \%options, undef, undef,
      undef, sub { Gtk2->main_quit } )
       if ( $i == $n );
    }
   );
  }
 );
}
Gtk2->main;

is( `pdffonts test.pdf | grep -c TrueType` + 0,
 1, 'font embedded once in multipage PDF' );

#########################

for my $i ( 1 .. $n ) {
 unlink "$i.pnm";
}
unlink 'test.pdf';
Gscan2pdf->quit();