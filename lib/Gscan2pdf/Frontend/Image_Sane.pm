package Gscan2pdf::Frontend::Image_Sane;

use strict;
use warnings;
use feature 'switch';
no if $] >= 5.018, warnings => 'experimental::smartmatch';

use threads;
use threads::shared;
use Thread::Queue;
use Storable qw(freeze thaw);    # For cloning the options cache
use Try::Tiny;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
use Glib qw(TRUE FALSE);
use Image::Sane ':all';
use Data::UUID;
use File::Temp;                  # To create temporary files
use Readonly;
Readonly my $BUFFER_SIZE    => ( 32 * 1024 );     # default size
Readonly my $_POLL_INTERVAL => 100;               # ms
Readonly my $_8_BIT         => 8;
Readonly my $MAXVAL_8_BIT   => 2**$_8_BIT - 1;
Readonly my $_16_BIT        => 16;
Readonly my $MAXVAL_16_BIT  => 2**$_16_BIT - 1;
Readonly my $LARGE_STATUS   => 99;
Readonly my $NOT_FOUND      => -1;
my $uuid_object = Data::UUID->new;
my $EMPTY       = q{};

our $VERSION = '2.7.0';

my ( $prog_name, $logger, %callback, $_self );

sub setup {
    ( my $class, $logger ) = @_;
    $_self     = {};
    $prog_name = Glib::get_application_name;

    $_self->{requests} = Thread::Queue->new;
    $_self->{return}   = Thread::Queue->new;

    # $_self->{device_handle} explicitly not shared
    share $_self->{abort_scan};
    share $_self->{scan_progress};

    $_self->{thread} = threads->new( \&_thread_main, $_self );
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
    return \$sentinel;
}

sub _monitor_process {
    my ( $sentinel, $uuid ) = @_;

    my $started;
    Glib::Timeout->add(
        $_POLL_INTERVAL,
        sub {
            if ( ${$sentinel} == 2 ) {
                if ( not $started ) {
                    if ( defined $callback{$uuid}{started} ) {
                        $callback{$uuid}{started}->();
                        delete $callback{$uuid}{started};
                    }
                    $started = 1;
                }
                check_return_queue();
                return Glib::SOURCE_REMOVE;
            }
            elsif ( ${$sentinel} == 1 ) {
                if ( not $started ) {
                    if ( defined $callback{$uuid}{started} ) {
                        $callback{$uuid}{started}->();
                        delete $callback{$uuid}{started};
                    }
                    $started = 1;
                }
                if ( defined $callback{$uuid}{running} ) {
                    $callback{$uuid}{running}->();
                }
                return Glib::SOURCE_CONTINUE;
            }
        }
    );
    return;
}

sub quit {
    _enqueue_request('quit');
    $_self->{thread}->join();
    $_self->{thread} = undef;
    return;
}

