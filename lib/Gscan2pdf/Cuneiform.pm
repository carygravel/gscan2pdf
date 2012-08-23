package Gscan2pdf::Cuneiform;

use 5.008005;
use strict;
use warnings;
use Carp;
use File::Temp;             # To create temporary files
use Gscan2pdf::Document;    # for slurp

my ( %languages, $installed, $setup, $logger );

sub setup {
 ( my $class, $logger ) = @_;
 return $installed if $setup;
 $installed = 1 if ( system("which cuneiform > /dev/null 2> /dev/null") == 0 );
 $setup = 1;
 return $installed;
}

sub languages {
 unless (%languages) {

  # cuneiform language codes
  my %lang = (
   eng    => 'English',
   ger    => 'German',
   fra    => 'French',
   rus    => 'Russian',
   swe    => 'Swedish',
   spa    => 'Spanish',
   ita    => 'Italian',
   ruseng => 'Russian+English',
   ukr    => 'Ukrainian',
   srp    => 'Serbian',
   hrv    => 'Croatian',
   pol    => 'Polish',
   dan    => 'Danish',
   por    => 'Portuguese',
   dut    => 'Dutch',
   cze    => 'Czech',
   rum    => 'Romanian',
   hun    => 'Hungarian',
   bul    => 'Bulgarian',
   slo    => 'Slovak',
   slv    => 'Slovenian',
   lav    => 'Latvian',
   lit    => 'Lithuanian',
   est    => 'Estonian',
   tur    => 'Turkish',
  );

  # Dig out supported languages
  my $cmd = "cuneiform -l";
  $logger->info($cmd);
  my $output = `$cmd`;

  my $langs;
  if ( $output =~ /Supported languages: (.*)\./ ) {
   $langs = $1;
   for ( split " ", $langs ) {
    if ( defined $lang{$_} ) {
     $languages{$_} = $lang{$_};
    }
    else {
     $languages{$_} = $_;
    }
   }
  }
  else {
   $logger->info("Unrecognised output from cuneiform: $output");
  }
 }
 return \%languages;
}

sub hocr {
 my ( $class, $file, $language, $pidfile ) = @_;
 my ($bmp);

 # Temporary filename for output
 my $txt = File::Temp->new( SUFFIX => '.txt' );

 if ( $file !~ /\.bmp$/ ) {

  # Temporary filename for new file
  $bmp = File::Temp->new( SUFFIX => '.bmp' );
  my $image = Image::Magick->new;
  $image->Read($file);

# Force TrueColor, as this produces DirectClass, which is what cuneiform expects.
# Without this, PseudoClass is often produced, for which cuneiform gives
# "PUMA_XFinalrecognition failed" warnings
  $image->Write( filename => $bmp, type => 'TrueColor' );
 }
 else {
  $bmp = $file;
 }
 my $cmd = "cuneiform -l $language -f hocr -o $txt $bmp";
 $logger->info($cmd);
 if ( defined $pidfile ) {
  system("echo $$ > $pidfile;$cmd");
 }
 else {
  system($cmd);
 }
 return Gscan2pdf::Document::slurp($txt);
}

1;

__END__
