use warnings;
use strict;
use Test::More tests => 12;
use Gscan2pdf::Document;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk3 -init;             # Could just call init separately

BEGIN {
    use_ok('Gscan2pdf::Dialog::Scan');
}

#########################

my $window = Gtk3::Window->new;

Gscan2pdf::Translation::set_domain('gscan2pdf');
use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;

ok(
    my $dialog = Gscan2pdf::Dialog::Scan->new(
        title           => 'title',
        'transient-for' => $window,
        'logger'        => $logger
    ),
    'Created dialog'
);
isa_ok( $dialog, 'Gscan2pdf::Dialog::Scan' );

$dialog->set( 'sided',        'double' );
$dialog->set( 'side-to-scan', 'reverse' );

# After having scanned some double-sided pages on a simplex scanner,
# selecting single-sided again should also select facing page.

$dialog->set( 'sided', 'single' );
is $dialog->get('side-to-scan'), 'facing',
  'selecting single sided also selects facing';

$dialog->{checkx}->set_active(TRUE);
$dialog->set( 'page-number-increment', 3 );
$dialog->{checkx}->set_active(FALSE);
is $dialog->get('page-number-increment'), 2,
  'turning off extended page numbering resets increment';

is $dialog->get('allow-batch-flatbed'), 0, 'default allow-batch-flatbed';
$dialog->set( 'allow-batch-flatbed', TRUE );
$dialog->set( 'num-pages',           2 );
is $dialog->get('num-pages'), 2, 'num-pages';
ok $dialog->{framen}->is_sensitive, 'num-page gui not ghosted';
$dialog->set( 'allow-batch-flatbed', FALSE );
is $dialog->get('num-pages'), 2,
  'with no source, num-pages not affected by allow-batch-flatbed';
ok $dialog->{framen}->is_sensitive, 'with no source, num-page gui not ghosted';

my $slist = Gscan2pdf::Document->new;
$dialog = Gscan2pdf::Dialog::Scan->new(
    title           => 'title',
    'transient-for' => $window,
    'document'      => $slist,
    'logger'        => $logger,
);
@{ $slist->{data} } = (
    [ 1, undef, undef ],
    [ 2, undef, undef ],
    [ 4, undef, undef ],
    [ 5, undef, undef ]
);
is $dialog->get('page-number-start'), 3,
  'adding pages should update page-number-start';
is $dialog->get('num-pages'), 1, 'adding pages should update num-pages';

__END__