sub get_devices {
    my ( $class, $started_callback, $running_callback, $finished_callback ) =
      @_;

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{started}  = $started_callback;
    $callback{$uuid}{running}  = $running_callback;
    $callback{$uuid}{finished} = $finished_callback;
    my $sentinel = _enqueue_request( 'get-devices', { uuid => $uuid } );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub is_connected {
    return defined $_self->{device_name};
}

sub device {
    return $_self->{device_name};
}

sub open_device {
    my ( $class, %options ) = @_;

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{started}  = $options{started_callback};
    $callback{$uuid}{running}  = $options{running_callback};
    $callback{$uuid}{finished} = sub {
        $_self->{device_name} = $options{device_name};
        $options{finished_callback}->();
    };
    $callback{$uuid}{error} = $options{error_callback};
    my $sentinel =
      _enqueue_request( 'open',
        { uuid => $uuid, device_name => $options{device_name} } );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub close_device {
    my ( $class, %options ) = @_;

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{started}  = $options{started_callback};
    $callback{$uuid}{running}  = $options{running_callback};
    $callback{$uuid}{finished} = sub {
        $_self->{device_name} = $options{device_name};
        $options{finished_callback}->();
    };
    $callback{$uuid}{error} = $options{error_callback};
    my $sentinel =
      _enqueue_request( 'close',
        { uuid => $uuid, device_name => $options{device_name} } );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub find_scan_options {
    my (
        $class,             $started_callback, $running_callback,
        $finished_callback, $error_callback
    ) = @_;

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{started}  = $started_callback;
    $callback{$uuid}{running}  = $running_callback;
    $callback{$uuid}{finished} = $finished_callback;
    $callback{$uuid}{error}    = $error_callback;
    my $sentinel = _enqueue_request( 'get-options', { uuid => $uuid } );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub set_option {
    my ( $class, %options ) = @_;

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{started}  = $options{started_callback};
    $callback{$uuid}{running}  = $options{running_callback};
    $callback{$uuid}{finished} = $options{finished_callback};
    $callback{$uuid}{error}    = $options{error_callback};
    my $sentinel = _enqueue_request(
        'set-option',
        {
            index => $options{index},
            value => $options{value},
            uuid  => $uuid,
        }
    );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub scan_page {
    my ( $class, %options ) = @_;

    $_self->{abort_scan}    = 0;
    $_self->{scan_progress} = 0;
    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{started}  = $options{started_callback};
    $callback{$uuid}{running}  = $options{running_callback};
    $callback{$uuid}{error}    = $options{error_callback};
    $callback{$uuid}{finished} = $options{finished_callback};
    my $sentinel = _enqueue_request( 'scan-page',
        { uuid => $uuid, path => "$options{path}" } );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub scan_page_finished_callback {
    my ( $status, $path, $n_scanned, %options ) = @_;
    if (    defined $options{new_page_callback}
        and not $_self->{abort_scan}
        and ( $status == SANE_STATUS_GOOD or $status == SANE_STATUS_EOF ) )
    {
        $options{new_page_callback}->( $status, $path, $options{start} );
    }

    # Stop the process unless everything OK and more scans required
    if (
           $_self->{abort_scan}
        or ( $options{npages} and $n_scanned >= $options{npages} )
        or (    $status != SANE_STATUS_GOOD
            and $status != SANE_STATUS_EOF )
      )
    {
        if ( $_self->{abort_scan} ) { unlink $path }
        _enqueue_request( 'cancel', { uuid => $uuid_object->create_str } );
        if ( _scanned_enough_pages( $status, $options{npages}, $n_scanned ) ) {
            if ( defined $options{finished_callback} ) {
                $options{finished_callback}->();
            }
        }
        else {
            if ( defined $options{error_callback} ) {
                $options{error_callback}->( Image::Sane::strstatus($status) );
            }
        }
        return;
    }
    elsif ( $options{cancel_between_pages} ) {
        _enqueue_request( 'cancel', { uuid => $uuid_object->create_str } );
    }

    if ( not defined $options{step} ) { $options{step} = 1 }
    $options{start} += $options{step};
    Gscan2pdf::Frontend::Image_Sane->scan_page(
        path => File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => '.pnm',
            UNLINK => FALSE,
        ),
        started_callback => $options{started_callback},
        running_callback => sub {
            $options{running_callback}->( $_self->{scan_progress} );
        },
        error_callback    => $options{error_callback},
        finished_callback => sub {
            my ( $new_path, $new_status ) = @_;
            scan_page_finished_callback( $new_status, $new_path, ++$n_scanned,
                %options );
        },
    );
    return;
}

sub scan_pages {
    my ( $class, %options ) = @_;

    my $num_pages_scanned = 0;
    Gscan2pdf::Frontend::Image_Sane->scan_page(
        path => File::Temp->new(
            DIR    => $options{dir},
            SUFFIX => '.pnm',
            UNLINK => FALSE,
        ),
        started_callback => $options{started_callback},
        running_callback => sub {
            if ( defined $options{running_callback} ) {
                $options{running_callback}->( $_self->{scan_progress} );
            }
        },
        error_callback    => $options{error_callback},
        finished_callback => sub {
            my ( $path, $status ) = @_;
            scan_page_finished_callback( $status, $path, ++$num_pages_scanned,
                %options );
        },
    );
    return;
}

sub _scanned_enough_pages {
    my ( $status, $nrequired, $ndone ) = @_;
    return (
             $status == SANE_STATUS_GOOD
          or $status == SANE_STATUS_EOF
          or ( $status == SANE_STATUS_NO_DOCS
            and ( $nrequired == 0 or $nrequired < $ndone ) )
    );
}

# Flag the scan routine to abort

sub cancel_scan {
    my ( $self, $callback ) = @_;

    # Empty process queue first to stop any new process from starting
    $logger->info('Emptying process queue');
    while ( $_self->{requests}->dequeue_nb ) { }

    # Then send the thread a cancel signal
    $_self->{abort_scan} = 1;

    my $uuid = $uuid_object->create_str;
    $callback{$uuid}{cancelled} = $callback;

    # Add a cancel request to ensure the reply is not blocked
    $logger->info('Requesting cancel');
    my $sentinel = _enqueue_request( 'cancel', { uuid => $uuid } );
    _monitor_process( $sentinel, $uuid );
    return;
}

sub _thaw_deref {
    my ($ref) = @_;
    if ( defined $ref ) {
        $ref = thaw($ref);
        if ( ref($ref) eq 'SCALAR' ) { $ref = ${$ref} }
    }
    return $ref;
}

sub check_return_queue {
    while ( defined( my $data = $_self->{return}->dequeue_nb() ) ) {
        if ( not defined $data->{type} ) {
            $logger->error("Bad data bundle $data in return queue.");
            next;
        }
        if ( not defined $data->{uuid} ) {
            $logger->error('Bad uuid in return queue.');
            next;
        }

        # if we have pressed the cancel button, ignore everything in the returns
        # queue until it flags 'cancelled'.
        if ( $_self->{cancel} ) {
            if ( $data->{type} eq 'cancelled' ) {
                $_self->{cancel} = FALSE;
                if ( defined $callback{ $data->{uuid} }{cancelled} ) {
                    $callback{ $data->{uuid} }{cancelled}
                      ->( _thaw_deref( $data->{info} ) );
                    delete $callback{ $data->{uuid} };
                }
            }
            else {
                next;
            }
        }

        if ( $data->{type} eq 'error' ) {
            if ( $data->{status} == SANE_STATUS_NO_DOCS ) {
                $data->{type} = 'finished';
            }
            else {
                if ( defined $callback{ $data->{uuid} }{error} ) {
                    $callback{ $data->{uuid} }{error}
                      ->( $data->{message}, $data->{status} );
                    delete $callback{ $data->{uuid} };
                }
                return Glib::SOURCE_CONTINUE;
            }
        }
        if ( $data->{type} eq 'finished' ) {
            if ( defined $callback{ $data->{uuid} }{started} ) {
                $callback{ $data->{uuid} }{started}->();
            }
            if ( defined $callback{ $data->{uuid} }{finished} ) {
                if ( $data->{process} eq 'set-option' ) {
                    $callback{ $data->{uuid} }{finished}
                      ->( $data->{info}, $data->{status} );
                }
                else {
                    $callback{ $data->{uuid} }{finished}
                      ->( _thaw_deref( $data->{info} ), $data->{status} );
                }
                delete $callback{ $data->{uuid} };
            }
        }
    }
    return Glib::SOURCE_CONTINUE;
}

sub _log2 {
    my ($n) = @_;
    return log($n) / log 2;
}

sub decode_info {
    my ($info) = @_;
    if ( $info == 0 ) { return 'none' }
    my @opts =
      qw(SANE_INFO_INEXACT SANE_INFO_RELOAD_OPTIONS SANE_INFO_RELOAD_PARAMS);
    my @this;
    my $n = _log2($info);
    if ( $n > int $n ) {
        $n = int($n) + 1;
    }
    my $i = @opts;
    while ( $n > $i ) {
        if ( $info >= 2**( $n - 1 ) ) {
            push @this, q{?};
            $info -= 2**( $n - 1 );
        }
        --$n;
    }
    while ( $n > $NOT_FOUND ) {
        if ( $info >= 2**$n ) {
            push @this, $opts[$n];
            $info -= 2**$n;
        }
        --$n;
    }
    return join ' + ', @this;
}

sub _thread_main {
    my ($self) = @_;

    while ( my $request = $self->{requests}->dequeue ) {

        # Signal the sentinel that the request was started.
        ${ $request->{sentinel} }++;

        given ( $request->{action} ) {
            when ('quit') { last }
            when ('get-devices') {
                _thread_get_devices( $self, $request->{uuid} )
            }
            when ('open') {
                _thread_open_device( $self, $request->{uuid},
                    $request->{device_name} )
            }
            when ('close') {
                if ( defined( $self->{device_handle} ) ) {
                    $logger->debug("closing device '$self->{device_name}'");
                    undef $self->{device_handle};
                }
                else {
                    $logger->debug(
                        'Ignoring close_device() call - no device open.');
                }
            }
            when ('get-options') {
                _thread_get_options( $self, $request->{uuid} )
            }
            when ('set-option') {
                _thread_set_option( $self, $request->{uuid}, $request->{index},
                    $request->{value} )
            }
            when ('scan-page') {
                _thread_scan_page( $self, $request->{uuid}, $request->{path} )
            }
            when ('cancel') { _thread_cancel( $self, $request->{uuid} ) }
            default {
                $logger->info("Ignoring unknown request $_");
                next;
            }
        }

        # Signal the sentinel that the request was completed.
        ${ $request->{sentinel} }++;
    }
    return;
}

sub _thread_get_devices {
    my ( $self, $uuid ) = @_;
    my @devices;
    my $status = SANE_STATUS_GOOD;
    try {
        @devices = Image::Sane->get_devices;
    }
    catch {
        $status = $_->status;
    };
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'get-devices',
            uuid    => $uuid,
            info    => freeze( \@devices ),
            status  => $status,
        }
    );
    return;
}

sub _thread_throw_error {
    my ( $self, $uuid, $process, $status, $message ) = @_;
    $logger->info($message);
    $self->{return}->enqueue(
        {
            type    => 'error',
            uuid    => $uuid,
            status  => $status,
            message => $message,
            process => $process,
        }
    );
    return;
}

sub _thread_open_device {
    my ( $self, $uuid, $device_name ) = @_;

    if ( not defined $device_name or $device_name eq $EMPTY ) {
        _thread_throw_error( $self, $uuid, 'open-device',
            SANE_STATUS_ACCESS_DENIED, 'Cannot open undefined device' );
        return;
    }

    # close the handle
    if ( defined( $self->{device_handle} ) ) { undef $self->{device_handle} }

    my $status = SANE_STATUS_GOOD;
    try {
        $self->{device_handle} = Image::Sane::Device->open($device_name);
        $self->{device_name}   = $device_name;
        $logger->debug("opened device '$self->{device_name}'");
    }
    catch {
        $status = $_->status;
        _thread_throw_error( $self, $uuid, 'open-device', $status,
            "opening device '$device_name': " . $_->error );
    };
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'open-device',
            uuid    => $uuid,
            info    => freeze( \$device_name ),
            status  => $status,
        }
    );
    return;
}

sub _thread_get_options {
    my ( $self, $uuid ) = @_;
    my @options;

    # We got a device, find out how many options it has:
    my $status = SANE_STATUS_GOOD;
    my $num_dev_options;
    try {
        $num_dev_options = $self->{device_handle}->get_option(0);
    }
    catch {
        $status = $_->status;
        _thread_throw_error( $self, $uuid, 'get-options', $status,
            'unable to determine option count: ' . $_->error );
    };
    $logger->debug("Backend reports $num_dev_options options");

    if ( $status == SANE_STATUS_GOOD ) {

        # if we can retrieve at least one good option, then do so.
        # otherwise return the error message
        $status = $LARGE_STATUS;
        for my $i ( 1 .. $num_dev_options - 1 ) {
            my $opt;
            try {
                $opt = $self->{device_handle}->get_option_descriptor($i);
            }
            catch {
                $status = $_->status;
                _thread_throw_error( $self, $uuid, 'get_option_descriptor',
                    $status,
                    "error getting option descriptor $i: " . $_->error );
            };
            $options[$i] = $opt;
            if (
                $opt->{cap} & SANE_CAP_SOFT_DETECT
                and not( ( $opt->{cap} & SANE_CAP_INACTIVE )
                    or ( $opt->{type} == SANE_TYPE_BUTTON )
                    or ( $opt->{type} == SANE_TYPE_GROUP ) )
              )
            {
                try {
                    $opt->{val} = $self->{device_handle}->get_option($i);
                    $status = SANE_STATUS_GOOD;
                }
                catch {
                    if ( $_->status < $status ) { $status = $_->status }
                    $opt->{cap} = 0;
                    $logger->warn( "Error getting option $i. ", Dumper($opt) );
                };
            }
        }
        if ( $status != SANE_STATUS_GOOD ) {
            _thread_throw_error( $self, $uuid, 'get_option', $status,
                'no options fetched: ' . $_->error );
        }
    }
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'get-options',
            uuid    => $uuid,
            info    => freeze( \@options ),
            status  => $status,
        }
    );
    return $status;
}

