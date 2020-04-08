use warnings;
use strict;
use File::Basename;    # Split filename into dir, file, ext
use Test::More tests => 5;

BEGIN {
    use_ok('Gscan2pdf::Document');
    use Gtk3 -init;    # Could just call init separately
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system('convert rose: test.gif');

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test.gif'],
    finished_callback => sub {
        is_deeply [ $slist->{data}[0][2]{width}, $slist->{data}[0][2]{height} ],
          [ 70, 46 ], 'dimensions before crop';
        $slist->crop(
            page              => $slist->{data}[0][2]->{uuid},
            x                 => 10,
            y                 => 10,
            w                 => 10,
            h                 => 10,
            finished_callback => sub {
                is_deeply [ $slist->{data}[0][2]{width},
                    $slist->{data}[0][2]{height} ], [ 10, 10 ],
                  'dimensions after crop';
                my $got =
                  `identify -format '%g' $slist->{data}[0][2]{filename}`;
                chomp($got);
                is $got, "10x10+0+0", 'GIF cropped correctly';
                is dirname("$slist->{data}[0][2]{filename}"),
                  "$dir", 'using session directory';
                Gtk3->main_quit;
            }
        );
    }
);
Gtk3->main;

#########################

unlink 'test.gif', <$dir/*>;
rmdir $dir;
Gscan2pdf::Document->quit();
