use warnings;
use strict;
use IPC::System::Simple qw(system);
use Test::More tests => 13;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gscan2pdf::Document;
use Gscan2pdf::Dialog::Scan;

BEGIN {
    use Gtk3 -init;         # Could just call init separately
}

#########################

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system(qw(convert rose: test.tif));

my $slist  = Gscan2pdf::Document->new;
my $window = Gtk3::Window->new;
my $dialog = Gscan2pdf::Dialog::Scan->new(
    title           => 'title',
    'transient-for' => $window,
    'document'      => $slist,
    'logger'        => $logger,
  ),

  # dir for temporary files
  my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->import_files(
    paths             => ['test.tif'],
    finished_callback => sub {
        my $clipboard = $slist->copy_selection(TRUE);
        $slist->paste_selection( $clipboard, '0', 'after', TRUE )
          ;    # copy-paste page 1->2
        isnt(
            "$slist->{data}[0][2]{filename}",
            "$slist->{data}[1][2]{filename}",
            'different filename'
        );
        isnt( "$slist->{data}[0][2]{uuid}",
            "$slist->{data}[1][2]{uuid}", 'different uuid' );
        is $slist->{data}[1][0], 2, 'new page is number 2';
        my @rows = $slist->get_selected_indices;
        is_deeply( \@rows, [1], 'pasted page selected' );

        $dialog->set( 'page-number-start', 3 );
        $clipboard = $slist->cut_selection;
        is( $#{$clipboard},       0, 'cut 1 page to clipboard' );
        is( $#{ $slist->{data} }, 0, '1 page left in list' );
      TODO: {
            local $TODO =
                "Don't know how to trigger update of page-number-start "
              . "from Document";
            is $dialog->get('page-number-start'), 2,
              'page-number-start after cut';
        }

        $slist->paste_selection( $clipboard, '0', 'before' )
          ;    # paste page before 1
        is(
            "$slist->{data}[0][2]{uuid}",
            $clipboard->[0][2]{uuid},
            'cut page pasted at page 1'
        );
        is $slist->{data}[0][0], 1, 'cut page renumbered to page 1';
        @rows = $slist->get_selected_indices;
        is_deeply( \@rows, [1],
            'pasted page not selected, as parameter not TRUE' );
        is $dialog->get('page-number-start'), 3,
          'page-number-start after paste';
        $slist->select( 0, 1 );
        @rows = $slist->get_selected_indices;
        is_deeply( \@rows, [ 0, 1 ], 'selected all pages' );
        $slist->delete_selection;
        is( $#{ $slist->{data} }, -1, 'deleted all pages' );

        # TODO/FIXME: test drag-and-drop callbacks for move

        # TODO/FIXME: test drag-and-drop callbacks for copy

        Gtk3->main_quit;
    }
);
Gtk3->main;

#########################

unlink 'test.tif', <$dir/*>;
rmdir $dir;
Gscan2pdf::Document->quit();