sub _thread_set_option {
    my ( $self, $uuid, $index, $value ) = @_;
    my $opt = $self->{device_handle}->get_option_descriptor($index);
    if ( $opt->{type} == SANE_TYPE_BOOL and $value eq $EMPTY ) { $value = 0 }

    # FIXME: Stringification to force this SV to have a PV slot.  This seems to
    # be necessary to get through Sane.pm's value checks.
    if ( $opt->{type} != SANE_TYPE_BUTTON ) { $value = "$value" }

    my $status = SANE_STATUS_GOOD;
    my $info;
    try {
        $info = $self->{device_handle}->set_option( $index, $value );
    }
    catch {
        $status = $_->status;
    };
    if ( $logger->is_info ) {
        $logger->info(
                "sane_set_option $index ($opt->{name})"
              . ( $opt->{type} == SANE_TYPE_BUTTON ? $EMPTY : " to $value" )
              . " returned status $status ("
              . Image::Sane::strstatus($status)
              . ') with info '
              . (
                defined $info
                ? sprintf( '%d (%s)',
                    $info, Gscan2pdf::Frontend::Image_Sane::decode_info($info) )
                : 'undefined'
              )
        );
    }
    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'set-option',
            uuid    => $uuid,
            status  => $status,
            info    => $info,
        }
    );
    return;
}

