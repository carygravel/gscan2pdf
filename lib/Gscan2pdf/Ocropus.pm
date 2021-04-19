package Gscan2pdf::Ocropus;

use 5.008005;
use strict;
use warnings;
use Carp;
use File::Temp;    # To create temporary files
use File::Basename;
use HTML::Entities;
use Encode;
use English qw( -no_match_vars );    # for $PROCESS_ID

our $VERSION = '2.12.0';

my ( $exe, $installed, $setup, $logger );

sub setup {
    ( my $class, $logger ) = @_;
    return $installed if $setup;
    if ( Gscan2pdf::Document::check_command('ocroscript') ) {
        my $env = $ENV{OCROSCRIPTS};

        if ( not defined $env ) {
            for (qw(/usr /usr/local)) {
                if ( -d "$_/share/ocropus/scripts" ) {
                    $env = "$_/share/ocropus/scripts";
                }
            }
        }
        if ( defined $env ) {
            my $script;
            if ( -f "$env/recognize.lua" ) {
                $script = 'recognize';
            }
            elsif ( -f "$env/rec-tess.lua" ) {
                $script = 'rec-tess';
            }
            if ( defined $script ) {
                $exe       = "ocroscript $script";
                $installed = 1;
                $logger->info("Using ocroscript with $script.");
            }
            else {
                $logger->warn(
                    'Found ocroscript, but no recognition scripts. Disabling.');
            }
        }
        else {
            $logger->warn('Found ocroscript, but not its scripts. Disabling.');
        }
    }
    $setup = 1;
    return $installed;
}

sub hocr {
    my ( $class, %options ) = @_;
    my ( $png, $cmd );
    if ( not $setup ) { Gscan2pdf::Ocropus->setup( $options{logger} ) }

    if (   ( $options{file} !~ /[.](?:png|jpg|pnm)$/xsm )
        or ( defined $options{threshold} and $options{threshold} ) )
    {

        # Temporary filename for new file
        $png = File::Temp->new( SUFFIX => '.png' );
        my @cmd;
        if ( defined $options{threshold} and $options{threshold} ) {
            $logger->info("thresholding at $options{threshold} to $png");
            @cmd = (
                'convert', $options{file}, '+dither', '-threshold',
                "$options{threshold}%", '-depth', 1, $png,
            );
        }
        else {
            $logger->info("writing temporary image $png");
            @cmd = ( 'convert', $options{file}, $png );
        }
        my ( $status, $stdout, $stderr ) =
          Gscan2pdf::Document::exec_command( \@cmd );
        if ( $status != 0 ) { return }
    }
    else {
        $png = $options{file};
    }
    if ( $options{language} ) {
        $cmd = [ "tesslanguage=$options{language}", $exe, $png ];
    }
    else {
        $cmd = [ $exe, $png ];
    }

    # decode html->utf8
    my ( undef, $output ) =
      Gscan2pdf::Document::exec_command( $cmd, $options{pidfile} );
    my $decoded = decode_entities($output);

    # Unfortunately, there seems to be a case (tested in t/31_ocropus_utf8.t)
    # where decode_entities doesn't work cleanly, so encode/decode to finally
    # get good UTF-8
    return decode_utf8( encode_utf8($decoded) );
}

1;

__END__
