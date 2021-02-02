package Gscan2pdf::Document;

use strict;
use warnings;
use feature 'switch';
no if $] >= 5.018, warnings => 'experimental::smartmatch';

use threads;
use threads::shared;
use Thread::Queue;

use Gscan2pdf::Scanner::Options;
use Gscan2pdf::Page;
use Gscan2pdf::Tesseract;
use Gscan2pdf::Ocropus;
use Gscan2pdf::Cuneiform;
use Gscan2pdf::NetPBM;
use Gscan2pdf::Translation '__';    # easier to extract strings with xgettext
use Glib 1.210 qw(TRUE FALSE)
  ; # To get TRUE and FALSE. 1.210 necessary for Glib::SOURCE_REMOVE and Glib::SOURCE_CONTINUE
use Socket;
use FileHandle;
use Image::Magick;
use File::Temp;        # To create temporary files
use File::Basename;    # Split filename into dir, file, ext
use File::Copy;
use Storable qw(store retrieve);
use Archive::Tar;      # For session files
use Proc::Killfam;
use IPC::Open3 'open3';
use Symbol;            # for gensym
use Try::Tiny;
use Set::IntSpan 1.10;    # For size method for page numbering issues
use PDF::Builder;
use English qw( -no_match_vars );    # for $PROCESS_ID, $INPUT_RECORD_SEPARATOR
                                     # $CHILD_ERROR
use POSIX qw(:sys_wait_h strftime);
use Data::UUID;
use Date::Calc qw(Add_Delta_DHMS Date_to_Time Today_and_Now Timezone);
use Time::Piece;
use Carp qw(longmess);

# to deal with utf8 in filenames
use Encode qw(_utf8_off _utf8_on decode encode);
use version;
use Readonly;
Readonly our $POINTS_PER_INCH             => 72;
Readonly my $STRING_FORMAT                => 8;
Readonly my $_POLL_INTERVAL               => 100;     # ms
Readonly my $THUMBNAIL                    => 100;     # pixels
Readonly my $_100PERCENT                  => 100;
Readonly my $YEAR                         => 5;
Readonly my $BOX_TOLERANCE                => 5;
Readonly my $BITS_PER_BYTE                => 8;
Readonly my $ALL_PENDING_ZOMBIE_PROCESSES => -1;
Readonly my $INFINITE                     => -1;
Readonly my $NOT_FOUND                    => -1;
Readonly my $PROCESS_FAILED               => -1;
Readonly my $SIGNAL_MASK                  => 127;
Readonly my $MONTHS_PER_YEAR              => 12;
Readonly my $DAYS_PER_MONTH               => 31;
Readonly my $HOURS_PER_DAY                => 24;
Readonly my $MINUTES_PER_HOUR             => 60;
Readonly my $SECONDS_PER_MINUTE           => 60;
Readonly my $ID_URI                       => 0;
Readonly my $ID_PAGE                      => 1;
Readonly my $STRFTIME_YEAR_OFFSET         => -1900;
Readonly my $STRFTIME_MONTH_OFFSET        => -1;
Readonly my $LAST_ELEMENT                 => -1;
Readonly my $_90_DEGREES                  => 90;
Readonly my $_270_DEGREES                 => 270;

BEGIN {
    use Exporter ();
    our ( $VERSION, @EXPORT_OK, %EXPORT_TAGS );

    $VERSION = '2.11.0';

    use base qw(Exporter Gtk3::SimpleList);
    %EXPORT_TAGS = ();    # eg: TAG => [ qw!name1 name2! ],

    # your exported package globals go here,
    # as well as any optionally exported functions
    @EXPORT_OK = qw();

    # define hidden string column for page data
    Gtk3::SimpleList->add_column_type(
        'hstring',
        type => 'Glib::Scalar',
        attr => 'hidden'
    );
}
our @EXPORT_OK;

my $jobs_completed = 0;
my $jobs_total     = 0;
my $uuid_object    = Data::UUID->new;
my $EMPTY          = q{};
my $SPACE          = q{ };
my $PERCENT        = q{%};
my $isodate_regex  = qr{(\d{4})-(\d\d)-(\d\d)}xsm;
my $time_regex     = qr{(\d\d):(\d\d):(\d\d)}xsm;
my $tz_regex       = qr{([+-]\d\d):(\d\d)}xsm;
my ( $_self, $logger, $paper_sizes, %callback );

my %format = (
    'pnm' => 'Portable anymap',
    'ppm' => 'Portable pixmap format (color)',
    'pgm' => 'Portable graymap format (gray scale)',
    'pbm' => 'Portable bitmap format (black and white)',
);

sub setup {
    ( my $class, $logger ) = @_;
    $_self = {};
    Gscan2pdf::Page->set_logger($logger);

    $_self->{requests} = Thread::Queue->new;
    $_self->{return}   = Thread::Queue->new;
    $_self->{pages}    = Thread::Queue->new;
    share $_self->{progress};
    share $_self->{message};
    share $_self->{process_name};
    share $_self->{cancel};
    $_self->{cancel} = FALSE;

    $_self->{thread} = threads->new( \&_thread_main, $_self );
    return;
}

sub new {
    my ( $class, %options ) = @_;
    my $self = Gtk3::SimpleList->new(
        q{#}             => 'int',
        __('Thumbnails') => 'pixbuf',
        'Page Data'      => 'hstring',
    );
    $self->get_selection->set_mode('multiple');
    $self->set_headers_visible(FALSE);
    $self->set_reorderable(TRUE);
    for ( keys %options ) {
        $self->{$_} = $options{$_};
    }

    # Default thumbnail sizes
    if ( not defined( $self->{heightt} ) ) { $self->{heightt} = $THUMBNAIL }
    if ( not defined( $self->{widtht} ) )  { $self->{widtht}  = $THUMBNAIL }

    bless $self, $class;
    Glib::Timeout->add( $_POLL_INTERVAL, \&check_return_queue, $self );

    my $dnd_source = Gtk3::TargetEntry->new(
        'Glib::Scalar',    # some string representing the drag type
        ${ Gtk3::TargetFlags->new(qw/same-widget/) },
        $ID_PAGE,          # some app-defined integer identifier
    );
    $self->drag_source_set( 'button1-mask', [$dnd_source], [ 'copy', 'move' ] );

    my $dnd_dest = Gtk3::TargetEntry->new(
        'text/uri-list',    # some string representing the drag type
        0,                  # flags
        $ID_URI,            # some app-defined integer identifier
    );
    $self->drag_dest_set(
        [ 'drop',      'motion', 'highlight' ],
        [ $dnd_source, $dnd_dest ],
        [ 'copy',      'move' ],
    );
    $self->signal_connect(
        'drag-data-get' => sub {
            my ( $tree, $context, $sel ) = @_;

            # set dummy data which we'll ignore and use selected rows
            $sel->set( $sel->get_target, $STRING_FORMAT, [] );
        }
    );

    $self->signal_connect( 'drag-data-delete' => \&delete_selection );

    $self->signal_connect(
        'drag-data-received' => \&drag_data_received_callback );

    # Callback for dropped signal.
    $self->signal_connect(
        drag_drop => sub {
            my ( $tree, $context, $x, $y, $when ) = @_;
            my $targets = $tree->drag_dest_get_target_list;
            if ( my $target =
                $tree->drag_dest_find_target( $context, $targets ) )
            {
                $tree->drag_get_data( $context, $target, $when );
                return TRUE;
            }
            return FALSE;
        }
    );

    # Set the page number to be editable
    $self->set_column_editable( 0, TRUE );

    # Set-up the callback when the page number has been edited.
    $self->{row_changed_signal} = $self->get_model->signal_connect(
        'row-changed' => sub {

            # Note uuids for selected pages
            my @selection = $self->get_selected_indices;
            my @uuids;
            for (@selection) {
                push @uuids, $self->{data}[$_][2]->{uuid};
            }

            $self->get_model->signal_handler_block(
                $self->{row_changed_signal} );

            # Sort pages
            $self->manual_sort_by_column(0);

            # And make sure there are no duplicates
            $self->renumber;
            $self->get_model->signal_handler_unblock(
                $self->{row_changed_signal} );

            # Select the renumbered pages via uuid
            @selection = ();
            for (@uuids) {
                push @selection, $self->find_page_by_uuid($_);
            }
            $self->select(@selection);
        }
    );

    return $self;
}

# Set the paper sizes in the manager and worker threads

sub set_paper_sizes {
    ( my $class, $paper_sizes ) = @_;
    _enqueue_request( 'paper_sizes', { paper_sizes => $paper_sizes } );
    return;
}

sub quit {
    _enqueue_request('quit');
    $_self->{thread}->join();
    $_self->{thread} = undef;
    return;
}

# Kill all running processes

sub cancel {
    my ( $self, $cancel_callback, $process_callback ) = @_;
    lock( $_self->{requests} );    # unlocks automatically when out of scope
    lock( $_self->{pages} );       # unlocks automatically when out of scope

    # Empty process queue first to stop any new process from starting
    $logger->info('Emptying process queue');
    while ( $_self->{requests}->pending ) {
        $_self->{requests}->dequeue;
    }
    $jobs_completed = 0;
    $jobs_total     = 0;

    # Empty pages queue
    while ( $_self->{pages}->pending ) {
        $_self->{pages}->dequeue;
    }

    # Then send the thread a cancel signal
    # to stop it going beyond the next break point
    $_self->{cancel} = TRUE;

    # Kill all running processes in the thread
    for my $pidfile ( keys %{ $self->{running_pids} } ) {
        my $pid = slurp($pidfile);
        if ( $pid ne $EMPTY ) {
            if ( $pid == 1 ) { next }
            if ( defined $process_callback ) {
                $process_callback->($pid);
            }
            $logger->info("Killing PID $pid");
            local $SIG{CHLD} = 'IGNORE';
            killfam 'KILL', ($pid);
            delete $self->{running_pids}{$pidfile};
        }
    }

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{cancelled} = $cancel_callback;

    # Add a cancel request to ensure the reply is not blocked
    $logger->info('Requesting cancel');
    my $sentinel = _enqueue_request( 'cancel', { uuid => $uuid } );

    # Send a dummy page to the pages queue in case the thread is waiting there
    $_self->{pages}->enqueue( { page => 'cancel' } );

    return $self->_monitor_process( sentinel => $sentinel, uuid => $uuid );
}

sub create_pidfile {
    my ( $self, %options ) = @_;
    my $pidfile;
    try {
        $pidfile = File::Temp->new( DIR => $self->{dir}, SUFFIX => '.pid' );
    }
    catch {
        $logger->error("Caught error writing to $self->{dir}: $_");
        if ( $options{error_callback} ) {
            $options{error_callback}->(
                $options{page},
                'create PID file',
                "Error: unable to write to $self->{dir}."
            );
        }
    };
    return $pidfile;
}

# To avoid race condtions importing multiple files,
# run get_file_info on all files first before checking for errors and importing

sub import_files {
    my ( $self, %options ) = @_;

    my @info;
    $options{passwords} = [];
    for my $i ( 0 .. $#{ $options{paths} } ) {
        $self->_get_file_info_finished_callback1( $i, \@info, %options );
    }
    return;
}

sub _get_file_info_finished_callback1 {
    my ( $self, $i, $infolist, %options ) = @_;
    my $path = $options{paths}->[$i];

    # File in which to store the process ID
    # so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid = $self->_note_callbacks(%options);
    $callback{$uuid}{finished} = sub {
        my ($info) = @_;
        if ( $info->{encrypted} and $options{password_callback} ) {
            $options{passwords}[$i] = $options{password_callback}->($path);
            if ( defined $options{passwords}[$i]
                and $options{passwords}[$i] ne $EMPTY )
            {
                $self->_get_file_info_finished_callback1( $i, $infolist,
                    %options );
            }
            return;
        }
        $infolist->[$i] = $info;
        if ( $i == $#{ $options{paths} } ) {
            $self->_get_file_info_finished_callback2(
                $infolist,
                uuid => $uuid,
                %options
            );
        }
    };
    my $sentinel = _enqueue_request(
        'get-file-info',
        {
            path     => $path,
            pidfile  => "$pidfile",
            uuid     => $uuid,
            password => $options{passwords}[$i]
        }
    );

    $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        info     => TRUE,
        uuid     => $uuid,
    );
    return;
}

sub _get_file_info_finished_callback2 {
    my ( $self, $info, %options ) = @_;
    if ( @{$info} > 1 ) {
        for ( @{$info} ) {
            if ( not defined ) {
                next;
            }
            if ( $_->{format} eq 'session file' ) {
                $logger->error(
'Cannot open a session file at the same time as another file.'
                );
                if ( $options{error_callback} ) {
                    $options{error_callback}->(
                        undef,
                        'Open file',
                        __(
'Error: cannot open a session file at the same time as another file.'
                        )
                    );
                }
                return;
            }
            elsif ( $_->{pages} > 1 ) {
                $logger->error(
'Cannot import a multipage file at the same time as another file.'
                );
                if ( $options{error_callback} ) {
                    $options{error_callback}->(
                        undef,
                        'Open file',
                        __(
'Error: importing a multipage file at the same time as another file.'
                        )
                    );
                }
                return;
            }
        }
        my $main_uuid         = $options{uuid};
        my $finished_callback = $options{finished_callback};
        delete $options{paths};
        delete $options{finished_callback};
        for my $i ( 0 .. $#{$info} ) {
            if ( $options{metadata_callback} ) {
                $options{metadata_callback}
                  ->( _extract_metadata( $info->[$i] ) );
            }
            if ( $i == $#{$info} ) {
                $options{finished_callback} = $finished_callback;
            }
            $self->import_file(
                info  => $info->[$i],
                first => 1,
                last  => 1,
                %options
            );
        }
    }
    elsif ( $info->[0]{format} eq 'session file' ) {
        $self->open_session_file( info => $info->[0]{path}, %options );
    }
    else {
        if ( $options{metadata_callback} ) {
            $options{metadata_callback}->( _extract_metadata( $info->[0] ) );
        }
        my $first_page = 1;
        my $last_page  = $info->[0]{pages};
        if ( $options{pagerange_callback} and $last_page > 1 ) {
            ( $first_page, $last_page ) =
              $options{pagerange_callback}->( $info->[0] );
            if ( not defined $first_page or not defined $last_page ) { return }
        }
        my $password = $options{passwords}[0];
        delete $options{paths};
        delete $options{passwords};
        delete $options{password_callback};
        $self->import_file(
            info     => $info->[0],
            password => $password,
            first    => $first_page,
            last     => $last_page,
            %options
        );
    }
    return;
}

sub _extract_metadata {
    my ($info) = @_;
    my %metadata;
    for my $key ( keys %{$info} ) {
        if (    $key =~ /(author|title|subject|keywords|tz)/xsm
            and $info->{$key} ne 'NONE' )
        {
            $metadata{$key} = $info->{$key};
        }
    }
    if ( $info->{datetime} ) {
        if ( $info->{format} eq 'Portable Document Format' ) {
            if ( $info->{datetime} =~ /^(.{19})((?:[+-]\d+)|Z)?$/xsm ) {
                try {
                    my $t  = Time::Piece->strptime( $1, '%Y-%m-%dT%H:%M:%S' );
                    my $tz = $2;
                    $metadata{datetime} = [
                        $t->year, $t->mon, $t->day_of_month,
                        $t->hour, $t->min, $t->sec
                    ];
                    if ( not defined $tz or $tz eq 'Z' ) {
                        $tz = 0;
                    }
                    $metadata{tz} =
                      [ undef, undef, undef, int $tz, 0, undef, undef ];
                }
            }
        }
        elsif ( $info->{format} eq 'DJVU' ) {
            if ( $info->{datetime} =~
                /^$isodate_regex\s$time_regex$tz_regex/xsm )
            {
                $metadata{datetime} =
                  [ int $1, int $2, int $3, int $4, int $5, int $6 ];
                $metadata{tz} =
                  [ undef, undef, undef, int($7), int($8), undef, undef ];
            }
        }
    }
    return \%metadata;
}

# Because the finished, error and cancelled callbacks are triggered by the
# return queue, note them here for the return queue to use.

sub _note_callbacks {
    my ( $self, %options ) = @_;
    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{queued}    = $options{queued_callback};
    $callback{$uuid}{started}   = $options{started_callback};
    $callback{$uuid}{running}   = $options{running_callback};
    $callback{$uuid}{finished}  = $options{finished_callback};
    $callback{$uuid}{error}     = $options{error_callback};
    $callback{$uuid}{cancelled} = $options{cancelled_callback};
    $callback{$uuid}{display}   = $options{display_callback};

    if ( $options{mark_saved} ) {
        $callback{$uuid}{mark_saved} = sub {

            # list_of_pages is frozen,
            # so find the original pages from their uuids
            for ( @{ $options{list_of_pages} } ) {
                my $page = $self->find_page_by_uuid($_);
                $self->{data}[$page][2]->{saved} = TRUE;
            }
        };
    }
    return $uuid;
}