sub _thread_write_pnm_header {
    my ( $fh, $format, $width, $height, $depth ) = @_;

    # The netpbm-package does not define raw image data with maxval > 255.
    # But writing maxval 65535 for 16bit data gives at least a chance
    # to read the image.

    if (   $format == SANE_FRAME_RED
        or $format == SANE_FRAME_GREEN
        or $format == SANE_FRAME_BLUE
        or $format == SANE_FRAME_RGB )
    {
        printf {$fh} "P6\n# SANE data follows\n%d %d\n%d\n", $width, $height,
          ( $depth > $_8_BIT ) ? $MAXVAL_16_BIT : $MAXVAL_8_BIT;
    }
    else {
        if ( $depth == 1 ) {
            printf {$fh} "P4\n# SANE data follows\n%d %d\n", $width, $height;
        }
        else {
            printf {$fh} "P5\n# SANE data follows\n%d %d\n%d\n", $width,
              $height,
              ( $depth > $_8_BIT ) ? $MAXVAL_16_BIT : $MAXVAL_8_BIT;
        }
    }
    return;
}

sub _thread_scan_page_to_fh {
    my ( $device, $fh ) = @_;
    my $first_frame = 1;
    my $offset      = 0;
    my $must_buffer = 0;
    my ( %image, $status );
    my @format_name = qw( gray RGB red green blue );
    my $total_bytes = 0;

    my ( $parm, $last_frame );
    while ( not $last_frame ) {
        $status = SANE_STATUS_GOOD;
        if ( not $first_frame ) {
            try {
                $device->start;
            }
            catch {
                $status = $_->status;
                $logger->info( "$prog_name: sane_start: " . $_->error );
            };
            if ( $status != SANE_STATUS_GOOD ) { goto CLEANUP }
        }

        try {
            $parm = $device->get_parameters;
        }
        catch {
            $status = $_->status;
            $logger->info( "$prog_name: sane_get_parameters: " . $_->error );
        };
        if ( $status != SANE_STATUS_GOOD ) { goto CLEANUP }

        _log_frame_info( $first_frame, $parm, \@format_name );
        ( $must_buffer, $offset ) =
          _initialise_scan( $fh, $first_frame, $parm );
        my $hundred_percent = _scan_data_size($parm);

        while (1) {

            # Pick up flag from cancel_scan()
            if ( $_self->{abort_scan} ) {
                $device->cancel;
                $logger->info('Scan cancelled');
                return SANE_STATUS_CANCELLED;
            }

            my ( $buffer, $len );
            try {
                ( $buffer, $len ) = $device->read($BUFFER_SIZE);
                $total_bytes += $len;
            }
            catch {
                $status = $_->status;
                $logger->info( "$prog_name: sane_read: " . $_->error );
            };
            my $progr = $total_bytes / $hundred_percent;
            if ( $progr > 1 ) { $progr = 1 }
            $_self->{scan_progress} = $progr;

            if ( $status != SANE_STATUS_GOOD ) {
                if ( $parm->{depth} == $_8_BIT ) {
                    $logger->info(
                        sprintf "$prog_name: min/max graylevel value = %d/%d",
                        $MAXVAL_8_BIT, 0 );
                }
                if ( $status != SANE_STATUS_EOF ) { return $status }
                last;
            }

            if ($must_buffer) {
                $offset =
                  _buffer_scan( $offset, $parm, \%image, $len, $buffer );
            }
            else {
                goto CLEANUP if not print {$fh} $buffer;
            }
        }
        $first_frame = 0;
        $last_frame  = $parm->{last_frame};
    }

    if ($must_buffer) { _write_buffer_to_fh( $fh, $parm, \%image ) }

  CLEANUP:
    my $expected_bytes =
      $parm->{bytes_per_line} * $parm->{lines} * _number_frames($parm);
    if ( $parm->{lines} < 0 ) { $expected_bytes = 0 }
    if ( $total_bytes > $expected_bytes and $expected_bytes != 0 ) {
        $logger->info(
            sprintf '%s: WARNING: read more data than announced by backend '
              . '(%u/%u)',
            $prog_name, $total_bytes, $expected_bytes );
    }
    else {
        $logger->info( sprintf '%s: read %u bytes in total',
            $prog_name, $total_bytes );
    }
    return $status;
}

