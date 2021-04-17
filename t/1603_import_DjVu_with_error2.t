use warnings;
use strict;
use File::Basename;    # Split filename into dir, file, ext
use IPC::Cmd qw(can_run);
use IPC::System::Simple qw(system capture);
use Test::More tests => 2;
use Carp;
use Sub::Override;     # Override Page to test functionality that
                       # we can't otherwise reproduce

BEGIN {
    use Gscan2pdf::Document;
    use Gtk3 -init;    # Could just call init separately
}

#########################

SKIP: {
    skip 'DjVuLibre not installed', 2 unless can_run('cjb2');
    Gscan2pdf::Translation::set_domain('gscan2pdf');
    use Log::Log4perl qw(:easy);
    Log::Log4perl->easy_init($FATAL);
    my $logger = Log::Log4perl::get_logger;

    # The overrides must occur before the thread is spawned in setup.
    my $override = Sub::Override->new;
    $override->replace(
        'Gscan2pdf::Page::import_djvu_txt' => sub {
            my ( $self, $text ) = @_;
            croak 'Error parsing djvu text';
            return;
        }
    );

    Gscan2pdf::Document->setup($logger);

    # Create test image
    system(qw(convert rose: test.jpg));
    system(qw(c44 test.jpg test.djvu));

    my $old =
      capture( qw(identify -format), '%m %G %g %z-bit %r', 'test.djvu' );

    my $slist = Gscan2pdf::Document->new;

    # dir for temporary files
    my $dir = File::Temp->newdir;
    $slist->set_dir($dir);

    my $expected = <<'EOS';
EOS

    $slist->import_files(
        paths          => ['test.djvu'],
        error_callback => sub {
            my ( $uuid, $process, $message ) = @_;
            ok( ( defined $message and $message ne '' ),
                'error callback has message' );
        },
        finished_callback => sub {
            like(
                capture(
                    qw(identify -format),
                    '%m %G %g %z-bit %r',
                    $slist->{data}[0][2]{filename}
                ),
                qr/^TIFF/,
                'DjVu otherwise imported correctly'
            );
            Gtk3->main_quit;
        }
    );
    Gtk3->main;

#########################

    unlink 'test.djvu', 'text.txt', 'test.jpg', <$dir/*>;
    rmdir $dir;
    Gscan2pdf::Document->quit();
}