sub import_file {
    my ( $self, %options ) = @_;

    # File in which to store the process ID
    # so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }
    my $dirname = $EMPTY;
    if ( defined $self->{dir} ) { $dirname = "$self->{dir}" }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'import-file',
        {
            info     => $options{info},
            password => $options{password},
            first    => $options{first},
            last     => $options{last},
            dir      => $dirname,
            pidfile  => "$pidfile",
            uuid     => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub _post_process_scan {
    my ( $self, $page, %options ) = @_;

    # tesseract can't extract resolution from pnm, so convert to png
    if (    defined $page
        and $page->{format} =~ /Portable[ ](any|pix|gray|bit)map/xsm
        and $options{to_png} )
    {
        $self->to_png(
            page              => $page->{uuid},
            queued_callback   => $options{queued_callback},
            started_callback  => $options{started_callback},
            finished_callback => sub {
                my $finished_page = $self->find_page_by_uuid( $page->{uuid} );
                if ( not defined $finished_page ) {
                    $self->_post_process_scan( undef, %options )
                      ;    # to fire finished_callback
                    return;
                }
                $self->_post_process_scan( $self->{data}[$finished_page][2],
                    %options );
            },
            error_callback   => $options{error_callback},
            display_callback => $options{display_callback},
        );
        return;
    }
    if ( $options{rotate} ) {
        $self->rotate(
            angle             => $options{rotate},
            page              => $page->{uuid},
            queued_callback   => $options{queued_callback},
            started_callback  => $options{started_callback},
            finished_callback => sub {
                delete $options{rotate};
                my $finished_page = $self->find_page_by_uuid( $page->{uuid} );
                if ( not defined $finished_page ) {
                    $self->_post_process_scan( undef, %options )
                      ;    # to fire finished_callback
                    return;
                }
                $self->_post_process_scan( $self->{data}[$finished_page][2],
                    %options );
            },
            error_callback   => $options{error_callback},
            display_callback => $options{display_callback},
        );
        return;
    }
    if ( $options{unpaper} ) {
        $self->unpaper(
            page    => $page->{uuid},
            options => {
                command   => $options{unpaper}->get_cmdline,
                direction => $options{unpaper}->get_option('direction'),
            },
            queued_callback   => $options{queued_callback},
            started_callback  => $options{started_callback},
            finished_callback => sub {
                delete $options{unpaper};
                my $finished_page = $self->find_page_by_uuid( $page->{uuid} );
                if ( not defined $finished_page ) {
                    $self->_post_process_scan( undef, %options )
                      ;    # to fire finished_callback
                    return;
                }
                $self->_post_process_scan( $self->{data}[$finished_page][2],
                    %options );
            },
            error_callback   => $options{error_callback},
            display_callback => $options{display_callback},
        );
        return;
    }
    if ( $options{udt} ) {
        $self->user_defined(
            page              => $page->{uuid},
            command           => $options{udt},
            queued_callback   => $options{queued_callback},
            started_callback  => $options{started_callback},
            finished_callback => sub {
                delete $options{udt};
                my $finished_page = $self->find_page_by_uuid( $page->{uuid} );
                if ( not defined $finished_page ) {
                    $self->_post_process_scan( undef, %options )
                      ;    # to fire finished_callback
                    return;
                }
                $self->_post_process_scan( $self->{data}[$finished_page][2],
                    %options );
            },
            error_callback   => $options{error_callback},
            display_callback => $options{display_callback},
        );
        return;
    }
    if ( $options{ocr} ) {
        $self->ocr_pages(
            [ $page->{uuid} ],
            threshold         => $options{threshold},
            engine            => $options{engine},
            language          => $options{language},
            queued_callback   => $options{queued_callback},
            started_callback  => $options{started_callback},
            finished_callback => sub {
                delete $options{ocr};
                $self->_post_process_scan( undef, %options )
                  ;    # to fire finished_callback
            },
            error_callback   => $options{error_callback},
            display_callback => $options{display_callback},
        );
        return;
    }
    if ( $options{finished_callback} ) { $options{finished_callback}->() }
    return;
}

# Take new scan, pad it if necessary, display it,
# and set off any post-processing chains

sub import_scan {
    my ( $self, %options ) = @_;

    # Interface to frontend
    open my $fh, '<', $options{filename}    ## no critic (RequireBriefOpen)
      or die "can't open $options{filename}: $ERRNO\n";

    # Read without blocking
    my $size = 0;
    Glib::IO->add_watch(
        fileno($fh),
        [ 'in', 'hup' ],
        sub {
            my ( $fileno, $condition ) = @_;
            if ( $condition & 'in' ) { # bit field operation. >= would also work
                my ( $width, $height );
                if ( $size == 0 ) {
                    ( $size, $width, $height ) =
                      Gscan2pdf::NetPBM::file_size_from_header(
                        $options{filename} );
                    $logger->info("Header suggests $size");
                    return Glib::SOURCE_CONTINUE if ( $size == 0 );
                    close $fh
                      or
                      $logger->warn("Error closing $options{filename}: $ERRNO");
                }
                my $filesize = -s $options{filename};
                $logger->info("Expecting $size, found $filesize");
                if ( $size > $filesize ) {
                    my $pad = $size - $filesize;
                    open my $fh, '>>', $options{filename}
                      or die "cannot open >> $options{filename}: $ERRNO\n";
                    my $data = $EMPTY;
                    for ( 1 .. $pad * $BITS_PER_BYTE ) {
                        $data .= '1';
                    }
                    printf {$fh} pack sprintf( 'b%d', length $data ), $data;
                    close $fh
                      or
                      $logger->warn("Error closing $options{filename}: $ERRNO");
                    $logger->info("Padded $pad bytes");
                }
                my $page = Gscan2pdf::Page->new(
                    filename    => $options{filename},
                    xresolution => $options{xresolution},
                    yresolution => $options{yresolution},
                    width       => $width,
                    height      => $height,
                    format      => 'Portable anymap',
                    delete      => $options{delete},
                    dir         => $options{dir},
                );
                my $index = $self->add_page( 'none', $page, $options{page} );
                if ( $index == $NOT_FOUND and $options{error_callback} ) {
                    $options{error_callback}
                      ->( undef, 'Import scan', __('Unable to load image') );
                }
                else {
                    if ( $options{display_callback} ) {
                        $options{display_callback}->();
                    }
                    $self->_post_process_scan( $page, %options );
                }
                return Glib::SOURCE_REMOVE;
            }
            return Glib::SOURCE_CONTINUE;
        }
    );

    return;
}

sub _throw_error {
    my ( $uuid, $page_uuid, $process, $message ) = @_;
    if ( defined $uuid and defined $callback{$uuid}{started} ) {
        $callback{$uuid}{started}
          ->( undef, $process, $jobs_completed, $jobs_total, $message, undef );
        delete $callback{$uuid}{started};
    }
    if ( defined $callback{$uuid}{error} ) {
        $message =~ s/\s+$//xsm;    # strip trailing whitespace
        $callback{$uuid}{error}->( $page_uuid, $process, $message );
        delete $callback{$uuid}{error};
    }
    return;
}

sub check_return_queue {
    my ($self) = @_;
    lock( $_self->{return} );       # unlocks automatically when out of scope
    while ( defined( my $data = $_self->{return}->dequeue_nb() ) ) {
        if ( not defined $data->{type} ) {
            $logger->error("Bad data bundle $data in return queue.");
            next;
        }

        # if we have pressed the cancel button, ignore everything in the returns
        # queue until it flags cancelled.
        if ( $_self->{cancel} ) {
            if ( $data->{type} eq 'cancelled' ) {
                $_self->{cancel} = FALSE;
                if ( defined $callback{ $data->{uuid} }{cancelled} ) {
                    $callback{ $data->{uuid} }{cancelled}->( $data->{info} );
                    delete $callback{ $data->{uuid} };
                }
            }
            else {
                next;
            }
        }

        if ( not defined $data->{uuid} ) {
            $logger->error('Bad uuid in return queue.');
            next;
        }
        given ( $data->{type} ) {
            when ('file-info') {
                if ( not defined $data->{info} ) {
                    $logger->error('Bad file info in return queue.');
                    next;
                }
                if ( defined $callback{ $data->{uuid} }{finished} ) {
                    $callback{ $data->{uuid} }{finished}->( $data->{info} );
                    delete $callback{ $data->{uuid} };
                }
            }
            when ('page request') {
                my $i = $self->find_page_by_uuid( $data->{uuid} );
                if ( defined $i ) {
                    $_self->{pages}->enqueue(
                        {
                            # sharing File::Temp objects causes problems,
                            # so freeze
                            page => $self->{data}[$i][2]->freeze,
                        }
                    );
                }
                else {
                    $logger->error("No page with UUID $data->{uuid}");
                    $_self->{pages}->enqueue( { page => 'cancel' } );
                }
                return Glib::SOURCE_CONTINUE;
            }
            when ('page') {
                if ( defined $data->{page} ) {
                    delete $data->{page}{saved};    # Remove saved tag
                    $self->add_page( $data->{uuid}, $data->{page},
                        $data->{info} );
                }
                else {
                    $logger->error('Bad page in return queue.');
                }
            }
            when ('error') {
                _throw_error(
                    $data->{uuid},    $data->{page},
                    $data->{process}, $data->{message}
                );
            }
            when ('finished') {
                if ( defined $callback{ $data->{uuid} }{started} ) {
                    $callback{ $data->{uuid} }{started}->(
                        undef, $_self->{process_name},
                        $jobs_completed, $jobs_total, $data->{message},
                        $_self->{progress}
                    );
                    delete $callback{ $data->{uuid} }{started};
                }
                if ( defined $callback{ $data->{uuid} }{mark_saved} ) {
                    $callback{ $data->{uuid} }{mark_saved}->();
                    delete $callback{ $data->{uuid} }{mark_saved};
                }
                if ( defined $callback{ $data->{uuid} }{finished} ) {
                    $callback{ $data->{uuid} }{finished}->( $data->{message} );
                    delete $callback{ $data->{uuid} };
                }
                if ( $_self->{requests}->pending == 0 ) {
                    $jobs_completed = 0;
                    $jobs_total     = 0;
                }
                else {
                    $jobs_completed++;
                }
            }
        }
    }
    return Glib::SOURCE_CONTINUE;
}

# does the given page exist?

sub index_for_page {
    my ( $self, $n, $min, $max, $direction ) = @_;
    if ( $#{ $self->{data} } < 0 ) { return $INFINITE }
    if ( not defined $min ) {
        $min = 0;
    }
    if ( not defined $max ) {
        $max = $n - 1;
    }
    my $s    = $min;
    my $e    = $max + 1;
    my $step = 1;
    if ( defined $direction and $direction < 0 ) {
        $step = -$step;
        $s    = $max;
        if ( $s > $#{ $self->{data} } ) { $s = $#{ $self->{data} } }
        $e = $min - 1;
    }

    my $i = $s;
    while ( $step > 0 ? ( $i <= $e and $i < @{ $self->{data} } ) : $i >= $e ) {
        if ( $self->{data}[$i][0] == $n ) {
            return $i;
        }
        $i += $step;
    }
    return $INFINITE;
}

# Check how many pages could be scanned

sub pages_possible {
    my ( $self, $start, $step ) = @_;
    my $i = $#{ $self->{data} };

    # Empty document and negative step
    if ( $i < 0 and $step < 0 ) {
        my $n = -$start / $step;
        return $n == int($n) ? $n : int($n) + 1;
    }

    # Empty document, or start page after end of document, allow infinite pages
    elsif ( ( $i < 0 or $self->{data}[$i][0] < $start ) and $step > 0 ) {
        return $INFINITE;
    }

    # scan in appropriate direction, looking for position for last page
    my $n               = 0;
    my $max_page_number = $self->{data}[$i][0];
    while (TRUE) {

        # fallen off top of index
        if ( $step > 0 and $start + $n * $step > $max_page_number ) {
            return $INFINITE;
        }

        # fallen off bottom of index
        if ( $step < 0 and $start + $n * $step < 1 ) {
            return $n;
        }

        # Found page
        $i = $self->index_for_page( $start + $n * $step, 0, $start - 1, $step );
        if ( $i > $INFINITE ) {
            return $n;
        }

        $n++;
    }
    return;
}

sub find_page_by_uuid {
    my ( $self, $uuid ) = @_;
    if ( not defined $uuid ) {
        $logger->error( longmess('find_page_by_uuid() called with undef') );
        return;
    }
    my $i = 0;
    while (
        $i <= $#{ $self->{data} }
        and ( not defined $self->{data}[$i][2]{uuid}
            or $self->{data}[$i][2]{uuid} ne $uuid )
      )
    {
        $i++;
    }
    if ( $i <= $#{ $self->{data} } ) { return $i }
    return;
}

# Add a new page to the document

sub add_page {
    my ( $self, $process_uuid, $page, $ref ) = @_;
    my ( $i, $pagenum, $new, @page );

    # This is really hacky to allow import_scan() to specify the page number
    if ( ref($ref) ne 'HASH' ) {
        $pagenum = $ref;
        undef $ref;
    }
    for my $uuid ( ( $ref->{replace}, $ref->{'insert-after'} ) ) {
        if ( defined $uuid ) {
            $i = $self->find_page_by_uuid($uuid);
            if ( not defined $i ) {
                $logger->error("Requested page $uuid does not exist.");
                return $NOT_FOUND;
            }
            last;
        }
    }

    # Move the temp file from the thread to a temp object that will be
    # automatically cleared up
    if ( ref( $page->{filename} ) eq 'File::Temp' ) {
        $new = $page;
    }
    else {
        try {
            $new = $page->thaw;
        }
        catch {
            _throw_error( $process_uuid, $page->{uuid}, $EMPTY,
                "Caught error writing to $self->{dir}: $_" );
        };
        if ( not defined $new ) { return }
    }

    # Block the row-changed signal whilst adding the scan (row) and sorting it.
    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_block( $self->{row_changed_signal} );
    }
    my ( $xresolution, $yresolution ) = $new->get_resolution($paper_sizes);
    my $thumb = $new->get_pixbuf_at_scale( $self->{heightt}, $self->{widtht} );

    if ( defined $i ) {
        if ( defined $ref->{replace} ) {
            $pagenum = $self->{data}[$i][0];
            $logger->info(
"Replaced $self->{data}[$i][2]->{filename} ($self->{data}[$i][2]->{uuid}) at page $pagenum with $new->{filename} ($new->{uuid}), resolution $xresolution,$yresolution"
            );
            $self->{data}[$i][1] = $thumb;
            $self->{data}[$i][2] = $new;
        }
        elsif ( defined $ref->{'insert-after'} ) {
            $pagenum = $self->{data}[$i][0] + 1;
            splice @{ $self->{data} }, $i + 1, 0, [ $pagenum, $thumb, $new ];
            $logger->info(
"Inserted $new->{filename} ($new->{uuid}) at page $pagenum with resolution $xresolution,$yresolution"
            );
        }
    }
    else {
        # Add to the page list
        if ( not defined $pagenum ) { $pagenum = $#{ $self->{data} } + 2 }
        push @{ $self->{data} }, [ $pagenum, $thumb, $new ];
        $logger->info(
"Added $page->{filename} ($new->{uuid}) at page $pagenum with resolution $xresolution,$yresolution"
        );
    }

    # Block selection_changed_signal
    # to prevent its firing changing pagerange to all
    if ( defined $self->{selection_changed_signal} ) {
        $self->get_selection->signal_handler_block(
            $self->{selection_changed_signal} );
    }
    $self->get_selection->unselect_all;
    $self->manual_sort_by_column(0);
    if ( defined $self->{selection_changed_signal} ) {
        $self->get_selection->signal_handler_unblock(
            $self->{selection_changed_signal} );
    }
    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_unblock( $self->{row_changed_signal} );
    }

    # Due to the sort, must search for new page
    $page[0] = 0;

    # $page[0] < $#{$self -> {data}} needed to prevent infinite loop in case of
    # error importing.
    while ( $page[0] < $#{ $self->{data} }
        and $self->{data}[ $page[0] ][0] != $pagenum )
    {
        ++$page[0];
    }

    $self->select(@page);

    if ( defined $callback{$process_uuid}{display} ) {
        $callback{$process_uuid}{display}->( $self->{data}[$i][2] );
    }
    return $page[0];
}

sub remove_corrupted_pages {
    my ($self) = @_;
    my $i = 0;
    while ( $i < @{ $self->{data} } ) {
        if ( not defined $self->{data}[$i][2] ) {
            splice @{ $self->{data} }, $i, 1;
        }
        else {
            $i++;
        }
    }
    return;
}

# Helpers:
sub compare_numeric_col { ## no critic (RequireArgUnpacking, RequireFinalReturn)
    $_[0] <=> $_[1];
}

sub compare_text_col {    ## no critic (RequireArgUnpacking, RequireFinalReturn)
    $_[0] cmp $_[1];
}

# Manual one-time sorting of the simplelist's data

sub manual_sort_by_column {
    my ( $self, $sortcol ) = @_;

    $self->remove_corrupted_pages;

    # The sort function depends on the column type
    my %sortfuncs = (
        'Glib::Scalar' => \&compare_text_col,
        'Glib::String' => \&compare_text_col,
        'Glib::Int'    => \&compare_numeric_col,
        'Glib::Double' => \&compare_numeric_col,
    );

    # Remember, this relies on the fact that simplelist keeps model
    # and view column indices aligned.
    my $sortfunc = $sortfuncs{ $self->get_model->get_column_type($sortcol) };

    # Deep copy the tied data so we can sort it.
    # Otherwise, very bad things happen.
    my @data = map { [ @{$_} ] } @{ $self->{data} };
    @data = sort { $sortfunc->( $a->[$sortcol], $b->[$sortcol] ) } @data;

    @{ $self->{data} } = @data;
    return;
}

sub drag_data_received_callback {    ## no critic (ProhibitManyArgs)
    my ( $tree, $context, $x, $y, $data, $info, $time ) = @_;
    my $delete =
      $context->get_actions ==       ## no critic (ProhibitMismatchedOperators)
      'move';

    # This callback is fired twice, seemingly once for the drop flag,
    # and once for the copy flag. If the drop flag is disabled, the URI
    # drop does not work. If the copy flag is disabled, the drag-with-copy
    # does not work. Therefore if copying, create a hash of the drop times
    # and ignore the second drop.
    if ( not $delete ) {
        if ( defined $tree->{drops}{$time} ) {
            delete $tree->{drops};
            Gtk3::drag_finish( $context, TRUE, $delete, $time );
            return;
        }
        else {
            $tree->{drops}{$time} = 1;
        }
    }

    if ( $info == $ID_URI ) {
        my $uris = $data->get_uris;
        for ( @{$uris} ) {
            s{^file://}{}gxsm;
        }
        $tree->import_files( paths => $uris );
        Gtk3::drag_finish( $context, TRUE, FALSE, $time );
    }
    elsif ( $info == $ID_PAGE ) {
        my ( $path, $how ) = $tree->get_dest_row_at_pos( $x, $y );
        if ( defined $path ) { $path = $path->to_string }

        my @rows      = $tree->get_selected_indices or return;
        my $selection = $tree->copy_selection( not $delete );

        # pasting without updating the selection
        # in order not to defeat the finish() call below.
        $tree->paste_selection( $selection, $path, $how );

        Gtk3::drag_finish( $context, TRUE, $delete, $time );
    }
    else {
        $context->abort;
    }
    return;
}

# Cut the selection

sub cut_selection {
    my ($self) = @_;
    my $data = $self->copy_selection(FALSE);
    $self->delete_selection_extra;
    return $data;
}

# Copy the selection

sub copy_selection {
    my ( $self, $clone ) = @_;
    my @selection = $self->get_selected_indices or return;
    my @data;
    for my $index (@selection) {
        my $page = $self->{data}[$index];
        push @data, [ $page->[0], $page->[1], $page->[2]->clone($clone) ];
    }
    $logger->info( 'Copied ', $clone ? 'and cloned ' : $EMPTY,
        $#data + 1, ' pages' );
    return \@data;
}

# Paste the selection

sub paste_selection {
    my ( $self, $data, $path, $how, $select_new_pages ) = @_;

    # Block row-changed signal so that the list can be updated before the sort
    # takes over.
    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_block( $self->{row_changed_signal} );
    }

    my $dest;
    if ( defined $path ) {
        if ( $how eq 'after' or $how eq 'into-or-after' ) {
            $path++;
        }
        splice @{ $self->{data} }, $path, 0, @{$data};
        $dest = $path;
    }
    else {
        $dest = $#{ $self->{data} } + 1;
        push @{ $self->{data} }, @{$data};
    }

    # Update the start spinbutton if necessary
    $self->renumber;
    $self->get_model->signal_emit( 'row-changed', Gtk3::TreePath->new,
        $self->get_model->get_iter_first );

    # Select the new pages
    if ($select_new_pages) {
        my @selection;
        for ( $dest .. $dest + $#{$data} ) {
            push @selection, $_;
        }
        $self->get_selection->unselect_all;
        $self->select(@selection);
    }

    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_unblock( $self->{row_changed_signal} );
    }

    $self->save_session;

    $logger->info( 'Pasted ', $#{$data} + 1, " pages at position $dest" );
    return;
}

# Delete the selected scans

sub delete_selection {
    my ( $self, $context ) = @_;

    # The drag-data-delete callback seems to be fired twice. Therefore, create
    # a hash of the context hashes and ignore the second drop. There must be a
    # less hacky way of solving this. FIXME
    if ( defined $context ) {
        if ( defined $self->{context}{$context} ) {
            delete $self->{context};
            return;
        }
        else {
            $self->{context}{$context} = 1;
        }
    }

    my ( $paths, $model ) = $self->get_selection->get_selected_rows;

    # Reverse the rows in order not to invalid the iters
    if ($paths) {
        for my $path ( reverse @{$paths} ) {
            my $iter = $model->get_iter($path);
            $model->remove($iter);
        }
    }
    return;
}

sub delete_selection_extra {
    my ($self) = @_;

    my @page   = $self->get_selected_indices;
    my $npages = $#page + 1;
    my @uuids  = map { $self->{data}[$_][2]{uuid} } @page;
    $logger->info( 'Deleting ', join q{ }, @uuids );
    if ( defined $self->{selection_changed_signal} ) {
        $self->get_selection->signal_handler_block(
            $self->{selection_changed_signal} );
    }
    $self->delete_selection;
    if ( defined $self->{selection_changed_signal} ) {
        $self->get_selection->signal_handler_unblock(
            $self->{selection_changed_signal} );
    }

    # Select nearest page to last current page
    if ( @{ $self->{data} } and @page ) {
        my $old_selection = $page[0];

        # Select just the first one
        @page = ( $page[0] );
        if ( $page[0] > $#{ $self->{data} } ) {
            $page[0] = $#{ $self->{data} };
        }
        $self->select(@page);

        # If the index hasn't changed, the signal won't have emitted, so do it
        # manually. Even if the index has changed, if it has the focus, the
        # signal is still not fired (is this a bug in gtk+-3?), so do it here.
        if ( $old_selection == $page[0] or $self->has_focus ) {
            $self->get_selection->signal_emit('changed');
        }
    }

    elsif ( @{ $self->{data} } ) {
        $self->get_selection->unselect_all;
    }

    # No pages left, and having blocked the selection_changed_signal,
    # we've got to clear the image
    else {
        $self->get_selection->signal_emit('changed');
    }

    $self->save_session;
    $logger->info("Deleted $npages pages");
    return;
}

sub save_pdf {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    $options{mark_saved} = TRUE;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'save-pdf',
        {
            path          => $options{path},
            list_of_pages => $options{list_of_pages},
            metadata      => $options{metadata},
            options       => $options{options},
            dir           => "$self->{dir}",
            pidfile       => "$pidfile",
            uuid          => $uuid,
        }
    );

    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub save_djvu {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    $options{mark_saved} = TRUE;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'save-djvu',
        {
            path          => $options{path},
            list_of_pages => $options{list_of_pages},
            metadata      => $options{metadata},
            options       => $options{options},
            dir           => "$self->{dir}",
            pidfile       => "$pidfile",
            uuid          => $uuid,
        }
    );

    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub save_tiff {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    $options{mark_saved} = TRUE;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'save-tiff',
        {
            path          => $options{path},
            list_of_pages => $options{list_of_pages},
            options       => $options{options},
            dir           => "$self->{dir}",
            pidfile       => "$pidfile",
            uuid          => $uuid,
        }
    );

    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub rotate {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'rotate',
        {
            angle => $options{angle},
            page  => $options{page},
            dir   => "$self->{dir}",
            uuid  => $uuid,
        }
    );

    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub save_image {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    $options{mark_saved} = TRUE;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'save-image',
        {
            path          => $options{path},
            list_of_pages => $options{list_of_pages},
            options       => $options{options},
            pidfile       => "$pidfile",
            uuid          => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

# Check that all pages have been saved

sub scans_saved {
    my ($self) = @_;
    for ( @{ $self->{data} } ) {
        if ( not $_->[2]{saved} ) { return FALSE }
    }
    return TRUE;
}

sub save_text {
    my ( $self, %options ) = @_;

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'save-text',
        {
            path          => $options{path},
            list_of_pages => $options{list_of_pages},
            options       => $options{options},
            uuid          => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub save_hocr {
    my ( $self, %options ) = @_;

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'save-hocr',
        {
            path          => $options{path},
            list_of_pages => $options{list_of_pages},
            options       => $options{options},
            uuid          => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub analyse {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'analyse',
        {
            list_of_pages => $options{list_of_pages},
            uuid          => $uuid
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub threshold {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'threshold',
        {
            threshold => $options{threshold},
            page      => $options{page},
            dir       => "$self->{dir}",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub brightness_contrast {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'brightness-contrast',
        {
            page       => $options{page},
            brightness => $options{brightness},
            contrast   => $options{contrast},
            dir        => "$self->{dir}",
            uuid       => $uuid
        }
    );

    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub negate {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'negate',
        {
            page => $options{page},
            dir  => "$self->{dir}",
            uuid => $uuid
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub unsharp {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'unsharp',
        {
            page      => $options{page},
            radius    => $options{radius},
            sigma     => $options{sigma},
            gain      => $options{gain},
            threshold => $options{threshold},
            dir       => "$self->{dir}",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub crop {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'crop',
        {
            page => $options{page},
            x    => $options{x},
            y    => $options{y},
            w    => $options{w},
            h    => $options{h},
            dir  => "$self->{dir}",
            uuid => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub split_page {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'split',
        {
            page      => $options{page},
            direction => $options{direction},
            position  => $options{position},
            dir       => "$self->{dir}",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub to_png {
    my ( $self, %options ) = @_;
    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'to-png',
        {
            page => $options{page},
            dir  => "$self->{dir}",
            uuid => $uuid
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        uuid     => $uuid,
    );
}

sub tesseract {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'tesseract',
        {
            page      => $options{page},
            language  => $options{language},
            threshold => $options{threshold},
            pidfile   => "$pidfile",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub ocropus {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'ocropus',
        {
            page      => $options{page},
            language  => $options{language},
            threshold => $options{threshold},
            pidfile   => "$pidfile",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub cuneiform {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'cuneiform',
        {
            page      => $options{page},
            language  => $options{language},
            threshold => $options{threshold},
            pidfile   => "$pidfile",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub gocr {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'gocr',
        {
            page      => $options{page},
            threshold => $options{threshold},
            pidfile   => "$pidfile",
            uuid      => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

# Wrapper for the various ocr engines

sub ocr_pages {
    my ( $self, $pages, %options ) = @_;
    for my $page ( @{$pages} ) {
        $options{page} = $page;
        if ( $options{engine} eq 'gocr' ) {
            $self->gocr(%options);
        }
        elsif ( $options{engine} eq 'tesseract' ) {
            $self->tesseract(%options);
        }
        elsif ( $options{engine} eq 'ocropus' ) {
            $self->ocropus(%options);
        }
        else {    # cuneiform
            $self->cuneiform(%options);
        }
    }
    return;
}

sub unpaper {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'unpaper',
        {
            page    => $options{page},
            options => $options{options},
            pidfile => "$pidfile",
            dir     => "$self->{dir}",
            uuid    => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

sub user_defined {
    my ( $self, %options ) = @_;

   # File in which to store the process ID so that it can be killed if necessary
    my $pidfile = $self->create_pidfile(%options);
    if ( not defined $pidfile ) { return }

    my $uuid     = $self->_note_callbacks(%options);
    my $sentinel = _enqueue_request(
        'user-defined',
        {
            page    => $options{page},
            command => $options{command},
            dir     => "$self->{dir}",
            pidfile => "$pidfile",
            uuid    => $uuid,
        }
    );
    return $self->_monitor_process(
        sentinel => $sentinel,
        pidfile  => $pidfile,
        uuid     => $uuid,
    );
}

# Dump $self to a file.
# If a filename is given, zip it up as a session file
# Pass version to allow us to mock different session version and to be able to
# test opening old sessions.

sub save_session {
    my ( $self, $filename, $version ) = @_;
    $self->remove_corrupted_pages;

    my ( %session, @filenamelist );
    for my $i ( 0 .. $#{ $self->{data} } ) {
        $session{ $self->{data}[$i][0] }{filename} =
          $self->{data}[$i][2]{filename}->filename;
        push @filenamelist, $self->{data}[$i][2]{filename}->filename;
        for my $key ( keys %{ $self->{data}[$i][2] } ) {
            if ( $key ne 'filename' ) {
                $session{ $self->{data}[$i][0] }{$key} =
                  $self->{data}[$i][2]{$key};
            }
        }
    }
    push @filenamelist, File::Spec->catfile( $self->{dir}, 'session' );
    my @selection = $self->get_selected_indices;
    @{ $session{selection} } = @selection;
    if ( defined $version ) { $session{version} = $version }
    store( \%session, File::Spec->catfile( $self->{dir}, 'session' ) );
    if ( defined $filename ) {
        my $tar = Archive::Tar->new;
        $tar->add_files(@filenamelist);
        $tar->write( $filename, TRUE, $EMPTY );
        for my $i ( 0 .. $#{ $self->{data} } ) {
            $self->{data}[$i][2]->{saved} = TRUE;
        }
    }
    return;
}

sub open_session_file {
    my ( $self, %options ) = @_;
    if ( not defined $options{info} ) {
        if ( $options{error_callback} ) {
            $options{error_callback}
              ->( undef, 'Open file', 'Error: session file not supplied.' );
        }
        return;
    }
    my $tar          = Archive::Tar->new( $options{info}, TRUE );
    my @filenamelist = $tar->list_files;
    my @sessionfile  = grep { /\/session$/xsm } @filenamelist;
    my $sesdir =
      File::Spec->catfile( $self->{dir}, dirname( $sessionfile[0] ) );
    for (@filenamelist) {
        $tar->extract_file( $_, File::Spec->catfile( $sesdir, basename($_) ) );
    }
    $self->open_session( dir => $sesdir, delete => TRUE, %options );
    if ( $options{finished_callback} ) { $options{finished_callback}->() }
    return;
}

sub open_session {
    my ( $self, %options ) = @_;
    if ( not defined $options{dir} ) {
        if ( $options{error_callback} ) {
            $options{error_callback}
              ->( undef, 'Open file', 'Error: session folder not defined' );
        }
        return;
    }
    my $sessionfile = File::Spec->catfile( $options{dir}, 'session' );
    if ( not -r $sessionfile ) {
        if ( $options{error_callback} ) {
            $options{error_callback}
              ->( undef, 'Open file', "Error: Unable to read $sessionfile" );
        }
        return;
    }
    my $sessionref = retrieve($sessionfile);

    # hocr -> bboxtree
    if ( not defined $sessionref->{version} ) {
        $logger->info('Restoring pre-2.8.1 session file.');
        for my $key ( keys %{$sessionref} ) {
            if ( ref( $sessionref->{$key} ) eq 'HASH'
                and defined $sessionref->{$key}{hocr} )
            {
                my $tree = Gscan2pdf::Bboxtree->new();
                if ( $sessionref->{$key}{hocr} =~ /<body>[\s\S]*<\/body>/xsm ) {
                    $tree->from_hocr( $sessionref->{$key}{hocr} );
                }
                else {
                    $tree->from_text( $sessionref->{$key}{hocr} );
                }
                $sessionref->{$key}{bboxtree} = $tree->json;
                delete $sessionref->{$key}{hocr};
            }
        }
    }
    else {
        $logger->info("Restoring v$sessionref->{version} session file.");
    }
    my %session = %{$sessionref};

    # Block the row-changed signal whilst adding the scan (row) and sorting it.
    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_block( $self->{row_changed_signal} );
    }
    my @selection = @{ $session{selection} };
    delete $session{selection};
    if ( defined $session{version} ) { delete $session{version} }
    for my $pagenum ( sort { $a <=> $b } ( keys %session ) ) {

        # don't reuse session directory
        $session{$pagenum}{dir}    = $self->{dir};
        $session{$pagenum}{delete} = $options{delete};

        # correct the path now that it is relative to the current session dir
        if ( $options{dir} ne $self->{dir} ) {
            $session{$pagenum}{filename} =
              File::Spec->catfile( $options{dir},
                basename( $session{$pagenum}{filename} ) );
        }

        # Populate the SimpleList
        try {
            my $page = Gscan2pdf::Page->new( %{ $session{$pagenum} } );

            # At some point the main window widget was being stored on the
            # Page object. Restoring this and dumping it via Dumper segfaults.
            # This is tested in t/175_open_session2.t
            if ( defined $page->{window} ) { delete $page->{window} }
            my $thumb =
              $page->get_pixbuf_at_scale( $self->{heightt}, $self->{widtht} );
            push @{ $self->{data} }, [ $pagenum, $thumb, $page ];
        }
        catch {
            if ( $options{error_callback} ) {
                $options{error_callback}->(
                    undef, 'Open file',
                    sprintf __('Error importing page %d. Ignoring.'), $pagenum
                );
            }
        };
    }
    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_unblock( $self->{row_changed_signal} );
    }
    $self->select(@selection);
    return;
}

# Renumber pages

sub renumber {
    my ( $self, $start, $step, $selection ) = @_;

    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_block( $self->{row_changed_signal} );
    }
    if ( defined $start ) {
        if ( not defined $step )      { $step      = 1 }
        if ( not defined $selection ) { $selection = 'all' }

        my @selection;
        if ( $selection eq 'selected' ) {
            @selection = $self->get_selected_indices;
        }
        else {
            @selection = 0 .. $#{ $self->{data} };
        }

        for (@selection) {
            $logger->info("Renumbering page $self->{data}[$_][0]->$start");
            $self->{data}[$_][0] = $start;
            $start += $step;
        }
    }

    # If $start and $step are undefined, just make sure that the numbering is
    # ascending.
    else {
        for ( 1 .. $#{ $self->{data} } ) {
            if ( $self->{data}[$_][0] <= $self->{data}[ $_ - 1 ][0] ) {
                my $new = $self->{data}[ $_ - 1 ][0] + 1;
                $logger->info("Renumbering page $self->{data}[$_][0]->$new");
                $self->{data}[$_][0] = $new;
            }
        }
    }
    if ( defined $self->{row_changed_signal} ) {
        $self->get_model->signal_handler_unblock( $self->{row_changed_signal} );
    }
    return;
}

# Check if $start and $step give duplicate page numbers

sub valid_renumber {
    my ( $self, $start, $step, $selection ) = @_;
    $logger->debug(
"Checking renumber validity of: start $start, step $step, selection $selection"
    );

    return FALSE if ( $step == 0 or $start < 1 );

    # if we are renumbering all pages, just make sure the numbers stay positive
    if ( $selection eq 'all' ) {
        return ( $start + $#{ $self->{data} } * $step > 0 ) ? TRUE : FALSE
          if ( $step < 0 );
        return TRUE;
    }

    # Get list of pages not in selection
    my @selected = $self->get_selected_indices;
    my @all      = ( 0 .. $#{ $self->{data} } );

    # Convert the indices to sets of page numbers
    @selected = $self->index2page_number(@selected);
    @all      = $self->index2page_number(@all);
    my $selected     = Set::IntSpan->new( \@selected );
    my $all          = Set::IntSpan->new( \@all );
    my $not_selected = $all->diff($selected);
    $logger->debug("Page numbers not selected: $not_selected");

    # Create a set from the current settings
    my $current = Set::IntSpan->new;
    for ( 0 .. $#selected ) { $current->insert( $start + $step * $_ ) }
    $logger->debug("Current setting would create page numbers: $current");

    # Are any of the new page numbers the same as those not selected?
    return FALSE if ( $current->intersect($not_selected)->size );
    return TRUE;
}

# helper function to return an array of page numbers given an array of page indices

sub index2page_number {
    my ( $self, @index ) = @_;
    for (@index) {
        $_ = ${ $self->{data} }[$_][0];
    }
    return @index;
}

# return array index of pages depending on which radiobutton is active

sub get_page_index {
    my ( $self, $page_range, $error_callback ) = @_;
    my @index;
    if ( $page_range eq 'all' ) {
        if ( @{ $self->{data} } ) {
            return 0 .. $#{ $self->{data} };
        }
        else {
            $error_callback->( undef, 'Get page', __('No pages to process') );
            return;
        }
    }
    elsif ( $page_range eq 'selected' ) {
        @index = $self->get_selected_indices;
        if ( @index == 0 ) {
            $error_callback->( undef, 'Get page', __('No pages selected') );
            return;
        }
    }
    return @index;
}

# Have to roll my own slurp sub to support utf8

sub slurp {
    my ($file) = @_;

    local $INPUT_RECORD_SEPARATOR = undef;
    my ($text);

    if ( ref($file) eq 'GLOB' ) {
        $text = <$file>;
    }
    else {
        open my $fh, '<:encoding(UTF8)', $file
          or die "Error: cannot open $file\n";
        $text = <$fh>;
        close $fh or die "Error: cannot close $file\n";
    }
    return $text;
}

sub unescape_utf8 {
    my ($text) = @_;
    if ( defined $text ) {
        $text =~
          s{\\(?:([0-7]{1,3})|(.))} {defined($1) ? chr(oct($1)) : $2}xsmeg;
    }
    return decode( 'UTF-8', $text );
}

sub exec_command {
    my ( $cmd, $pidfile ) = @_;

    # remove empty arguments in $cmd
    my $i = 0;
    while ( $i <= $#{$cmd} ) {
        if ( not defined $cmd->[$i] or $cmd->[$i] eq $EMPTY ) {
            splice @{$cmd}, $i, 1;
        }
        else {
            ++$i;
        }
    }
    if ( defined $logger ) { $logger->info( join $SPACE, @{$cmd} ) }

    # we create a symbol for the err because open3 will not do that for us
    my $err = gensym();
    my ( $pid, $reader );
    try {
        $pid = open3( undef, $reader, $err, @{$cmd} );
    }
    catch {
        $pid = 0;
    };
    if ( $pid == 0 ) {
        return $PROCESS_FAILED, undef,
          join( $SPACE, @{$cmd} ) . ': command not found';
    }
    if ( defined $logger ) { $logger->info("Spawned PID $pid") }

    if ( defined $pidfile ) {
        open my $fh, '>', $pidfile or return $PROCESS_FAILED;
        $fh->print($pid);
        close $fh or return $PROCESS_FAILED;
    }

    # slurping these before waitpid, as if the output is larger than 65535,
    # waitpid hangs forever.
    $reader = unescape_utf8( slurp($reader) );
    $err    = unescape_utf8( slurp($err) );

    # Using 0 for flags, rather than WNOHANG to ensure that we wait for the
    # process to finish and not leave a zombie
    waitpid $pid, 0;
    my $child_exit_status = $CHILD_ERROR >> $BITS_PER_BYTE;
    return $child_exit_status, $reader, $err;
}

# wrapper for _program_version below

sub program_version {
    my ( $stream, $regex, $cmd ) = @_;
    return _program_version( $stream, $regex, exec_command($cmd) );
}

# Check exec_command output for version number
# Don't call exec_command directly to allow us to test output we can't reproduce.

sub _program_version {
    my ( $stream, $regex, @output ) = @_;
    my ( $status, $out,   $err )    = @output;
    if ( not defined $out ) { $out = q{} }
    if ( not defined $err ) { $err = q{} }
    my $output;
    given ($stream) {
        when ('stdout') {
            $output = $out
        }
        when ('stderr') {
            $output = $err
        }
        when ('both') {
            $output = $out . $err
        }
        default {
            $logger->error("Unknown stream: '$stream'");
        }
    }
    if ( $output =~ $regex ) { return $1 }
    if ( $status == $PROCESS_FAILED ) {
        $logger->info($err);
        return $PROCESS_FAILED;
    }
    $logger->info("Unable to parse version string from: '$output'");
    return;
}

# Check that a command exists

sub check_command {
    my ($cmd) = @_;
    my ( undef, $exe ) = exec_command( [ 'which', $cmd ] );
    return ( defined $exe and $exe ne $EMPTY ? TRUE : FALSE );
}

# Compute a timestamp

sub timestamp {
    my @time = localtime;

    # return a time which can be string-wise compared
    return sprintf '%04d%02d%02d%02d%02d%02d', reverse @time[ 0 .. $YEAR ];
}

sub text_to_datetime {
    my ( $text, $thisyear, $thismonth, $thisday ) = @_;
    my ( $year, $month, $day, $hour, $minute, $sec );
    if ( defined $text
        and $text =~
        /^(\d+)?-?(\d+)?-?(\d+)?(?:\s(\d+)?:?(\d+)?:?(\d+)?)?$/smx )
    {
        ( $year, $month, $day, $hour, $minute, $sec ) =
          ( $1, $2, $3, $4, $5, $6 );
    }
    if ( not defined $year ) { $year = $thisyear }
    if ( not defined $month or $month < 1 or $month > $MONTHS_PER_YEAR ) {
        $month = $thismonth;
    }
    if ( not defined $day or $day < 1 or $day > $DAYS_PER_MONTH ) {
        $day = $thisday;
    }
    if ( not defined $hour or $hour > $HOURS_PER_DAY - 1 ) {
        $hour = 0;
    }
    if ( not defined $minute or $minute > $MINUTES_PER_HOUR - 1 ) {
        $minute = 0;
    }
    if ( not defined $sec or $sec > $SECONDS_PER_MINUTE - 1 ) {
        $sec = 0;
    }
    return $year + 0, $month + 0, $day + 0, $hour + 0, $minute + 0, $sec + 0;
}

sub expand_metadata_pattern {
    my (%data) = @_;
    my ( $dyear, $dmonth, $dday, $dhour, $dmin, $dsec ) = @{ $data{docdate} };
    my ( $tyear, $tmonth, $tday, $thour, $tmin, $tsec ) =
      @{ $data{today_and_now} };
    if ( not defined $dhour ) { $dhour = 0 }
    if ( not defined $dmin )  { $dmin  = 0 }
    if ( not defined $dsec )  { $dsec  = 0 }
    if ( not defined $thour ) { $thour = 0 }
    if ( not defined $tmin )  { $tmin  = 0 }
    if ( not defined $tsec )  { $tsec  = 0 }

    # Expand author, title and extension
    $data{template} =~ s/%Da/$data{author}/gsm;
    $data{template} =~ s/%Dt/$data{title}/gsm;
    $data{template} =~ s/%De/$data{extension}/gsm;

    # Expand convert %Dx code to %x, convert using strftime and replace
    while ( $data{template} =~ /%D([[:alpha:]])/smx ) {
        my $code     = $1;
        my $template = "$PERCENT$code";
        my $result   = POSIX::strftime(
            $template, $dsec, $dmin, $dhour, $dday,
            $dmonth + $STRFTIME_MONTH_OFFSET,
            $dyear + $STRFTIME_YEAR_OFFSET
        );
        $data{template} =~ s/%D$code/$result/gsmx;
    }

    # Expand basic strftime codes
    $data{template} = POSIX::strftime(
        $data{template}, $tsec, $tmin, $thour, $tday,
        $tmonth + $STRFTIME_MONTH_OFFSET,
        $tyear + $STRFTIME_YEAR_OFFSET
    );

    # avoid leading and trailing whitespace in expanded filename template
    $data{template} =~ s/^\s*(.*?)\s*$/$1/xsm;

    if ( $data{convert_whitespace} ) { $data{template} =~ s/\s/_/gsm }

    return $data{template};
}

# Normally, it would be more sensible to put this in main::, but in order to
# run unit tests on the sub, it has been moved here.

sub collate_metadata {
    my ( $settings, $today_and_now, $timezone ) = @_;
    my %metadata;
    for my $key (qw/author title subject keywords/) {
        if ( defined $settings->{$key} ) {
            $metadata{$key} = $settings->{$key};
        }
    }
    $metadata{datetime} = [
        Add_Delta_DHMS(
            @{$today_and_now}, @{ $settings->{'datetime offset'} }
        )
    ];
    if ( not $settings->{use_time} ) {

        # Set time to zero
        my @time = ( 0, 0, 0 );
        splice @{ $metadata{datetime} }, @{ $metadata{datetime} } - @time,
          @time, @time;
    }
    if ( defined $settings->{use_timezone} ) {
        $metadata{tz} = [
            add_delta_timezone(
                @{$timezone}, @{ $settings->{'timezone offset'} }
            )
        ];
    }
    return \%metadata;
}

# calculate delta between two timezones - mostly to spot differences between
# DST.

sub add_delta_timezone {
    my @tz_delta = @_;
    my @tz1      = splice @tz_delta, 0, @tz_delta / 2;
    my @tz2;
    for my $i ( 0 .. $#tz1 ) {
        $tz2[$i] = $tz1[$i] + $tz_delta[$i];
    }
    return @tz2;
}

# apply timezone delta

sub delta_timezone {
    my @tz2 = @_;
    my @tz1 = splice @tz2, 0, @tz2 / 2;
    my @tz_delta;
    for my $i ( 0 .. $#tz1 ) {
        $tz_delta[$i] = $tz2[$i] - $tz1[$i];
    }
    return @tz_delta;
}

sub prepare_output_metadata {
    my ( $type, $metadata ) = @_;
    my %h;

    if ( $type eq 'PDF' or $type eq 'DjVu' ) {
        my $dateformat =
          $type eq 'PDF'
          ? "D:%4i%02i%02i%02i%02i%02i%1s%02i'%02i'"
          : '%4i-%02i-%02i %02i:%02i:%02i%1s%02i:%02i';
        my ( $year, $month, $day, $hour, $min, $sec ) =
          @{ $metadata->{datetime} };
        my ( $sign, $dh, $dm ) = ( q{+}, 0, 0 );
        if ( defined $metadata->{tz} ) {
            ( undef, undef, undef, $dh, $dm, undef, undef ) =
              @{ $metadata->{tz} };
            if ( $dh * $MINUTES_PER_HOUR + $dm < 0 ) { $sign = q{-} }
            $dh = abs $dh;
            $dm = abs $dm;
        }
        $h{CreationDate} = sprintf $dateformat, $year, $month, $day, $hour,
          $min, $sec, $sign,
          $dh, $dm;
        $h{ModDate} = $h{CreationDate};
        $h{Creator} = "gscan2pdf v$Gscan2pdf::Document::VERSION";
        if ( $type eq 'DjVu' ) { $h{Producer} = 'djvulibre' }
        for my $key (qw/author title subject keywords/) {
            if ( defined $metadata->{$key} ) {
                $h{ ucfirst $key } = $metadata->{$key};
            }
        }
    }

    return \%h;
}

# Set session dir

sub set_dir {
    my ( $self, $dir ) = @_;
    $self->{dir} = $dir;
    return;
}

sub _enqueue_request {
    my ( $action, $data ) = @_;
    my $sentinel : shared = 0;
    $_self->{requests}->enqueue(
        {
            action   => $action,
            sentinel => \$sentinel,
            ( $data ? %{$data} : () )
        }
    );
    $jobs_total++;
    return \$sentinel;
}

sub _monitor_process {
    my ( $self, %options ) = @_;

    if ( defined $options{pidfile} ) {
        $self->{running_pids}{"$options{pidfile}"} = "$options{pidfile}";
    }

    if ( $callback{ $options{uuid} }{queued} ) {
        $callback{ $options{uuid} }{queued}->(
            process_name   => $_self->{process_name},
            jobs_completed => $jobs_completed,
            jobs_total     => $jobs_total
        );
    }

    Glib::Timeout->add(
        $_POLL_INTERVAL,
        sub {
            if ( ${ $options{sentinel} } == 2 ) {
                $self->_monitor_process_finished_callback( \%options );
                return Glib::SOURCE_REMOVE;
            }
            elsif ( ${ $options{sentinel} } == 1 ) {
                $self->_monitor_process_running_callback( \%options );
                return Glib::SOURCE_CONTINUE;
            }
            return Glib::SOURCE_CONTINUE;
        }
    );
    return $options{pidfile};
}

sub _monitor_process_running_callback {
    my ( $self, $options ) = @_;
    if ( $_self->{cancel} ) { return }
    if ( $callback{ $options->{uuid} }{started} ) {
        $callback{ $options->{uuid} }{started}->(
            1, $_self->{process_name},
            $jobs_completed, $jobs_total, $_self->{message}, $_self->{progress}
        );
        delete $callback{ $options->{uuid} }{started};
    }
    if ( $callback{ $options->{uuid} }{running} ) {
        $callback{ $options->{uuid} }{running}->(
            process        => $_self->{process_name},
            jobs_completed => $jobs_completed,
            jobs_total     => $jobs_total,
            message        => $_self->{message},
            progress       => $_self->{progress}
        );
    }
    return;
}

sub _monitor_process_finished_callback {
    my ( $self, $options ) = @_;
    if ( $_self->{cancel} ) { return }
    if ( $callback{ $options->{uuid} }{started} ) {
        $callback{ $options->{uuid} }{started}->(
            undef, $_self->{process_name},
            $jobs_completed, $jobs_total, $_self->{message}, $_self->{progress}
        );
        delete $callback{ $options->{uuid} }{started};
    }
    if ( $_self->{status} ) {
        if ( $callback{ $options->{uuid} }{error} ) {
            $callback{ $options->{uuid} }{error}->( $_self->{message} );
        }
        return;
    }
    $self->check_return_queue;
    if ( defined $options->{pidfile} ) {
        delete $self->{running_pids}{"$options->{pidfile}"};
    }
    return;
}

sub _thread_main {
    my ($self) = @_;

    while ( my $request = $self->{requests}->dequeue ) {
        $self->{process_name} = $request->{action};

        # Signal the sentinel that the request was started.
        ${ $request->{sentinel} }++;

        # Ask for page data given UUID
        if ( defined $request->{page} ) {
            $self->{return}
              ->enqueue( { type => 'page request', uuid => $request->{page} } );
            my $page_request = $self->{pages}->dequeue;
            if ( $page_request->{page} eq 'cancel' ) { next }
            $request->{page} = $page_request->{page};
        }
        elsif ( defined $request->{list_of_pages} ) {
            my $cancel = FALSE;
            for my $i ( 0 .. $#{ $request->{list_of_pages} } ) {
                $self->{return}->enqueue(
                    {
                        type => 'page request',
                        uuid => $request->{list_of_pages}[$i]
                    }
                );
                my $page_request = $self->{pages}->dequeue;
                if ( $page_request->{page} eq 'cancel' ) {
                    $cancel = TRUE;
                    last;
                }
                $request->{list_of_pages}[$i] = $page_request->{page};
            }
            if ($cancel) { next }
        }

        given ( $request->{action} ) {
            when ('analyse') {
                _thread_analyse( $self, $request->{list_of_pages},
                    $request->{uuid} );
            }

            when ('brightness-contrast') {
                _thread_brightness_contrast(
                    $self,
                    page       => $request->{page},
                    brightness => $request->{brightness},
                    contrast   => $request->{contrast},
                    dir        => $request->{dir},
                    uuid       => $request->{uuid}
                );
            }

            when ('cancel') {
                lock( $_self->{pages} )
                  ;    # unlocks automatically when out of scope

                # Empty pages queue
                while ( $_self->{pages}->pending ) {
                    $_self->{pages}->dequeue;
                }
                $self->{return}->enqueue(
                    { type => 'cancelled', uuid => $request->{uuid} } );
            }

            when ('crop') {
                _thread_crop(
                    $self,
                    page => $request->{page},
                    x    => $request->{x},
                    y    => $request->{y},
                    w    => $request->{w},
                    h    => $request->{h},
                    dir  => $request->{dir},
                    uuid => $request->{uuid},
                );
            }

            when ('split') {
                _thread_split(
                    $self,
                    page      => $request->{page},
                    direction => $request->{direction},
                    position  => $request->{position},
                    dir       => $request->{dir},
                    uuid      => $request->{uuid},
                );
            }

            when ('cuneiform') {
                _thread_cuneiform(
                    $self,
                    page      => $request->{page},
                    language  => $request->{language},
                    threshold => $request->{threshold},
                    pidfile   => $request->{pidfile},
                    uuid      => $request->{uuid}
                );
            }

            when ('get-file-info') {
                _thread_get_file_info(
                    $self,
                    filename => $request->{path},
                    password => $request->{password},
                    pidfile  => $request->{pidfile},
                    uuid     => $request->{uuid}
                );
            }

            when ('gocr') {
                _thread_gocr( $self, $request->{page}, $request->{threshold},
                    $request->{pidfile}, $request->{uuid} );
            }

            when ('import-file') {
                _thread_import_file(
                    $self,
                    info     => $request->{info},
                    password => $request->{password},
                    first    => $request->{first},
                    last     => $request->{last},
                    dir      => $request->{dir},
                    pidfile  => $request->{pidfile},
                    uuid     => $request->{uuid}
                );
            }

            when ('negate') {
                _thread_negate(
                    $self,           $request->{page},
                    $request->{dir}, $request->{uuid}
                );
            }

            when ('ocropus') {
                _thread_ocropus(
                    $self,
                    page      => $request->{page},
                    language  => $request->{language},
                    threshold => $request->{threshold},
                    pidfile   => $request->{pidfile},
                    uuid      => $request->{uuid}
                );
            }

            when ('paper_sizes') {
                _thread_paper_sizes( $self, $request->{paper_sizes} );
            }

            when ('quit') {
                last;
            }

            when ('rotate') {
                _thread_rotate(
                    $self,           $request->{angle}, $request->{page},
                    $request->{dir}, $request->{uuid}
                );
            }

            when ('save-djvu') {
                _thread_save_djvu(
                    $self,
                    path          => $request->{path},
                    list_of_pages => $request->{list_of_pages},
                    metadata      => $request->{metadata},
                    options       => $request->{options},
                    dir           => $request->{dir},
                    pidfile       => $request->{pidfile},
                    uuid          => $request->{uuid}
                );
            }

            when ('save-hocr') {
                _thread_save_hocr( $self, $request->{path},
                    $request->{list_of_pages},
                    $request->{options}, $request->{uuid} );
            }

            when ('save-image') {
                _thread_save_image(
                    $self,
                    path          => $request->{path},
                    list_of_pages => $request->{list_of_pages},
                    pidfile       => $request->{pidfile},
                    options       => $request->{options},
                    uuid          => $request->{uuid}
                );
            }

            when ('save-pdf') {
                _thread_save_pdf(
                    $self,
                    path          => $request->{path},
                    list_of_pages => $request->{list_of_pages},
                    metadata      => $request->{metadata},
                    options       => $request->{options},
                    dir           => $request->{dir},
                    pidfile       => $request->{pidfile},
                    uuid          => $request->{uuid}
                );
            }

            when ('save-text') {
                _thread_save_text( $self, $request->{path},
                    $request->{list_of_pages},
                    $request->{options}, $request->{uuid} );
            }

            when ('save-tiff') {
                _thread_save_tiff(
                    $self,
                    path          => $request->{path},
                    list_of_pages => $request->{list_of_pages},
                    options       => $request->{options},
                    dir           => $request->{dir},
                    pidfile       => $request->{pidfile},
                    uuid          => $request->{uuid}
                );
            }

            when ('tesseract') {
                _thread_tesseract(
                    $self,
                    page      => $request->{page},
                    language  => $request->{language},
                    threshold => $request->{threshold},
                    pidfile   => $request->{pidfile},
                    uuid      => $request->{uuid}
                );
            }

            when ('threshold') {
                _thread_threshold( $self, $request->{threshold},
                    $request->{page}, $request->{dir}, $request->{uuid} );
            }

            when ('to-png') {
                _thread_to_png(
                    $self,           $request->{page},
                    $request->{dir}, $request->{uuid}
                );
            }

            when ('unpaper') {
                _thread_unpaper(
                    $self,
                    page    => $request->{page},
                    options => $request->{options},
                    pidfile => $request->{pidfile},
                    dir     => $request->{dir},
                    uuid    => $request->{uuid}
                );
            }

            when ('unsharp') {
                _thread_unsharp(
                    $self,
                    page      => $request->{page},
                    radius    => $request->{radius},
                    sigma     => $request->{sigma},
                    gain      => $request->{gain},
                    threshold => $request->{threshold},
                    dir       => $request->{dir},
                    uuid      => $request->{uuid},
                );
            }

            when ('user-defined') {
                _thread_user_defined(
                    $self,
                    page    => $request->{page},
                    command => $request->{command},
                    dir     => $request->{dir},
                    pidfile => $request->{pidfile},
                    uuid    => $request->{uuid}
                );
            }

            default {
                $logger->info(
                    'Ignoring unknown request ' . $request->{action} );
                next;
            }
        }

        # Signal the sentinel that the request was completed.
        ${ $request->{sentinel} }++;

        undef $self->{process_name};
    }
    return;
}

sub _thread_throw_error {
    my ( $self, $uuid, $page_uuid, $process, $message ) = @_;
    $self->{return}->enqueue(
        {
            type    => 'error',
            uuid    => $uuid,
            page    => $page_uuid,
            process => $process,
            message => $message
        }
    );
    return;
}

sub _thread_get_file_info {
    my ( $self, %options ) = @_;

    if ( not -e $options{filename} ) {
        _thread_throw_error(
            $self,       $options{uuid}, $options{page}{uuid},
            'Open file', sprintf __('File %s not found'),
            $options{filename}
        );
        return;
    }

    $logger->info("Getting info for $options{filename}");
    ( undef, my $format ) =
      exec_command( [ 'file', '-b', $options{filename} ] );
    chomp $format;
    $logger->info("Format: '$format'");

    given ($format) {
        when ('very short file (no magic)') {
            _thread_throw_error(
                $self,
                $options{uuid},
                $options{page}{uuid},
                'Open file',
                sprintf __('Error importing zero-length file %s.'),
                $options{filename}
            );
            return;
        }
        when (/gzip[ ]compressed[ ]data/xsm) {
            $options{info}{path}   = $options{filename};
            $options{info}{format} = 'session file';
            $self->{return}->enqueue(
                {
                    type => 'file-info',
                    uuid => $options{uuid},
                    info => $options{info}
                }
            );
            return;
        }
        when (/DjVu/xsm) {

            # Dig out the number of pages
            ( undef, my $info, my $err ) =
              exec_command( [ 'djvudump', $options{filename} ],
                $options{pidfile} );
            if ( $err =~ /command[ ]not[ ]found/xsm ) {
                _thread_throw_error(
                    $self,
                    $options{uuid},
                    $options{page}{uuid},
                    'Open file',
                    __(
'Please install djvulibre-bin in order to open DjVu files.'
                    )
                );
                return;
            }
            $logger->info($info);
            return if $_self->{cancel};

            my $pages = 1;
            if ( $info =~ /\s(\d+)\s+page/xsm ) {
                $pages = $1;
            }

            # Dig out the size and resolution of each page
            my ( @width, @height, @ppi );
            $options{info}{format} = 'DJVU';
            while ( $info =~ /DjVu\s(\d+)x(\d+).+?\s+(\d+)\s+dpi(.*)/xsm ) {
                push @width,  $1;
                push @height, $2;
                push @ppi,    $3;
                $info = $4;
                $logger->info(
"Page $#ppi is $width[$#width]x$height[$#height], $ppi[$#ppi] ppi"
                );
            }
            if ( $pages != @ppi ) {
                _thread_throw_error(
                    $self,
                    $options{uuid},
                    $options{page}{uuid},
                    'Open file',
                    __(
'Unknown DjVu file structure. Please contact the author.'
                    )
                );
                return;
            }
            $options{info}{width}  = \@width;
            $options{info}{height} = \@height;
            $options{info}{ppi}    = \@ppi;
            $options{info}{pages}  = $pages;
            $options{info}{path}   = $options{filename};

            # Dig out the metadata
            ( undef, $info ) =
              exec_command(
                [ 'djvused', $options{filename}, '-e', 'print-meta' ],
                $options{pidfile} );
            $logger->info($info);
            return if $_self->{cancel};

            # extract the metadata from the file
            _add_metadata_to_info( $options{info}, $info, qr{\s+"([^"]+)}xsm );

            $self->{return}->enqueue(
                {
                    type => 'file-info',
                    uuid => $options{uuid},
                    info => $options{info}
                }
            );
            return;
        }
        when (/PDF[ ]document/xsm) {
            $format = 'Portable Document Format';
            my $args = [ 'pdfinfo', '-isodates', $options{filename} ];
            if ( defined $options{password} ) {
                $args = [
                    'pdfinfo', '-isodates',
                    '-upw',    $options{password},
                    $options{filename}
                ];
            }
            ( undef, my $info, my $error ) =
              exec_command( $args, $options{pidfile} );
            return if $_self->{cancel};
            $logger->info("stdout: $info");
            $logger->info("stderr: $error");
            if ( defined $error and $error =~ /Incorrect[ ]password/xsm ) {
                $options{info}{encrypted} = TRUE;
            }
            else {
                $options{info}{pages} = 1;
                if ( $info =~ /Pages:\s+(\d+)/xsm ) {
                    $options{info}{pages} = $1;
                }
                $logger->info("$options{info}{pages} pages");
                my $float = qr{\d+(?:[.]\d*)?}xsm;
                if ( $info =~
                    /Page\ssize:\s+($float)\s+x\s+($float)\s+(\w+)/xsm )
                {
                    $options{info}{page_size} = [ $1, $2, $3 ];
                    $logger->info("Page size: $1 x $2 $3");
                }

                # extract the metadata from the file
                _add_metadata_to_info( $options{info}, $info,
                    qr{:\s+([^\n]+)}xsm );
            }
        }

        # A JPEG which I was unable to reproduce as a test case had what
        # seemed to be a TIFF thumbnail which file -b reported, and therefore
        # gscan2pdf attempted to import it as a TIFF. Therefore forcing the text
        # to appear at the beginning of the file -b output.
        when (/^TIFF[ ]image[ ]data/xsm) {
            $format = 'Tagged Image File Format';
            ( undef, my $info ) =
              exec_command( [ 'tiffinfo', $options{filename} ],
                $options{pidfile} );
            return if $_self->{cancel};
            $logger->info($info);

            # Count number of pages
            $options{info}{pages} = () =
              $info =~ /TIFF[ ]Directory[ ]at[ ]offset/xsmg;
            $logger->info("$options{info}{pages} pages");

            # Dig out the size of each page
            my ( @width, @height );
            while (
                $info =~ /Image\sWidth:\s(\d+)\sImage\sLength:\s(\d+)(.*)/xsm )
            {
                push @width,  $1;
                push @height, $2;
                $info = $3;
                $logger->info(
                    "Page $#width is $width[$#width]x$height[$#height]");
            }
            $options{info}{width}  = \@width;
            $options{info}{height} = \@height;
        }
        default {

            # Get file type
            my $image = Image::Magick->new;
            my $e     = $image->Read( $options{filename} );
            if ("$e") {
                $logger->error($e);
                _thread_throw_error(
                    $self,
                    $options{uuid},
                    $options{page}{uuid},
                    'Open file',
                    sprintf __('%s is not a recognised image type'),
                    $options{filename}
                );
                return;
            }
            return if $_self->{cancel};
            $format = $image->Get('format');
            if ( not defined $format ) {
                _thread_throw_error(
                    $self,
                    $options{uuid},
                    $options{page}{uuid},
                    'Open file',
                    sprintf __('%s is not a recognised image type'),
                    $options{filename}
                );
                return;
            }
            $logger->info("Format $format");
            $options{info}{width}       = $image->Get('width');
            $options{info}{height}      = $image->Get('height');
            $options{info}{xresolution} = $image->Get('xresolution');
            $options{info}{yresolution} = $image->Get('yresolution');
            $options{info}{pages}       = 1;
        }
    }
    $options{info}{format} = $format;
    $options{info}{path}   = $options{filename};
    $self->{return}->enqueue(
        { type => 'file-info', uuid => $options{uuid}, info => $options{info} }
    );
    return;
}

sub _add_metadata_to_info {
    my ( $info, $string, $regex ) = @_;
    my %kw_lookup = (
        Title        => 'title',
        Subject      => 'subject',
        Keywords     => 'keywords',
        Author       => 'author',
        CreationDate => 'datetime',
    );

    while ( my ( $key, $value ) = each %kw_lookup ) {
        if ( $string =~ /$key$regex/xsm ) {
            $info->{$value} = $1;
        }
    }
    return;
}

sub _thread_import_file {
    my ( $self, %options ) = @_;
    if ( not defined $options{info} ) { return }
    my $PNG = qr/Portable[ ]Network[ ]Graphics/xsm;
    my $JPG = qr/Joint[ ]Photographic[ ]Experts[ ]Group[ ]JFIF[ ]format/xsm;
    my $GIF = qr/CompuServe[ ]graphics[ ]interchange[ ]format/xsm;

    given ( $options{info}{format} ) {
        when ('DJVU') {

            # Extract images from DjVu
            if ( $options{last} >= $options{first} and $options{first} > 0 ) {
                for my $i ( $options{first} .. $options{last} ) {
                    $self->{progress} =
                      ( $i - 1 ) / ( $options{last} - $options{first} + 1 );
                    $self->{message} =
                      sprintf __('Importing page %i of %i'),
                      $i, $options{last} - $options{first} + 1;

                    my ( $tif, $txt, $error );
                    try {
                        $tif = File::Temp->new(
                            DIR    => $options{dir},
                            SUFFIX => '.tif',
                            UNLINK => FALSE
                        );
                        exec_command(
                            [
                                'ddjvu',    '-format=tiff',
                                "-page=$i", $options{info}{path},
                                $tif
                            ],
                            $options{pidfile}
                        );
                        ( undef, $txt ) = exec_command(
                            [
                                'djvused', $options{info}{path},
                                '-e',      "select $i; print-txt"
                            ],
                            $options{pidfile}
                        );
                    }
                    catch {
                        if ( defined $tif ) {
                            $logger->error("Caught error creating $tif: $_");
                            _thread_throw_error(
                                $self,
                                $options{uuid},
                                $options{page}{uuid},
                                'Open file',
                                "Error: unable to write to $tif."
                            );
                        }
                        else {
                            $logger->error(
                                "Caught error writing to $options{dir}: $_");
                            _thread_throw_error(
                                $self,
                                $options{uuid},
                                $options{page}{uuid},
                                'Open file',
                                "Error: unable to write to $options{dir}."
                            );
                        }
                        $error = TRUE;
                    };
                    return if ( $_self->{cancel} or $error );
                    my $page = Gscan2pdf::Page->new(
                        filename    => $tif,
                        dir         => $options{dir},
                        delete      => TRUE,
                        format      => 'Tagged Image File Format',
                        xresolution => $options{info}{ppi}[ $i - 1 ],
                        yresolution => $options{info}{ppi}[ $i - 1 ],
                        width       => $options{info}{width}[ $i - 1 ],
                        height      => $options{info}{height}[ $i - 1 ],
                    );
                    try {
                        $page->import_djvutext($txt);
                    }
                    catch {
                        $logger->error(
                            "Caught error parsing DjVU text layer: $_");
                        _thread_throw_error( $self, $options{uuid},
                            $options{page}{uuid},
                            'Open file', 'Error: parsing DjVU text layer' );
                    };
                    $self->{return}->enqueue(
                        {
                            type => 'page',
                            uuid => $options{uuid},
                            page => $page->freeze
                        }
                    );
                }
            }
        }
        when ('Portable Document Format') {
            _thread_import_pdf( $self, %options );
        }
        when ('Tagged Image File Format') {

            # Only one page, so skip tiffcp in case it gives us problems
            if ( $options{last} == 1 ) {
                $self->{progress} = 1;
                $self->{message}  = sprintf __('Importing page %i of %i'), 1, 1;
                my $page = Gscan2pdf::Page->new(
                    filename => $options{info}{path},
                    dir      => $options{dir},
                    delete   => FALSE,
                    format   => $options{info}{format},
                    width    => $options{info}{width}[0],
                    height   => $options{info}{height}[0],
                );
                $self->{return}->enqueue(
                    {
                        type => 'page',
                        uuid => $options{uuid},
                        page => $page->freeze
                    }
                );
            }

            # Split the tiff into its pages and import them individually
            elsif ( $options{last} >= $options{first} and $options{first} > 0 )
            {
                for my $i ( $options{first} - 1 .. $options{last} - 1 ) {
                    $self->{progress} =
                      $i / ( $options{last} - $options{first} + 1 );
                    $self->{message} =
                      sprintf __('Importing page %i of %i'),
                      $i, $options{last} - $options{first} + 1;

                    my ( $tif, $error );
                    try {
                        $tif = File::Temp->new(
                            DIR    => $options{dir},
                            SUFFIX => '.tif',
                            UNLINK => FALSE
                        );
                        my ( $status, $out, $err ) =
                          exec_command(
                            [ 'tiffcp', "$options{info}{path},$i", $tif ],
                            $options{pidfile} );
                        if ( defined $err and $err ne $EMPTY ) {
                            $logger->error(
"Caught error extracting page $i from $options{info}{path}: $err"
                            );
                            _thread_throw_error(
                                $self,
                                $options{uuid},
                                $options{page}{uuid},
                                'Open file',
"Caught error extracting page $i from $options{info}{path}: $err"
                            );
                        }
                    }
                    catch {
                        if ( defined $tif ) {
                            $logger->error("Caught error creating $tif: $_");
                            _thread_throw_error(
                                $self,
                                $options{uuid},
                                $options{page}{uuid},
                                'Open file',
                                "Error: unable to write to $tif."
                            );
                        }
                        else {
                            $logger->error(
                                "Caught error writing to $options{dir}: $_");
                            _thread_throw_error(
                                $self,
                                $options{uuid},
                                $options{page}{uuid},
                                'Open file',
                                "Error: unable to write to $options{dir}."
                            );
                        }
                        $error = TRUE;
                    };
                    return if ( $_self->{cancel} or $error );
                    my $page = Gscan2pdf::Page->new(
                        filename => $tif,
                        dir      => $options{dir},
                        delete   => TRUE,
                        format   => $options{info}{format},
                        width    => $options{info}{width}[ $i - 1 ],
                        height   => $options{info}{height}[ $i - 1 ],
                    );
                    $self->{return}->enqueue(
                        {
                            type => 'page',
                            uuid => $options{uuid},
                            page => $page->freeze
                        }
                    );
                }
            }
        }
        when (/(?:$PNG|$JPG|$GIF)/xsm) {
            try {
                my $page = Gscan2pdf::Page->new(
                    filename    => $options{info}{path},
                    dir         => $options{dir},
                    format      => $options{info}{format},
                    width       => $options{info}{width},
                    height      => $options{info}{height},
                    xresolution => $options{info}{xresolution},
                    yresolution => $options{info}{yresolution},
                );
                $self->{return}->enqueue(
                    {
                        type => 'page',
                        uuid => $options{uuid},
                        page => $page->freeze
                    }
                );
            }
            catch {
                $logger->error("Caught error writing to $options{dir}: $_");
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Open file', "Error: unable to write to $options{dir}." );
            };
        }

        # only 1-bit Portable anymap is properly supported,
        # so convert ANY pnm to png
        default {
            try {
                my $page = Gscan2pdf::Page->new(
                    filename => $options{info}{path},
                    dir      => $options{dir},
                    format   => $options{info}{format},
                    width    => $options{info}{width},
                    height   => $options{info}{height},
                );
                $self->{return}->enqueue(
                    {
                        type => 'page',
                        uuid => $options{uuid},
                        page => $page->to_png($paper_sizes)->freeze
                    }
                );
            }
            catch {
                $logger->error("Caught error writing to $options{dir}: $_");
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Open file', "Error: unable to write to $options{dir}." );
            };
        }
    }
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'import-file',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_import_pdf {
    my ( $self, %options ) = @_;
    my ( $warning_flag, $xresolution, $yresolution );

    # Extract images from PDF
    if ( $options{last} >= $options{first} and $options{first} > 0 ) {
        for my $i ( $options{first} .. $options{last} ) {
            my $args =
              [ 'pdfimages', '-f', $i, '-l', $i, '-list',
                $options{info}{path} ];
            if ( defined $options{password} ) {
                splice @{$args}, 1, 0, '-upw', $options{password};
            }
            my ( $status, $out, $err ) =
              exec_command( $args, $options{pidfile} );
            for ( split /\n/xsm, $out ) {
                ( $xresolution, $yresolution ) = unpack 'x69A6xA6';
                if ( $xresolution =~ /\d/xsm ) { last }
            }
            $args =
              [ 'pdfimages', '-f', $i, '-l', $i, $options{info}{path}, 'x' ];
            if ( defined $options{password} ) {
                splice @{$args}, 1, 0, '-upw', $options{password};
            }
            ( $status, $out, $err ) =
              exec_command( $args, $options{pidfile} );
            return if $_self->{cancel};
            if ($status) {
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Open file', __('Error extracting images from PDF') );
            }

            my $html =
              File::Temp->new( DIR => $options{dir}, SUFFIX => '.html' );
            $args = [
                'pdftotext', '-bbox', '-f', $i, '-l', $i,
                $options{info}{path}, $html
            ];
            if ( defined $options{password} ) {
                splice @{$args}, 1, 0, '-upw', $options{password};
            }
            ( $status, $out, $err ) = exec_command( $args, $options{pidfile} );
            return if $_self->{cancel};
            if ($status) {
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Open file', __('Error extracting text layer from PDF') );
            }

            # Import each image
            my @images = glob 'x-??*.???';
            if ( @images != 1 ) { $warning_flag = TRUE }
            for (@images) {
                my ($ext) = /([^.]+)$/xsm;
                try {
                    my $page = Gscan2pdf::Page->new(
                        filename    => $_,
                        dir         => $options{dir},
                        delete      => TRUE,
                        format      => $format{$ext},
                        xresolution => $xresolution,
                        yresolution => $yresolution,
                    );
                    $page->import_pdftotext( slurp($html) );
                    $self->{return}->enqueue(
                        {
                            type => 'page',
                            uuid => $options{uuid},
                            page => $page->to_png($paper_sizes)->freeze
                        }
                    );
                }
                catch {
                    $logger->error("Caught error importing PDF: $_");
                    _thread_throw_error( $self, $options{uuid},
                        $options{page}{uuid},
                        'Open file', __('Error importing PDF') );
                };
            }
        }

        if ($warning_flag) {
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Open file', __(<<'EOS') );
Warning: gscan2pdf expects one image per page, but this was not satisfied. It is probable that the PDF has not been correctly imported.

If you wish to add scans to an existing PDF, use the prepend/append to PDF options in the Save dialogue.
EOS
        }
    }
    return;
}

# return if the given PDF::Builder font can encode the given character

sub font_can_char {
    my ( $font, $char ) = @_;
    return $font->glyphByUni( ord $char ) ne '.notdef';
}

sub _thread_save_pdf {
    my ( $self, %options ) = @_;

    my $pagenr = 0;
    my ( $cache, $pdf, $error, $message );

    # Create PDF with PDF::Builder
    $self->{message} = __('Setting up PDF');
    my $filename = $options{path};
    if ( _need_temp_pdf(%options) ) {
        $filename = File::Temp->new( DIR => $options{dir}, SUFFIX => '.pdf' );
    }
    try {
        $pdf = PDF::Builder->new( -file => $filename );
    }
    catch {
        $logger->error("Caught error creating PDF $filename: $_");
        _thread_throw_error(
            $self, $options{uuid}, $options{page}{uuid},
            'Save file', sprintf __('Caught error creating PDF %s: %s'),
            $filename,   $_
        );
        $error = TRUE;
    };
    if ($error) { return 1 }

    if ( defined $options{metadata} and not defined $options{options}{ps} ) {
        my $metadata = prepare_output_metadata( 'PDF', $options{metadata} );
        $pdf->info( %{$metadata} );
    }

    $cache->{core} = $pdf->corefont('Times-Roman');
    if ( defined $options{options}{font} ) {
        $message =
          sprintf __("Unable to find font '%s'. Defaulting to core font."),
          $options{options}{font};
        if ( -f $options{options}{font} ) {
            try {
                $cache->{ttf} =
                  $pdf->ttfont( $options{options}{font}, -unicodemap => 1 );
                $logger->info(
                    "Using $options{options}{font} for non-ASCII text");
            }
            catch {
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file', $message )
            }
        }
        else {
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file', $message );
        }
    }

    for my $pagedata ( @{ $options{list_of_pages} } ) {
        ++$pagenr;
        $self->{progress} = $pagenr / ( $#{ $options{list_of_pages} } + 2 );
        $self->{message}  = sprintf __('Saving page %i of %i'),
          $pagenr, $#{ $options{list_of_pages} } + 1;
        my $status =
          _add_page_to_pdf( $self, $pdf, $pagedata, $cache, %options );
        return if ( $status or $_self->{cancel} );
    }

    $self->{message} = __('Closing PDF');
    $logger->info('Closing PDF');
    $pdf->save;
    $pdf->end;

    if (   defined $options{options}{prepend}
        or defined $options{options}{append} )
    {
        return if _append_pdf( $self, $filename, %options );
    }

    if ( defined $options{options}{'user-password'} ) {
        return if _encrypt_pdf( $self, $filename, %options );
    }

    _set_timestamp( $self, %options );

    if ( defined $options{options}{ps} ) {
        $self->{message} = __('Converting to PS');

        my @cmd =
          ( $options{options}{pstool}, $filename, $options{options}{ps} );
        ( my $status, undef, $error ) =
          exec_command( \@cmd, $options{pidfile} );
        if ( $status or $error ) {
            $logger->info($error);
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file',
                sprintf __('Error converting PDF to PS: %s'), $error );
            return;
        }
        _post_save_hook( $options{options}{ps}, %{ $options{options} } );
    }
    else {
        _post_save_hook( $filename, %{ $options{options} } );
    }

    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'save-pdf',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _need_temp_pdf {
    my (%options) = @_;
    return (
             defined $options{options}{prepend}
          or defined $options{options}{append}
          or defined $options{options}{ps}
          or defined $options{options}{'user-password'}
    );
}

sub _append_pdf {
    my ( $self, $filename, %options ) = @_;
    my ( $bak, $file1, $file2, $out, $message );
    if ( defined $options{options}{prepend} ) {
        $file1   = $filename;
        $file2   = "$options{options}{prepend}.bak";
        $bak     = $file2;
        $out     = $options{options}{prepend};
        $message = __('Error prepending PDF: %s');
        $logger->info('Prepending PDF');
    }
    else {
        $file2   = $filename;
        $file1   = "$options{options}{append}.bak";
        $bak     = $file1;
        $out     = $options{options}{append};
        $message = __('Error appending PDF: %s');
        $logger->info('Appending PDF');
    }

    if ( not move( $out, $bak ) ) {
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', __('Error creating backup of PDF') );
        return;
    }

    my ( $status, undef, $error ) =
      exec_command( [ 'pdfunite', $file1, $file2, $out ], $options{pidfile} );
    if ($status) {
        $logger->info($error);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', sprintf $message, $error );
        return $status;
    }
}

sub _encrypt_pdf {
    my ( $self, $filename, %options ) = @_;
    my @cmd = ( 'pdftk', $filename, 'output', $options{path} );
    if ( defined $options{options}{'user-password'} ) {
        push @cmd, 'user_pw', $options{options}{'user-password'};
    }
    ( my $status, undef, my $error ) =
      exec_command( \@cmd, $options{pidfile} );
    if ( $status or $error ) {
        $logger->info($error);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', sprintf __('Error encrypting PDF: %s'), $error );
        return $status;
    }
}

sub _set_timestamp {
    my ( $self, %options ) = @_;

    if (   not defined $options{options}{set_timestamp}
        or not $options{options}{set_timestamp}
        or defined $options{options}{ps} )
    {
        return;
    }

    my @datetime = @{ $options{metadata}{datetime} };
    if ( defined $options{metadata}{tz} ) {
        my @tz = @{ $options{metadata}{tz} };
        splice @tz, 0, 2;
        splice @tz, $LAST_ELEMENT, 1;
        for (@tz) {
            if ( not defined ) {
                $_ = 0;
            }
            else {
                $_ = -$_;
            }
        }
        @datetime = Add_Delta_DHMS( @datetime, @tz );
    }
    try {
        my $time = Date_to_Time(@datetime);
        utime $time, $time, $options{path};
    }
    catch {
        $logger->error('Unable to set file timestamp for dates prior to 1970');
        _thread_throw_error(
            $self, $options{uuid}, undef,
            'Set timestamp',
            __('Unable to set file timestamp for dates prior to 1970')
        );
    };
    return;
}

sub _add_page_to_pdf {
    my ( $self, $pdf, $pagedata, $cache, %options ) = @_;
    my $filename = $pagedata->{filename};
    my $image    = Image::Magick->new;
    my $status   = $image->Read($filename);
    return if $_self->{cancel};
    if ("$status") { $logger->warn($status) }

    # Get the size and resolution. Resolution is pixels per inch, width
    # and height are in pixels.
    my ( $width, $height ) = $pagedata->get_size;
    my ( $xres,  $yres )   = $pagedata->get_resolution;
    my $w = $width / $xres * $POINTS_PER_INCH;
    my $h = $height / $yres * $POINTS_PER_INCH;

    # Automatic mode
    my $type;
    if ( not defined $options{options}{compression}
        or $options{options}{compression} eq 'auto' )
    {
        $pagedata->{depth} = $image->Get('depth');
        $logger->info("Depth of $filename is $pagedata->{depth}");
        if ( $pagedata->{depth} == 1 ) {
            $pagedata->{compression} = 'png';
        }
        else {
            $type = $image->Get('type');
            $logger->info("Type of $filename is $type");
            if ( $type =~ /TrueColor/xsm ) {
                $pagedata->{compression} = 'jpg';
            }
            else {
                $pagedata->{compression} = 'png';
            }
        }
        $logger->info("Selecting $pagedata->{compression} compression");
    }
    else {
        $pagedata->{compression} = $options{options}{compression};
    }

    my ( $format, $output_resolution, $error );
    try {
        ( $filename, $format, $output_resolution ) =
          _convert_image_for_pdf( $self, $pagedata, $image, %options );
    }
    catch {
        $logger->error("Caught error converting image: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', "Caught error converting image: $_." );
        $error = TRUE;
    };
    if ($error) { return 1 }

    my $page = $pdf->page;
    if ( defined $options{options}{text_position}
        and $options{options}{text_position} eq 'right' )
    {
        $logger->info('Embedding OCR output right of image');
        $logger->info( 'Defining page at ', $w * 2, " pt x $h pt" );
        $page->mediabox( $w * 2, $h );
    }
    else {
        $logger->info('Embedding OCR output behind image');
        $logger->info("Defining page at $w pt x $h pt");
        $page->mediabox( $w, $h );
    }

    if ( defined( $pagedata->{bboxtree} ) ) {
        _add_text_to_pdf( $self, $page, $pagedata, $cache, %options );
    }

    # Add scan
    my $gfx = $page->gfx;
    my ( $imgobj, $msg );
    try {
        given ($format) {
            when ('png') {
                $imgobj = $pdf->image_png($filename);
            }
            when ('jpg') {
                $imgobj = $pdf->image_jpeg($filename);
            }
            when (/^p[bn]m$/xsm) {
                $imgobj = $pdf->image_pnm($filename);
            }
            when ('gif') {
                $imgobj = $pdf->image_gif($filename);
            }
            when ('tif') {
                $imgobj = $pdf->image_tiff($filename);
            }
            default {
                $msg = "Unknown format $format file $filename";
            }
        }
    }
    catch { $msg = $_ };
    return if $_self->{cancel};
    if ($msg) {
        $logger->warn($msg);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file',
            sprintf __('Error creating PDF image object: %s'), $msg );
        return 1;
    }

    try {
        $gfx->image( $imgobj, 0, 0, $w, $h );
    }
    catch {
        $logger->warn($_);
        _thread_throw_error(
            $self, $options{uuid}, $options{page}{uuid},
            'Save file',
            sprintf __('Error embedding file image in %s format to PDF: %s'),
            $format, $_
        );
        $error = TRUE;
    };
    if ($error) { return 1 }

    $logger->info("Added $filename at $output_resolution PPI");
    return;
}

# Convert file if necessary

sub _convert_image_for_pdf {
    my ( $self, $pagedata, $image, %options ) = @_;
    my $filename    = $pagedata->{filename};
    my $compression = $pagedata->{compression};

    my $format;
    if ( $filename =~ /[.](\w*)$/xsm ) {
        $format = $1;
    }

    # The output resolution is normally the same as the input
    # resolution.
    my $output_xresolution = $pagedata->{xresolution};
    my $output_yresolution = $pagedata->{yresolution};

    if (
        _must_convert_image_for_pdf(
            $compression, $format, $options{options}{downsample}
        )
      )
    {
        if (   ( $compression !~ /(?:jpg|png)/xsm and $format ne 'tif' )
            or ( $compression =~ /g[34]/xsm and $image->Get('depth') > 1 ) )
        {
            my $ofn = $filename;
            $filename =
              File::Temp->new( DIR => $options{dir}, SUFFIX => '.tif' );
            $logger->info("Converting $ofn to $filename");
        }
        elsif ( $compression =~ /(?:jpg|png)/xsm ) {
            my $ofn = $filename;
            $filename = File::Temp->new(
                DIR    => $options{dir},
                SUFFIX => ".$compression"
            );
            my $msg = "Converting $ofn to $filename";
            if ( defined $options{options}{quality}
                and $compression eq 'jpg' )
            {
                $msg .= " with quality=$options{options}{quality}";
            }
            $logger->info($msg);
        }

        if ( $options{options}{downsample} ) {
            $output_xresolution = $options{options}{'downsample dpi'};
            $output_yresolution = $options{options}{'downsample dpi'};
            my $w_pixels =
              $pagedata->{width} *
              $output_xresolution /
              $pagedata->{xresolution};
            my $h_pixels =
              $pagedata->{height} *
              $output_yresolution /
              $pagedata->{yresolution};

            $logger->info("Resizing $filename to $w_pixels x $h_pixels");
            my $status =
              $image->Sample( width => $w_pixels, height => $h_pixels );
            if ("$status") { $logger->warn($status) }
        }
        if ( defined $options{options}{quality} and $compression eq 'jpg' ) {
            my $status = $image->Set( quality => $options{options}{quality} );
            if ("$status") { $logger->warn($status) }
        }

        $format =
          _write_image_object( $image, $filename, $format, $pagedata,
            $options{options}{downsample} );

        if ( $compression !~ /(?:jpg|png)/xsm ) {
            my $filename2 =
              File::Temp->new( DIR => $options{dir}, SUFFIX => '.tif' );
            my $error =
              File::Temp->new( DIR => $options{dir}, SUFFIX => '.txt' );
            ( my $status, undef, $error ) = exec_command(
                [ 'tiffcp', '-c', $compression, $filename, $filename2 ],
                $options{pidfile} );
            return if $_self->{cancel};
            if ($status) {
                $logger->info($error);
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file',
                    sprintf __('Error compressing image: %s'), $error );
                return;
            }
            $filename = $filename2;
        }
    }
    return $filename, $format, $output_xresolution, $output_yresolution;
}

sub _must_convert_image_for_pdf {
    my ( $compression, $format, $downsample ) = @_;
    return (
             ( $compression ne 'none' and $compression ne $format )
          or $downsample
          or $compression eq 'jpg'
    );
}

sub _write_image_object {
    my ( $image, $filename, $format, $pagedata, $downsample ) = @_;
    my $compression = $pagedata->{compression};
    if (   ( $compression !~ /(?:jpg|png)/xsm and $format ne 'tif' )
        or ( $compression =~ /(?:jpg|png)/xsm )
        or $downsample
        or ( $compression =~ /g[34]/xsm and $image->Get('depth') > 1 ) )
    {
        $logger->info("Writing temporary image $filename");

        # Perlmagick doesn't reliably convert to 1-bit, so using convert
        if ( $compression =~ /g[34]/xsm ) {
            my @cmd = (
                'convert', $image->Get('filename'),
                '-threshold', '40%', '-depth', '1', $filename,
            );
            my ($status) = exec_command( \@cmd );
            return 'tif';
        }

        # Reset depth because of ImageMagick bug
        # <https://github.com/ImageMagick/ImageMagick/issues/277>
        $image->Set( 'depth', $image->Get('depth') );
        my $status = $image->Write( filename => $filename );
        return if $_self->{cancel};
        if ("$status")                     { $logger->warn($status) }
        if ( $filename =~ /[.](\w*)$/xsm ) { $format = $1 }
    }
    return $format;
}

# Add OCR as text behind the scan

sub _add_text_to_pdf {
    my ( $self, $pdf_page, $gs_page, $cache, %options ) = @_;
    my $xresolution = $gs_page->{xresolution};
    my $yresolution = $gs_page->{yresolution};
    my $w           = $gs_page->{width} / $gs_page->{xresolution};
    my $h           = $gs_page->{height} / $gs_page->{yresolution};
    my $font;
    my $offset = 0;
    if ( defined $options{options}{text_position}
        and $options{options}{text_position} eq 'right' )
    {
        $offset = $w * $POINTS_PER_INCH;
    }
    my $text = $pdf_page->text;
    my $iter =
      Gscan2pdf::Bboxtree->new( $gs_page->{bboxtree} )->get_bbox_iter();

    while ( my $box = $iter->() ) {
        my ( $x1, $y1, $x2, $y2 ) = @{ $box->{bbox} };
        my $txt = $box->{text};
        if ( not defined $txt ) { next }
        if ( $txt =~ /([[:^ascii:]]+)/xsm ) {
            if ( not font_can_char( $cache->{core}, $1 ) ) {
                if ( not defined $cache->{ttf} ) {
                    my $message = sprintf __(
"Core font '%s' cannot encode character '%s', and no TTF font defined."
                    ), $cache->{core}->fontname, $1;
                    $logger->error( encode( 'UTF-8', $message ) );
                    _thread_throw_error( $self, $options{uuid},
                        $options{page}{uuid},
                        'Save file', $message );
                }
                elsif ( font_can_char( $cache->{ttf}, $1 ) ) {
                    $logger->debug(
                        encode( 'UTF-8', "Using TTF for '$1' in '$txt'" ) );
                    $font = $cache->{ttf};
                }
                else {
                    my $message = sprintf __(
"Neither '%s' nor '%s' can encode character '%s' in '%s'"
                      ), $cache->{core}->fontname, $cache->{ttf}->fontname, $1,
                      $txt;
                    $logger->error( encode( 'UTF-8', $message ) );
                    _thread_throw_error( $self, $options{uuid},
                        $options{page}{uuid},
                        'Save file', $message );
                }
            }
        }
        if ( not defined $font ) { $font = $cache->{core} }
        if ( $x1 == 0 and $y1 == 0 and not defined $x2 ) {
            ( $x2, $y2 ) = ( $w * $xresolution, $h * $yresolution );
        }
        if (    abs( $h * $yresolution - $y2 + $y1 ) > $BOX_TOLERANCE
            and abs( $w * $xresolution - $x2 + $x1 ) > $BOX_TOLERANCE )
        {

            # Box is smaller than the page. We know the text position.
            # Set the text position.
            # Translate x1 and y1 to inches and then to points. Invert the
            # y coordinate (since the PDF coordinates are bottom to top
            # instead of top to bottom) and subtract $size, since the text
            # will end up above the given point instead of below.
            my $size = ( $y2 - $y1 ) / $yresolution * $POINTS_PER_INCH;
            $text->font( $font, $size );
            $text->translate(
                $offset + $x1 / $xresolution * $POINTS_PER_INCH,
                ( $h - ( $y1 / $yresolution ) ) * $POINTS_PER_INCH - $size
            );
            $text->text( $txt, utf8 => 1 );
        }
        else {
            my $size = 1;
            $text->font( $font, $size );
            _wrap_text_to_page( $txt, $size, $text, $h, $w );
        }
    }
    return;
}

# Box is the same size as the page. We don't know the text position.
# Start at the top of the page (PDF coordinate system starts
# at the bottom left of the page)

sub _wrap_text_to_page {
    my ( $txt, $size, $text_box, $h, $w ) = @_;
    my $y = $h * $POINTS_PER_INCH - $size;
    for my $line ( split /\n/xsm, $txt ) {
        my $x = 0;

        # Add a word at a time in order to linewrap
        for my $word ( split $SPACE, $line ) {
            if ( length($word) * $size + $x > $w * $POINTS_PER_INCH ) {
                $x = 0;
                $y -= $size;
            }
            $text_box->translate( $x, $y );
            if ( $x > 0 ) { $word = $SPACE . $word }
            $x += $text_box->text( $word, utf8 => 1 );
        }
        $y -= $size;
    }
    return;
}

sub _post_save_hook {
    my ( $filename, %options ) = @_;
    if ( defined $options{post_save_hook} ) {
        my $command = $options{post_save_hook};

        # a filename returned by Gtk3::FileChooserDialog containing utf8 is
        # not marked as utf8. This is then mangled by the string operations
        # below, but not for the operations than come afterwards, so just
        # turning on utf8 for the append.
        # Annoyingly, I have been unable to construct a test case to reproduce
        # the problem.
        _utf8_on($filename);
        $command =~ s/%i/"$filename"/gxsm;
        if ( not defined $options{post_save_hook_options}
            or $options{post_save_hook_options} ne 'fg' )
        {
            $command .= ' &';
        }
        _utf8_off($filename);
        $logger->info($command);
        system $command;
    }
    return;
}

sub _thread_save_djvu {
    my ( $self, %options ) = @_;

    my $page = 0;
    my @filelist;

    for my $pagedata ( @{ $options{list_of_pages} } ) {
        ++$page;
        $self->{progress} = $page / ( $#{ $options{list_of_pages} } + 2 );
        $self->{message}  = sprintf __('Writing page %i of %i'),
          $page, $#{ $options{list_of_pages} } + 1;

        my ( $djvu, $error );
        try {
            $djvu = File::Temp->new( DIR => $options{dir}, SUFFIX => '.djvu' );
        }
        catch {
            $logger->error("Caught error writing DjVu: $_");
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file', "Caught error writing DjVu: $_." );
            $error = TRUE;
        };
        if ($error) { return }

        my ( $compression, $filename, $resolution ) =
          _convert_image_for_djvu( $self, $pagedata, $page, %options );

        # Create the djvu
        my ($status) = exec_command(
            [ $compression, '-dpi', int($resolution), $filename, $djvu ],
            $options{pidfile} );
        my $size =
          -s "$djvu"; # quotes needed to prevent -s clobbering File::Temp object
        return if $_self->{cancel};
        if ( $status != 0 or not $size ) {
            $logger->error(
"Error writing image for page $page of DjVu (process returned $status, image size $size)"
            );
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file', __('Error writing DjVu') );
            return;
        }
        push @filelist, $djvu;
        _add_text_to_djvu( $self, $djvu, $options{dir}, $pagedata,
            $options{uuid} );
    }
    $self->{progress} = 1;
    $self->{message}  = __('Merging DjVu');
    my ( $status, $out, $err ) =
      exec_command( [ 'djvm', '-c', $options{path}, @filelist ],
        $options{pidfile} );
    return if $_self->{cancel};
    if ($status) {
        $logger->error('Error merging DjVu');
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', __('Error merging DjVu') );
    }
    _add_metadata_to_djvu( $self, %options );

    _set_timestamp( $self, %options );

    _post_save_hook( $options{path}, %{ $options{options} } );

    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'save-djvu',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _convert_image_for_djvu {
    my ( $self, $pagedata, $page, %options ) = @_;
    my $filename = $pagedata->{filename};

    # Check the image depth to decide what sort of compression to use
    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', "Error reading $filename: $e." );
        return;
    }
    my $depth = $image->Get('depth');
    my $class = $image->Get('class');
    my ( $compression, $resolution, $upsample );

    # Get the size
    $pagedata->{w}           = $image->Get('width');
    $pagedata->{h}           = $image->Get('height');
    $pagedata->{pidfile}     = $options{pidfile};
    $pagedata->{page_number} = $page;

    # c44 and cjb2 do not support different resolutions in the x and y
    # directions, so resample
    if ( $pagedata->{xresolution} != $pagedata->{yresolution} ) {
        $resolution =
            $pagedata->{xresolution} > $pagedata->{yresolution}
          ? $pagedata->{xresolution}
          : $pagedata->{yresolution};
        $pagedata->{w} *= $resolution / $pagedata->{xresolution};
        $pagedata->{h} *= $resolution / $pagedata->{yresolution};
        $logger->info( "Upsampling to $resolution" . "x$resolution" );
        $image->Sample( width => $pagedata->{w}, height => $pagedata->{h} );
        $upsample = TRUE;
    }
    else {
        $resolution = $pagedata->{xresolution};
    }

    # c44 can only use pnm and jpg
    my $format;
    if ( $filename =~ /[.](\w*)$/xsm ) {
        $format = $1;
    }
    if ( $depth > 1 ) {
        $compression = 'c44';
        if ( $format !~ /(?:pnm|jpg)/xsm or $upsample ) {
            my $pnm = File::Temp->new( DIR => $options{dir}, SUFFIX => '.pnm' );
            $e = $image->Write( filename => $pnm );
            if ("$e") {
                $logger->error($e);
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file', "Error writing $pnm: $e." );
                return;
            }
            $filename = $pnm;
        }
    }

    # cjb2 can only use pnm and tif
    else {
        $compression = 'cjb2';
        if (   $format !~ /(?:pnm|tif)/xsm
            or ( $format eq 'pnm' and $class ne 'PseudoClass' )
            or $upsample )
        {
            my $pbm = File::Temp->new( DIR => $options{dir}, SUFFIX => '.pbm' );
            $e = $image->Write( filename => $pbm );
            if ("$e") {
                $logger->error($e);
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file', "Error writing $pbm: $e." );
                return;
            }
            $filename = $pbm;
        }
    }

    return $compression, $filename, $resolution;
}

sub _write_file {
    my ( $self, $fh, $filename, $data, $uuid ) = @_;
    if ( not print {$fh} $data ) {
        _thread_throw_error( $self, $uuid, undef, 'Save file',
            sprintf __("Can't write to file: %s"), $filename );
        return FALSE;
    }
    return TRUE;
}

# Add OCR to text layer

sub _add_text_to_djvu {
    my ( $self, $djvu, $dir, $pagedata, $uuid ) = @_;
    if ( defined( $pagedata->{bboxtree} ) ) {
        my $txt = $pagedata->export_djvutext;
        if ( $txt eq $EMPTY ) { return }

        # Write djvusedtxtfile
        my $djvusedtxtfile = File::Temp->new( DIR => $dir, SUFFIX => '.txt' );
        $logger->debug($txt);
        open my $fh, '>:encoding(UTF8)', $djvusedtxtfile
          or croak( sprintf __("Can't open file: %s"), $djvusedtxtfile );
        _write_file( $self, $fh, $djvusedtxtfile, $txt, $uuid )
          or return;
        close $fh
          or croak( sprintf __("Can't close file: %s"), $djvusedtxtfile );

        # Run djvusedtxtfile
        my @cmd =
          ( 'djvused', $djvu, '-e', "select 1; set-txt $djvusedtxtfile", '-s' );
        my ($status) = exec_command( \@cmd, $pagedata->{pidfile} );
        return if $_self->{cancel};
        if ($status) {
            $logger->error(
                "Error adding text layer to DjVu page $pagedata->{page_number}"
            );
            _thread_throw_error( $self, $uuid, $pagedata->{uuid},
                'Save file', __('Error adding text layer to DjVu') );
        }
    }
    return;
}

sub _add_metadata_to_djvu {
    my ( $self, %options ) = @_;
    if ( $options{metadata} and %{ $options{metadata} } ) {

        # Open djvusedmetafile
        my $djvusedmetafile =
          File::Temp->new( DIR => $options{dir}, SUFFIX => '.txt' );
        open my $fh, '>:encoding(UTF8)',    ## no critic (RequireBriefOpen)
          $djvusedmetafile
          or croak( sprintf __("Can't open file: %s"), $djvusedmetafile );
        _write_file( $self, $fh, $djvusedmetafile, "(metadata\n",
            $options{uuid} )
          or return;

        # Write the metadata
        my $metadata = prepare_output_metadata( 'DjVu', $options{metadata} );
        for my $key ( keys %{$metadata} ) {
            my $val = $metadata->{$key};

            # backslash-escape any double quotes and bashslashes
            $val =~ s/\\/\\\\/gxsm;
            $val =~ s/"/\\\"/gxsm;
            _write_file( $self, $fh, $djvusedmetafile, "$key \"$val\"\n",
                $options{uuid} )
              or return;
        }
        _write_file( $self, $fh, $djvusedmetafile, ')', $options{uuid} )
          or return;
        close $fh
          or croak( sprintf __("Can't close file: %s"), $djvusedmetafile );

        # Write djvusedmetafile
        my @cmd = (
            'djvused', $options{path}, '-e', "set-meta $djvusedmetafile", '-s',
        );
        my ($status) = exec_command( \@cmd, $options{pidfile} );
        return if $_self->{cancel};
        if ($status) {
            $logger->error('Error adding metadata info to DjVu file');
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file', __('Error adding metadata to DjVu') );
        }
    }
    return;
}

sub _thread_save_tiff {
    my ( $self, %options ) = @_;

    my $page = 0;
    my @filelist;

    for my $pagedata ( @{ $options{list_of_pages} } ) {
        ++$page;
        $self->{progress} =
          ( $page - 1 ) / ( $#{ $options{list_of_pages} } + 2 );
        $self->{message} =
          sprintf __('Converting image %i of %i to TIFF'),
          $page, $#{ $options{list_of_pages} } + 1;

        my $filename = $pagedata->{filename};
        if (
            $filename !~ /[.]tif/xsm
            or ( defined $options{options}{compression}
                and $options{options}{compression} eq 'jpeg' )
          )
        {
            my ( $tif, $error );
            try {
                $tif =
                  File::Temp->new( DIR => $options{dir}, SUFFIX => '.tif' );
            }
            catch {
                $logger->error("Error writing TIFF: $_");
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file', "Error writing TIFF: $_." );
                $error = TRUE;
            };
            if ($error) { return }
            my $xresolution = $pagedata->{xresolution};
            my $yresolution = $pagedata->{yresolution};

            # Convert to tiff
            my @depth;
            if ( defined $options{options}{compression} ) {
                if ( $options{options}{compression} eq 'jpeg' ) {
                    @depth = qw(-depth 8);
                }
                elsif ( $options{options}{compression} =~ /g[34]/xsm ) {
                    @depth = qw(-threshold 40% -depth 1);
                }
            }

            my @cmd = (
                'convert', $filename, '-units', 'PixelsPerInch', '-density',
                $xresolution . 'x' . $yresolution,
                @depth, $tif,
            );
            my ($status) = exec_command( \@cmd, $options{pidfile} );
            return if $_self->{cancel};

            if ($status) {
                $logger->error('Error writing TIFF');
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file', __('Error writing TIFF') );
                return;
            }
            $filename = $tif;
        }
        push @filelist, $filename;
    }

    my @compression;
    if ( defined $options{options}{compression} ) {
        @compression = ( '-c', "$options{options}{compression}" );
        if ( $options{options}{compression} eq 'jpeg' ) {
            $compression[1] .= ":$options{options}{quality}";
            push @compression, qw(-r 16);
        }
    }

    # Create the tiff
    $self->{progress} = 1;
    $self->{message}  = __('Concatenating TIFFs');
    my @cmd = ( 'tiffcp', @compression, @filelist, $options{path} );
    my ( $status, undef, $error ) = exec_command( \@cmd, $options{pidfile} );
    return if $_self->{cancel};

    if ( $status or $error ne $EMPTY ) {
        $logger->info($error);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Save file', sprintf __('Error compressing image: %s'), $error );
        return;
    }
    if ( defined $options{options}{ps} ) {
        $self->{message} = __('Converting to PS');
        @cmd = ( 'tiff2ps', '-3', $options{path}, '-O', $options{options}{ps} );
        ( $status, undef, $error ) = exec_command( \@cmd, $options{pidfile} );
        if ( $status or $error ) {
            $logger->info($error);
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file',
                sprintf __('Error converting TIFF to PS: %s'), $error );
            return;
        }
        _post_save_hook( $options{options}{ps}, %{ $options{options} } );
    }
    else {
        _post_save_hook( $options{path}, %{ $options{options} } );
    }

    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'save-tiff',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_no_filename {
    my ( $self, $process, $uuid, $page ) = @_;
    if ( not defined $page->{filename} )
    {    # in case file was deleted after process started
        my $e = "Page for process $uuid no longer exists. Cannot $process.";
        $logger->error($e);
        _thread_throw_error( $self, $uuid, $page->{uuid}, $process, $e );
        return TRUE;
    }
    return;
}

sub _thread_rotate {
    my ( $self, $angle, $page, $dir, $uuid ) = @_;
    if ( _thread_no_filename( $self, 'rotate', $uuid, $page ) ) { return }
    my $filename = $page->{filename};
    $logger->info("Rotating $filename by $angle degrees");

    # Rotate with imagemagick
    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }

    # workaround for those versions of imagemagick that produce 16bit output
    # with rotate
    my $depth = $image->Get('depth');
    $e = $image->Rotate($angle);
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'Rotate', $e );
        return;
    }
    return if $_self->{cancel};
    my ( $suffix, $error );
    if ( $filename =~ /[.](\w*)$/xsm ) {
        $suffix = $1;
    }
    try {
        $filename = File::Temp->new(
            DIR    => $dir,
            SUFFIX => ".$suffix",
            UNLINK => FALSE
        );
        $e = $image->Write( filename => $filename, depth => $depth );
    }
    catch {
        $logger->error("Error rotating: $_");
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'Rotate', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }
    $page->{filename}   = $filename->filename;
    $page->{dirty_time} = timestamp();           #flag as dirty
    if ( $angle == $_90_DEGREES or $angle == $_270_DEGREES ) {
        ( $page->{width}, $page->{height} ) =
          ( $page->{height}, $page->{width} );
        ( $page->{xresolution}, $page->{yresolution} ) =
          ( $page->{yresolution}, $page->{xresolution} );
    }
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $uuid,
            page => $page,
            info => { replace => $page->{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'rotate',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_save_image {
    my ( $self, %options ) = @_;

    if ( @{ $options{list_of_pages} } == 1 ) {
        my $status = exec_command(
            [
                'convert',
                $options{list_of_pages}->[0]{filename},
                '-density',
                $options{list_of_pages}->[0]{xresolution} . 'x'
                  . $options{list_of_pages}->[0]{yresolution},
                $options{path}
            ],
            $options{pidfile}
        );
        return if $_self->{cancel};
        if ($status) {
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'Save file', __('Error saving image') );
        }
        _post_save_hook( $options{list_of_pages}->[0]{filename},
            %{ $options{options} } );
    }
    else {
        my $current_filename;
        my $i = 1;
        for ( @{ $options{list_of_pages} } ) {
            $current_filename = sprintf $options{path}, $i++;
            my $status = exec_command(
                [
                    'convert',  $_->{filename},
                    '-density', $_->{xresolution} . 'x' . $_->{yresolution},
                    $current_filename
                ],
                $options{pidfile}
            );
            return if $_self->{cancel};
            if ($status) {
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'Save file', __('Error saving image') );
            }
            _post_save_hook( $_->{filename}, %{ $options{options} } );
        }
    }
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'save-image',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_save_text {
    my ( $self, $path, $list_of_pages, $options, $uuid ) = @_;
    my $fh;
    my $string = $EMPTY;

    for my $page ( @{$list_of_pages} ) {
        $string .= $page->export_text;
        return if $_self->{cancel};
    }
    if ( not open $fh, '>', $path ) {
        _thread_throw_error( $self, $uuid, undef, 'Save file',
            sprintf __("Can't open file: %s"), $path );
        return;
    }
    _write_file( $self, $fh, $path, $string, $uuid ) or return;
    if ( not close $fh ) {
        _thread_throw_error( $self, $uuid, undef, 'Save file',
            sprintf __("Can't close file: %s"), $path );
    }
    _post_save_hook( $path, %{$options} );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'save-text',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_save_hocr {
    my ( $self, $path, $list_of_pages, $options, $uuid ) = @_;
    my $fh;

    if ( not open $fh, '>', $path ) {    ## no critic (RequireBriefOpen)
        _thread_throw_error( $self, $uuid, undef, 'Save file',
            sprintf __("Can't open file: %s"), $path );
        return;
    }

    my $written_header = FALSE;
    for ( @{$list_of_pages} ) {
        my $hocr = $_->export_hocr;
        if ( defined $hocr and $hocr =~ /([\s\S]*<body>)([\s\S]*)<\/body>/xsm )
        {
            my $header    = $1;
            my $hocr_page = $2;
            if ( not $written_header ) {
                _write_file( $self, $fh, $path, $header, $uuid ) or return;
                $written_header = TRUE;
            }
            _write_file( $self, $fh, $path, $hocr_page, $uuid ) or return;
            return if $_self->{cancel};
        }
    }
    if ($written_header) {
        _write_file( $self, $fh, $path, "</body>\n</html>\n", $uuid ) or return;
    }

    if ( not close $fh ) {
        _thread_throw_error( $self, $uuid, undef, 'Save file',
            sprintf __("Can't close file: %s"), $path );
    }
    _post_save_hook( $path, %{$options} );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'save-hocr',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_analyse {
    my ( $self, $list_of_pages, $uuid ) = @_;

    my $i     = 1;
    my $total = @{$list_of_pages};
    for my $page ( @{$list_of_pages} ) {
        $self->{progress} = ( $i - 1 ) / $total;
        $self->{message}  = sprintf __('Analysing page %i of %i'), $i++, $total;

        # Identify with imagemagick
        my $image = Image::Magick->new;
        my $e     = $image->Read( $page->{filename} );
        if ("$e") {
            $logger->error($e);
            _thread_throw_error( $self, $uuid, $page->{uuid}, 'Analyse',
                "Error reading $page->{filename}: $e." );
            return;
        }
        return if $_self->{cancel};

        my ( $depth, $min, $max, $mean, $stddev ) = $image->Statistics();
        if ( not defined $depth ) {
            $logger->warn('image->Statistics() failed');
        }
        $logger->info("std dev: $stddev mean: $mean");
        return if $_self->{cancel};
        my $maxq = ( 1 << $depth ) - 1;
        $mean = $maxq ? $mean / $maxq : 0;
        if ( $stddev =~ /^[-]nan$/xsm ) { $stddev = 0 }

# my $quantum_depth = $image->QuantumDepth;
# warn "image->QuantumDepth failed" unless defined $quantum_depth;
# TODO add any other useful image analysis here e.g. is the page mis-oriented?
#  detect mis-orientation possible algorithm:
#   blur or low-pass filter the image (so words look like ovals)
#   look at few vertical narrow slices of the image and get the Standard Deviation
#   if most of the Std Dev are high, then it might be portrait
# TODO may need to send quantumdepth

        $page->{mean}         = $mean;
        $page->{std_dev}      = $stddev;
        $page->{analyse_time} = timestamp();
        $self->{return}->enqueue(
            {
                type => 'page',
                uuid => $uuid,
                page => $page,
                info => { replace => $page->{uuid} }
            }
        );
    }
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'analyse',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_threshold {
    my ( $self, $threshold, $page, $dir, $uuid ) = @_;
    if ( _thread_no_filename( $self, 'threshold', $uuid, $page ) ) { return }
    my $filename = $page->{filename};

    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }

    # Using imagemagick, as Perlmagick has performance problems.
    # See https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=968918
    my $out;
    try {
        $out =
          File::Temp->new( DIR => $dir, SUFFIX => '.pbm', UNLINK => FALSE );
    }
    catch {
        $logger->error($_);
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'Threshold', $_ );
        return;
    };
    my @cmd =
      ( 'convert', $filename, '+dither', '-threshold', "$threshold%", $out, );
    my ( $status, $stdout, $stderr ) = exec_command( \@cmd );
    if ( $status != 0 ) {
        $logger->error($stderr);
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'Threshold',
            $stderr );
        return;
    }
    return if $_self->{cancel};

    $page->{filename}   = $out->filename;
    $page->{dirty_time} = timestamp();      #flag as dirty
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $uuid,
            page => $page,
            info => { replace => $page->{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'theshold',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_brightness_contrast {
    my ( $self, %options ) = @_;
    if (
        _thread_no_filename(
            $self, 'brightness-contrast', $options{uuid}, $options{page}
        )
      )
    {
        return;
    }
    my $filename = $options{page}{filename};

    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }

    my $depth = $image->Get('depth');

    # BrightnessContrast the image
    $image->BrightnessContrast(
        brightness => 2 * $options{brightness} - $_100PERCENT,
        contrast   => 2 * $options{contrast} - $_100PERCENT
    );
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Brightness-contrast', $e );
        return;
    }
    return if $_self->{cancel};

    # Write it
    my $error;
    try {
        my $suffix;
        if ( $filename =~ /([.]\w*)$/xsm ) { $suffix = $1 }
        $filename = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => $suffix,
            UNLINK => FALSE
        );
        $e = $image->Write( depth => $depth, filename => $filename );
        if ("$e") { $logger->warn($e) }
    }
    catch {
        $logger->error("Error changing brightness / contrast: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Brightness-contrast', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    return if $_self->{cancel};
    $logger->info(
"Wrote $filename with brightness / contrast changed to $options{brightness} / $options{contrast}"
    );

    $options{page}{filename}   = $filename->filename;
    $options{page}{dirty_time} = timestamp();           #flag as dirty
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'brightness-contrast',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_negate {
    my ( $self, $page, $dir, $uuid ) = @_;
    if ( _thread_no_filename( $self, 'negate', $uuid, $page ) ) { return }
    my $filename = $page->{filename};

    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }

    my $depth = $image->Get('depth');

    # Negate the image
    $e = $image->Negate( channel => 'RGB' );
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'Negate', $e );
        return;
    }
    return if $_self->{cancel};

    # Write it
    my $error;
    try {
        my $suffix;
        if ( $filename =~ /([.]\w*)$/xsm ) { $suffix = $1 }
        $filename =
          File::Temp->new( DIR => $dir, SUFFIX => $suffix, UNLINK => FALSE );
        $e = $image->Write( depth => $depth, filename => $filename );
        if ("$e") { $logger->warn($e) }
    }
    catch {
        $logger->error("Error negating: $_");
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'Negate', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    return if $_self->{cancel};
    $logger->info("Negating to $filename");

    $page->{filename}   = $filename->filename;
    $page->{dirty_time} = timestamp();           #flag as dirty
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $uuid,
            page => $page,
            info => { replace => $page->{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'negate',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_unsharp {
    my ( $self, %options ) = @_;
    if ( _thread_no_filename( $self, 'unsharp', $options{uuid}, $options{page} )
      )
    {
        return;
    }
    my $filename = $options{page}{filename};
    my $version;
    my $image = Image::Magick->new;
    if ( $image->Get('version') =~ /ImageMagick\s([\d.]+)/xsm ) {
        $version = $1;
    }
    $logger->debug("Image::Magick->version $version");
    my $e = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }

    # Unsharp the image
    if ( version->parse("v$version") >= version->parse('v7.0.0') ) {
        $e = $image->UnsharpMask(
            radius    => $options{radius},
            sigma     => $options{sigma},
            gain      => $options{gain},
            threshold => $options{threshold},
        );
    }
    else {
        $e = $image->UnsharpMask(
            radius    => $options{radius},
            sigma     => $options{sigma},
            amount    => $options{gain},
            threshold => $options{threshold},
        );
    }
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Unsharp', $e );
        return;
    }
    return if $_self->{cancel};

    # Write it
    my $error;
    try {
        my $suffix;
        if ( $filename =~ /[.](\w*)$/xsm ) { $suffix = $1 }
        $filename = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => ".$suffix",
            UNLINK => FALSE
        );
        $e = $image->Write( filename => $filename );
        if ("$e") { $logger->warn($e) }
    }
    catch {
        $logger->error("Error writing image with unsharp mask: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'Unsharp', "Error writing image with unsharp mask: $_." );
        $error = TRUE;
    };
    if ($error) { return }
    return if $_self->{cancel};
    $logger->info(
"Wrote $filename with unsharp mask: radius=$options{radius}, sigma=$options{sigma}, gain=$options{gain}, threshold=$options{threshold}"
    );

    $options{page}{filename}   = $filename->filename;
    $options{page}{dirty_time} = timestamp();           #flag as dirty
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'unsharp',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_crop {
    my ( $self, %options ) = @_;
    if ( _thread_no_filename( $self, 'crop', $options{uuid}, $options{page} ) )
    {
        return;
    }
    my $filename = $options{page}{filename};

    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }

    # Crop the image
    $e = $image->Crop(
        width  => $options{w},
        height => $options{h},
        x      => $options{x},
        y      => $options{y}
    );
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'crop', $e );
        return;
    }
    $image->Set( page => '0x0+0+0' );
    return if $_self->{cancel};

    # Write it
    my $error;
    try {
        my $suffix;
        if ( $filename =~ /[.](\w*)$/xsm ) { $suffix = $1 }
        $filename = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => ".$suffix",
            UNLINK => FALSE
        );
        $e = $image->Write( filename => $filename );
        if ("$e") { $logger->warn($e) }
    }
    catch {
        $logger->error("Error cropping: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'crop', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    $logger->info(
"Cropping $options{w} x $options{h} + $options{x} + $options{y} to $filename"
    );
    return if $_self->{cancel};

    $options{page}{filename}   = $filename->filename;
    $options{page}{width}      = $options{w};
    $options{page}{height}     = $options{h};
    $options{page}{dirty_time} = timestamp();           #flag as dirty

    if ( $options{page}{bboxtree} ) {
        my $bboxtree = Gscan2pdf::Bboxtree->new( $options{page}{bboxtree} );
        $options{page}{bboxtree} =
          $bboxtree->crop( $options{x}, $options{y}, $options{w}, $options{h} )
          ->json;
    }

    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'crop',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_split {
    my ( $self, %options ) = @_;
    if ( _thread_no_filename( $self, 'split', $options{uuid}, $options{page} ) )
    {
        return;
    }
    my $filename  = $options{page}{filename};
    my $filename2 = $filename;

    my $image = Image::Magick->new;
    my $e     = $image->Read($filename);
    return if $_self->{cancel};
    if ("$e") { $logger->warn($e) }
    my $image2 = $image->Clone;

    # split the image
    my ( $w, $h, $x2, $y2, $w2, $h2 );
    if ( $options{direction} eq 'v' ) {
        $w  = $options{position};
        $h  = $image->Get('height');
        $x2 = $w;
        $y2 = 0;
        $w2 = $image->Get('width') - $w;
        $h2 = $h;
    }
    else {
        $w  = $image->Get('width');
        $h  = $options{position};
        $x2 = 0;
        $y2 = $h;
        $w2 = $w;
        $h2 = $image->Get('height') - $h;
    }

    $e = $image->Crop( $w . "x$h+0+0" );
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'crop', $e );
        return;
    }
    $image->Set( page => '0x0+0+0' );
    $e = $image2->Crop( $w2 . "x$h2+$x2+$y2" );
    if ("$e") {
        $logger->error($e);
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'crop', $e );
        return;
    }
    $image2->Set( page => '0x0+0+0' );
    return if $_self->{cancel};

    # Write it
    my $error;
    try {
        my $suffix;
        if ( $filename =~ /[.](\w*)$/xsm ) { $suffix = $1 }
        $filename = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => ".$suffix",
            UNLINK => FALSE
        );
        $e = $image->Write( filename => $filename );
        if ("$e") { $logger->warn($e) }
        $filename2 = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => ".$suffix",
            UNLINK => FALSE
        );
        $e = $image2->Write( filename => $filename2 );
        if ("$e") { $logger->warn($e) }
    }
    catch {
        $logger->error("Error cropping: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'crop', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    $logger->info(
"Splitting in direction $options{direction} @ $options{position} -> $filename + $filename2"
    );
    return if $_self->{cancel};

    $options{page}{filename}   = $filename->filename;
    $options{page}{width}      = $image->Get('width');
    $options{page}{height}     = $image->Get('height');
    $options{page}{dirty_time} = timestamp();             #flag as dirty

    my $new2 = Gscan2pdf::Page->new(
        filename => $filename2,
        dir      => $options{dir},
        delete   => TRUE,
        format   => $image2->Get('format'),
    );

    if ( $options{page}{bboxtree} ) {
        my $bboxtree  = Gscan2pdf::Bboxtree->new( $options{page}{bboxtree} );
        my $bboxtree2 = Gscan2pdf::Bboxtree->new( $options{page}{bboxtree} );
        $options{page}{bboxtree} = $bboxtree->crop( 0, 0, $w, $h )->json;
        $new2->{bboxtree} = $bboxtree2->crop( $x2, $y2, $w2, $h2 )->json;
    }

    # crop doesn't change the resolution, so we can safely copy it
    if ( defined $options{page}{xresolution} ) {
        $new2->{xresolution} = $options{page}{xresolution};
        $new2->{yresolution} = $options{page}{yresolution};
    }

    $new2->{dirty_time} = timestamp();    #flag as dirty
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $new2->freeze,
            info => { 'insert-after' => $options{page}{uuid} }
        }
    );

    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );

    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'crop',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_to_png {
    my ( $self, $page, $dir, $uuid ) = @_;
    if ( _thread_no_filename( $self, 'to_png', $uuid, $page ) ) { return }
    my ( $new, $error );
    try {
        $new = $page->to_png($paper_sizes);
        $new->{uuid} = $page->{uuid};
    }
    catch {
        $logger->error("Error converting to png: $_");
        _thread_throw_error( $self, $uuid, $page->{uuid}, 'to-PNG', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    return if $_self->{cancel};
    $logger->info("Converted $page->{filename} to $new->{filename}");
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $uuid,
            page => $new->freeze,
            info => { replace => $page->{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'to-png',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_tesseract {
    my ( $self, %options ) = @_;
    if (
        _thread_no_filename(
            $self, 'tesseract', $options{uuid}, $options{page}
        )
      )
    {
        return;
    }
    my ( $error, $stdout, $stderr );
    try {
        ( $stdout, $stderr ) = Gscan2pdf::Tesseract->hocr(
            file      => $options{page}{filename},
            language  => $options{language},
            logger    => $logger,
            threshold => $options{threshold},
            dpi       => $options{page}{xresolution},
            pidfile   => $options{pidfile},
        );
        $options{page}->import_hocr($stdout);
    }
    catch {
        $logger->error("Error processing with tesseract: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'tesseract', $_ );
        $error = TRUE;
    };
    if ($error) { return }
    return if $_self->{cancel};
    if ( defined $stderr and $stderr ne $EMPTY ) {
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'tesseract', $stderr );
    }
    $options{page}{ocr_flag} = 1;    #FlagOCR
    $options{page}{ocr_time} =
      timestamp();                   #remember when we ran OCR on this page
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'tesseract',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_ocropus {
    my ( $self, %options ) = @_;
    if ( _thread_no_filename( $self, 'ocropus', $options{uuid}, $options{page} )
      )
    {
        return;
    }
    $options{page}->import_hocr(
        Gscan2pdf::Ocropus->hocr(
            file      => $options{page}{filename},
            language  => $options{language},
            logger    => $logger,
            pidfile   => $options{pidfile},
            threshold => $options{threshold}
        )
    );
    return if $_self->{cancel};
    $options{page}{ocr_flag} = 1;    #FlagOCR
    $options{page}{ocr_time} =
      timestamp();                   #remember when we ran OCR on this page
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'ocropus',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_cuneiform {
    my ( $self, %options ) = @_;
    if (
        _thread_no_filename(
            $self, 'cuneiform', $options{uuid}, $options{page}
        )
      )
    {
        return;
    }
    $options{page}->import_hocr(
        Gscan2pdf::Cuneiform->hocr(
            file      => $options{page}{filename},
            language  => $options{language},
            logger    => $logger,
            pidfile   => $options{pidfile},
            threshold => $options{threshold}
        )
    );
    return if $_self->{cancel};
    $options{page}{ocr_flag} = 1;    #FlagOCR
    $options{page}{ocr_time} =
      timestamp();                   #remember when we ran OCR on this page
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $options{uuid},
            page => $options{page},
            info => { replace => $options{page}{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'cuneiform',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_gocr {
    my ( $self, $page, $threshold, $pidfile, $uuid ) = @_;
    if ( _thread_no_filename( $self, 'gocr', $uuid, $page ) ) { return }
    my $pnm;
    if (   ( $page->{filename} !~ /[.]pnm$/xsm )
        or ( defined $threshold and $threshold ) )
    {

        # Temporary filename for new file
        $pnm = File::Temp->new( SUFFIX => '.pnm' );
        my $image = Image::Magick->new;
        $image->Read( $page->{filename} );
        return if $_self->{cancel};

        my $x;
        if ( defined $threshold and $threshold ) {
            $logger->info("thresholding at $threshold to $pnm");
            $image->Threshold( threshold => "$threshold%" );
            return if $_self->{cancel};
            $x = $image->Quantize( colors => 2 );
            return if $_self->{cancel};
            $x = $image->Write( depth => 1, filename => $pnm );
        }
        else {
            $logger->info("writing temporary image $pnm");
            $image->Write( filename => $pnm );
        }
        return if $_self->{cancel};
    }
    else {
        $pnm = $page->{filename};
    }

    # Temporary filename for output
    my $txt = File::Temp->new( SUFFIX => '.txt' );

    # Using temporary txt file, as perl munges charset encoding
    # if text is passed by stdin/stdout
    exec_command( [ 'gocr', $pnm, '-o', $txt ], $pidfile );
    ( my $stdout, undef ) = slurp($txt);
    $page->import_text($stdout);

    return if $_self->{cancel};
    $page->{ocr_flag} = 1;              #FlagOCR
    $page->{ocr_time} = timestamp();    #remember when we ran OCR on this page
    $self->{return}->enqueue(
        {
            type => 'page',
            uuid => $uuid,
            page => $page,
            info => { replace => $page->{uuid} }
        }
    );
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'gocr',
            uuid    => $uuid,
        }
    );
    return;
}

sub _thread_unpaper {
    my ( $self, %options ) = @_;
    if ( _thread_no_filename( $self, 'unpaper', $options{uuid}, $options{page} )
      )
    {
        return;
    }
    my $filename = $options{page}{filename};
    my $in;

    try {
        if ( $filename !~ /[.]pnm$/xsm ) {
            my $image = Image::Magick->new;
            my $e     = $image->Read($filename);
            if ("$e") {
                $logger->error($e);
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'unpaper', "Error reading $filename: $e." );
                return;
            }
            my $depth = $image->Get('depth');

            # Unfortunately, -depth doesn't seem to work here,
            # so forcing depth=1 using pbm extension.
            my $suffix = '.pbm';
            if ( $depth > 1 ) { $suffix = '.pnm' }

            # Temporary filename for new file
            $in = File::Temp->new(
                DIR    => $options{dir},
                SUFFIX => $suffix,
            );

            # FIXME: need to -compress Zip from perlmagick
            # "convert -compress Zip $self->{data}[$pagenum][2]{filename} $in;";
            $logger->debug("Converting $filename -> $in for unpaper");
            $image->Write( filename => $in );
        }
        else {
            $in = $filename;
        }

        my $out = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => '.pnm',
            UNLINK => FALSE
        );
        my $out2 = $EMPTY;
        if ( $options{options}{command} =~ /--output-pages[ ]2[ ]/xsm ) {
            $out2 = File::Temp->new(
                DIR    => $options{dir},
                SUFFIX => '.pnm',
                UNLINK => FALSE
            );
        }

        # --overwrite needed because $out exists with 0 size
        my @cmd = split $SPACE, sprintf "$options{options}{command}", $in,
          $out, $out2;
        ( undef, my $stdout, my $stderr ) =
          exec_command( \@cmd, $options{pidfile} );
        $logger->info($stdout);
        if ($stderr) {
            $logger->error($stderr);
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'unpaper', $stderr );
            if ( not -s $out ) { return }
        }
        return if $_self->{cancel};

        $stdout =~ s/Processing[ ]sheet.*[.]pnm\n//xsm;
        if ($stdout) {
            $logger->warn($stdout);
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'unpaper', $stdout );
            if ( not -s $out ) { return }
        }

        if (    $options{options}{command} =~ /--output-pages[ ]2[ ]/xsm
            and defined $options{options}{direction}
            and $options{options}{direction} eq 'rtl' )
        {
            ( $out, $out2 ) = ( $out2, $out );
        }

        my $new = Gscan2pdf::Page->new(
            filename => $out,
            dir      => $options{dir},
            delete   => TRUE,
            format   => 'Portable anymap',
        );

        # unpaper doesn't change the resolution, so we can safely copy it
        if ( defined $options{page}{xresolution} ) {
            $new->{xresolution} = $options{page}{xresolution};
            $new->{yresolution} = $options{page}{yresolution};
        }

        # reuse uuid so that the process chain can find it again
        $new->{uuid}       = $options{page}{uuid};
        $new->{dirty_time} = timestamp();            #flag as dirty
        $self->{return}->enqueue(
            {
                type => 'page',
                uuid => $options{uuid},
                page => $new->freeze,
                info => { replace => $options{page}{uuid} }
            }
        );

        if ( $out2 ne $EMPTY ) {
            my $new2 = Gscan2pdf::Page->new(
                filename => $out2,
                dir      => $options{dir},
                delete   => TRUE,
                format   => 'Portable anymap',
            );

            # unpaper doesn't change the resolution, so we can safely copy it
            if ( defined $options{page}{xresolution} ) {
                $new2->{xresolution} = $options{page}{xresolution};
                $new2->{yresolution} = $options{page}{yresolution};
            }

            $new2->{dirty_time} = timestamp();    #flag as dirty
            $self->{return}->enqueue(
                {
                    type => 'page',
                    uuid => $options{uuid},
                    page => $new2->freeze,
                    info => { 'insert-after' => $new->{uuid} }
                }
            );
        }
    }
    catch {
        $logger->error("Error creating file in $options{dir}: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'unpaper', "Error creating file in $options{dir}: $_." );
    };
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'unpaper',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_user_defined {
    my ( $self, %options ) = @_;
    if (
        _thread_no_filename(
            $self, 'user-defined', $options{uuid}, $options{page}
        )
      )
    {
        return;
    }
    my $in = $options{page}{filename};
    my $suffix;
    if ( $in =~ /([.]\w*)$/xsm ) {
        $suffix = $1;
    }
    try {
        my $out = File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => $suffix,
            UNLINK => FALSE
        );

        if ( $options{command} =~ s/%o/$out/gxsm ) {
            $options{command} =~ s/%i/$in/gxsm;
        }
        else {
            if ( not copy( $in, $out ) ) {
                _thread_throw_error( $self, $options{uuid},
                    $options{page}{uuid},
                    'user-defined', __('Error copying page') );
                return;
            }
            $options{command} =~ s/%i/$out/gxsm;
        }
        $options{command} =~ s/%r/$options{page}{xresolution}/gxsm;
        ( undef, my $info, my $error ) =
          exec_command( [ $options{command} ], $options{pidfile} );
        return if $_self->{cancel};
        $logger->info("stdout: $info");
        $logger->info("stderr: $error");

        # don't return in here, just in case we can ignore the error -
        # e.g. theming errors from gimp
        if ( $error ne $EMPTY ) {
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'user-defined', $error );
        }

        # Get file type
        my $image = Image::Magick->new;
        my $e     = $image->Read($out);
        if ("$e") {
            $logger->error($e);
            _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
                'user-defined', "Error reading $out: $e." );
            return;
        }

        my $new = Gscan2pdf::Page->new(
            filename => $out,
            dir      => $options{dir},
            delete   => TRUE,
            format   => $image->Get('format'),
        );

        # No way to tell what resolution a pnm is,
        # so assume it hasn't changed
        if ( $new->{format} =~ /Portable\s(:?any|bit|gray|pix)map/xsm ) {
            $new->{xresolution} = $options{page}{xresolution};
            $new->{yresolution} = $options{page}{yresolution};
        }

        # Copy the OCR output
        $new->{bboxtree} = $options{page}{bboxtree};

        # reuse uuid so that the process chain can find it again
        $new->{uuid} = $options{page}{uuid};
        $self->{return}->enqueue(
            {
                type => 'page',
                uuid => $options{uuid},
                page => $new->freeze,
                info => { replace => $options{page}{uuid} }
            }
        );
    }
    catch {
        $logger->error("Error creating file in $options{dir}: $_");
        _thread_throw_error( $self, $options{uuid}, $options{page}{uuid},
            'user-defined', "Error creating file in $options{dir}: $_." );
    };
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'user-defined',
            uuid    => $options{uuid},
        }
    );
    return;
}

sub _thread_paper_sizes {
    ( my $self, $paper_sizes ) = @_;
    return;
}

# Build a look-up table of all true-type fonts installed

sub parse_truetype_fonts {
    my ($fclist) = @_;
    my %fonts;
    for ( split /\n/sm, $fclist ) {
        if (/ttf:[ ]/xsm) {
            my ( $file, $family, $style ) = split /:/xsm;
            if ( $file and $family and $style ) {
                chomp $style;
                $family =~ s/^[ ]//xsm;
                $family =~ s/,.*$//xsm;
                $style  =~ s/^style=//xsm;
                $style  =~ s/,.*$//xsm;
                $fonts{by_file}{$file} = [ $family, $style ];
                $fonts{by_family}{$family}{$style} = $file;
            }
        }
    }
    return \%fonts;
}

# If user selects session dir as tmp dir, return parent dir

sub get_tmp_dir {
    my ( $dir, $pattern ) = @_;
    if ( not defined $dir ) { return }
    while ( $dir =~ /$pattern/xsm ) {
        $dir = dirname($dir);
    }
    return $dir;
}

1;

__END__