sub _thread_scan_page {
    my ( $self, $uuid, $path ) = @_;

    if ( not defined( $self->{device_handle} ) ) {
        _thread_throw_error( $self, $uuid, 'scan-page',
            SANE_STATUS_ACCESS_DENIED,
            "$prog_name: must open device before starting scan" );
        return;
    }
    my $status = SANE_STATUS_GOOD;
    try {
        $self->{device_handle}->start;
    }
    catch {
        $status = $_->status;
        _thread_throw_error( $self, $uuid, 'scan-page', $status,
            "$prog_name: sane_start: " . $_->error );
        unlink $path;
    };
    if ( $status != SANE_STATUS_GOOD ) { return }

    my $fh;
    if ( not open $fh, '>', $path ) {
        $self->{device_handle}->cancel;
        _thread_throw_error( $self, $uuid, 'scan-page',
            SANE_STATUS_ACCESS_DENIED, "Error writing to $path" );
        return;
    }

    $status = _thread_scan_page_to_fh( $self->{device_handle}, $fh );

    if ( not close $fh ) {
        $self->{device_handle}->cancel;
        _thread_throw_error( $self, $uuid, 'scan-page',
            SANE_STATUS_ACCESS_DENIED, "Error closing $path" );
        return;
    }

    $logger->info( sprintf 'Scanned page %s. (scanner status = %d)',
        $path, $status );

    if ( $status != SANE_STATUS_GOOD and $status != SANE_STATUS_EOF ) {
        unlink $path;
    }

    $self->{return}->enqueue(
        {
            type    => 'finished',
            process => 'scan-page',
            uuid    => $uuid,
            status  => $status,
            info    => freeze( \$path ),
        }
    );
    return;
}

sub _thread_cancel {
    my ( $self, $uuid ) = @_;
    if ( defined $self->{device_handle} ) { $self->{device_handle}->cancel }
    $self->{return}->enqueue( { type => 'cancelled', uuid => $uuid } );
    return;
}

sub _log_frame_info {
    my ( $first_frame, $parm, $format_name ) = @_;
    if ($first_frame) {
        if ( $parm->{lines} >= 0 ) {
            $logger->info(
                sprintf "$prog_name: scanning image of size %dx%d pixels at "
                  . '%d bits/pixel',
                $parm->{pixels_per_line},
                $parm->{lines},
                $_8_BIT * $parm->{bytes_per_line} / $parm->{pixels_per_line}
            );
        }
        else {
            $logger->info(
                sprintf "$prog_name: scanning image %d pixels wide and "
                  . 'variable height at %d bits/pixel',
                $parm->{pixels_per_line},
                $_8_BIT * $parm->{bytes_per_line} / $parm->{pixels_per_line}
            );
        }

        $logger->info(
            sprintf "$prog_name: acquiring %s frame",
            $parm->{format} <= SANE_FRAME_BLUE
            ? $format_name->[ $parm->{format} ]
            : 'Unknown'
        );
    }
    return;
}

sub _initialise_scan {
    my ( $fh, $first_frame, $parm ) = @_;
    my ( $must_buffer, $offset );
    if ($first_frame) {
        if (   $parm->{format} == SANE_FRAME_RED
            or $parm->{format} == SANE_FRAME_GREEN
            or $parm->{format} == SANE_FRAME_BLUE )
        {
            if ( $parm->{depth} != $_8_BIT ) {
                die "Red/Green/Blue frames require depth=$_8_BIT\n";
            }
            $must_buffer = 1;
            $offset      = $parm->{format} - SANE_FRAME_RED;
        }
        elsif ( $parm->{format} == SANE_FRAME_RGB ) {
            if (    ( $parm->{depth} != $_8_BIT )
                and ( $parm->{depth} != $_16_BIT ) )
            {
                die "RGB frames require depth=$_8_BIT or $_16_BIT\n";
            }
        }
        if (   $parm->{format} == SANE_FRAME_RGB
            or $parm->{format} == SANE_FRAME_GRAY )
        {
            if (    ( $parm->{depth} != 1 )
                and ( $parm->{depth} != $_8_BIT )
                and ( $parm->{depth} != $_16_BIT ) )
            {
                die "Valid depths are 1, $_8_BIT or $_16_BIT\n";
            }
            if ( $parm->{lines} < 0 ) {
                $must_buffer = 1;
                $offset      = 0;
            }
            else {
                _thread_write_pnm_header( $fh, $parm->{format},
                    $parm->{pixels_per_line},
                    $parm->{lines}, $parm->{depth} );
            }
        }
    }
    else {
        die "Encountered unknown format\n"
          if ( $parm->{format} < SANE_FRAME_RED
            or $parm->{format} > SANE_FRAME_BLUE );
        $offset = $parm->{format} - SANE_FRAME_RED;
    }
    return ( $must_buffer, $offset );
}

# Return size of final scan (ignoring header)

sub _scan_data_size {
    my ($parm) = @_;
    return $parm->{bytes_per_line} * $parm->{lines} * _number_frames($parm);
}

# Return number of frames

sub _number_frames {
    my ($parm) = @_;
    return (
             $parm->{format} == SANE_FRAME_RGB
          or $parm->{format} == SANE_FRAME_GRAY
      )
      ? 1
      : 3;    ## no critic (ProhibitMagicNumbers)
}

# We're either scanning a multi-frame image or the
# scanner doesn't know what the eventual image height
# will be (common for hand-held scanners).  In either
# case, we need to buffer all data before we can write
# the header

sub _buffer_scan {
    my ( $offset, $parm, $image, $len, $buffer ) = @_;

    my $number_frames = _number_frames($parm);
    for ( 0 .. $len - 1 ) {
        $image->{data}[ $offset + $number_frames * $_ ] = substr $buffer, $_, 1;
    }
    $offset += $number_frames * $len;
    return $offset;
}

sub _write_buffer_to_fh {
    my ( $fh, $parm, $image ) = @_;
    if ( $parm->{lines} > 0 ) {
        $image->{height} = $parm->{lines};
    }
    else {
        $image->{height} = @{ $image->{data} } / $parm->{pixels_per_line};
        $image->{height} /= _number_frames($parm);
    }
    _thread_write_pnm_header( $fh, $parm->{format}, $parm->{pixels_per_line},
        $image->{height}, $parm->{depth} );
    for my $data ( @{ $image->{data} } ) {
        goto CLEANUP if not print {$fh} $data;
    }
    return;
}

1;

__END__
