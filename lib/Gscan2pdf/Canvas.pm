package Gscan2pdf::Canvas;

use strict;
use warnings;
use feature 'switch';
no if $] >= 5.018, warnings => 'experimental::smartmatch';
use GooCanvas2;
use Glib 1.220 qw(TRUE FALSE);    # To get TRUE and FALSE
use HTML::Entities;
use Readonly;
Readonly my $_100_PERCENT       => 100;
Readonly my $_360_DEGREES       => 360;
Readonly my $FULLPAGE_OCR_SCALE => 0.8;
my $SPACE = q{ };
my $EMPTY = q{};

our $VERSION = '2.2.0';

use Glib::Object::Subclass GooCanvas2::Canvas::, signals => {
    'zoom-changed' => {
        param_types => ['Glib::Float'],    # new zoom
    },
    'offset-changed' => {
        param_types => [ 'Glib::Int', 'Glib::Int' ],    # new offset
    },
  },
  properties => [
    Glib::ParamSpec->scalar(
        'offset',                                       # name
        'Image offset',                                 # nick
        'Gdk::Rectangle hash of x, y',                  # blurb
        [qw/readable writable/]                         # flags
    ),
  ];

sub INIT_INSTANCE {
    my $self = shift;

    # Set up the canvas
    $self->signal_connect( 'button-press-event'   => \&_button_pressed );
    $self->signal_connect( 'button-release-event' => \&_button_released );
    $self->signal_connect( 'motion-notify-event'  => \&_motion );
    $self->signal_connect( 'scroll-event'         => \&_scroll );
    if (
        $Glib::Object::Introspection::VERSION <
        0.043    ## no critic (ProhibitMagicNumbers)
      )
    {
        $self->add_events(
            ${ Gtk3::Gdk::EventMask->new(qw/exposure-mask/) } |
              ${ Gtk3::Gdk::EventMask->new(qw/button-press-mask/) } |
              ${ Gtk3::Gdk::EventMask->new(qw/button-release-mask/) } |
              ${ Gtk3::Gdk::EventMask->new(qw/pointer-motion-mask/) } |
              ${ Gtk3::Gdk::EventMask->new(qw/scroll-mask/) } );
    }
    else {
        $self->add_events(
            Glib::Object::Introspection->convert_sv_to_flags(
                'Gtk3::Gdk::EventMask', 'exposure-mask' ) |
              Glib::Object::Introspection->convert_sv_to_flags(
                'Gtk3::Gdk::EventMask', 'button-press-mask' ) |
              Glib::Object::Introspection->convert_sv_to_flags(
                'Gtk3::Gdk::EventMask', 'button-release-mask' ) |
              Glib::Object::Introspection->convert_sv_to_flags(
                'Gtk3::Gdk::EventMask', 'pointer-motion-mask' ) |
              Glib::Object::Introspection->convert_sv_to_flags(
                'Gtk3::Gdk::EventMask', 'scroll-mask'
              )
        );
    }
    $self->{offset}{x} = 0;
    $self->{offset}{y} = 0;

    return $self;
}

sub SET_PROPERTY {
    my ( $self, $pspec, $newval ) = @_;
    my $name   = $pspec->get_name;
    my $oldval = $self->get($name);
    if (   ( defined $newval and defined $oldval and $newval ne $oldval )
        or ( defined $newval xor defined $oldval ) )
    {
        given ($name) {
            when ('offset') {
                if (   ( defined $newval xor defined $oldval )
                    or $oldval->{x} != $newval->{x}
                    or $oldval->{y} != $newval->{y} )
                {
                    $self->{$name} = $newval;
                    $self->scroll_to( -$newval->{x}, -$newval->{y} );
                    $self->signal_emit( 'offset-changed', $newval->{x},
                        $newval->{y} );
                }
            }
            default {
                $self->{$name} = $newval;

                #                $self->SUPER::SET_PROPERTY( $pspec, $newval );
            }
        }
    }
    return;
}

sub add_text {
    my ( $self, $page, $edit_callback ) = @_;
    my $root = $self->get_root_item;
    if ( not defined $page->{w} ) {

        # quotes required to prevent File::Temp object being clobbered
        my $pixbuf = Gtk3::Gdk::Pixbuf->new_from_file("$page->{filename}");
        $page->{w} = $pixbuf->get_width;
        $page->{h} = $pixbuf->get_height;
    }
    $self->{pixbuf_size} = { width => $page->{w}, height => $page->{h} };
    $self->set_bounds( 0, 0, $page->{w}, $page->{h} );

    # Attach the text to the canvas
    for my $box ( @{ $page->boxes } ) {
        boxed_text( $root, $box, [ 0, 0, 0 ], $edit_callback );
    }
    return;
}

sub get_pixbuf_size {
    my ($self) = @_;
    return $self->{pixbuf_size};
}

sub clear_text {
    my ($self) = @_;
    my $root = $self->get_root_item;
    if ( $root->get_n_children > 0 ) {
        $root->remove_child(0);
    }
    delete $self->{pixbuf_size};
    return;
}

sub set_offset {
    my ( $self, $offset_x, $offset_y ) = @_;
    if ( not defined $self->get_pixbuf_size ) { return }

    # Convert the widget size to image scale to make the comparisons easier
    my $allocation = $self->get_allocation;
    ( $allocation->{width}, $allocation->{height} ) =
      $self->_to_image_distance( $allocation->{width}, $allocation->{height} );
    my $pixbuf_size = $self->get_pixbuf_size;

    $offset_x = _clamp_direction( $offset_x, $allocation->{width},
        $pixbuf_size->{width} );
    $offset_y = _clamp_direction( $offset_y, $allocation->{height},
        $pixbuf_size->{height} );

    my $min_x = 0;
    my $min_y = 0;
    if ( $offset_x > 0 ) {
        $min_x = -$offset_x;
    }
    if ( $offset_y > 0 ) {
        $min_y = -$offset_y;
    }
    $self->set_bounds(
        $min_x, $min_y,
        $pixbuf_size->{width} - $min_x,
        $pixbuf_size->{height} - $min_y
    );

    $self->set( 'offset', { x => $offset_x, y => $offset_y } );
    return;
}

sub get_offset {
    my ($self) = @_;
    return $self->get('offset');
}

# Draw text on the canvas with a box around it

sub boxed_text {
    my ( $root, $box, $transformation, $edit_callback ) = @_;
    my ( $rotation, $x0, $y0 ) = @{$transformation};
    my ( $x1, $y1, $x2, $y2 ) = @{ $box->{bbox} };
    my $x_size = abs $x2 - $x1;
    my $y_size = abs $y2 - $y1;
    my $g      = GooCanvas2::CanvasGroup->new( parent => $root );
    $g->translate( $x1 - $x0, $y1 - $y0 );
    my $textangle = $box->{textangle} || 0;

    # add box properties to group properties
    map { $g->{$_} = $box->{$_}; } keys %{$box};

    # draw the rect first to make sure the text goes on top
    # and receives any mouse clicks
    my $confidence =
      defined $box->{confidence} ? $box->{confidence} : $_100_PERCENT;
    $confidence = $confidence > 64    ## no critic (ProhibitMagicNumbers)
      ? 2 * int( ( $confidence - 65 ) / 12 ) ## no critic (ProhibitMagicNumbers)
      + 10                                   ## no critic (ProhibitMagicNumbers)
      : 0;
    my $color = defined $box->{confidence}
      ? sprintf(
        '#%xfff%xfff%xfff',
        0xf - int( $confidence / 10 ),       ## no critic (ProhibitMagicNumbers)
        $confidence, $confidence
      )
      : '#7fff7fff7fff';
    my $rect = GooCanvas2::CanvasRect->new(
        parent         => $g,
        x              => 0,
        y              => 0,
        width          => $x_size,
        height         => $y_size,
        'stroke-color' => $color,
        'line-width'   => ( $box->{text} ? 2 : 1 )
    );

    # show text baseline (currently of no use)
    #if ( $box->{baseline} ) {
    #    my ( $slope, $offs ) = @{ $box->{baseline} }[-2,-1];
    #    # "real" baseline with slope
    #    $rect = GooCanvas2::CanvasPolyline->new_line( $g,
    #        0, $y_size + $offs, $x_size, $y_size + $offs + $x_size * $slope,
    #        'stroke-color' => 'green' );
    #    # virtual, horizontally aligned baseline
    #    my $y_offs = $y_size + $offs + 0.5 * $x_size * $slope;
    #    $rect = GooCanvas2::CanvasPolyline->new_line( $g,
    #        0, $y_offs, $x_size, $y_offs,
    #        'stroke-color' => 'orange' );
    #}

    if ( $box->{text} ) {

        # create text and then scale, shift & rotate it into the bounding box
        my $text = GooCanvas2::CanvasText->new(
            parent => $g,
            text   => $box->{text},
            x      => ( $x_size / 2 ),
            y      => ( $y_size / 2 ),
            width  => -1,
            anchor => 'center',
            'font' => 'Sans'
        );
        my $angle  = -( $textangle + $rotation ) % $_360_DEGREES;
        my $bounds = $text->get_bounds;
        my $scale =
          ( $angle ? $y_size : $x_size ) / ( $bounds->x2 - $bounds->x1 );

        # gocr case: gocr creates text only which we treat as page text
        if ( $box->{type} eq 'page' ) {
            $scale *= $FULLPAGE_OCR_SCALE;
        }

        _transform_text( $g, $text, $scale, $angle );

        # clicking text box produces a dialog to edit the text
        if ($edit_callback) {
            $text->signal_connect( 'button-press-event' =>
                  sub { $root->get_parent->{dragging} = FALSE } );
            $text->signal_connect( 'button-press-event' => $edit_callback );
        }
    }
    if ( $box->{contents} ) {
        for my $box ( @{ $box->{contents} } ) {
            boxed_text( $g, $box, [ $textangle + $rotation, $x1, $y1 ],
                $edit_callback );
        }
    }

    # $rect->signal_connect(
    #  'button-press-event' => sub {
    #   my ( $widget, $target, $ev ) = @_;
    #   print "rect button-press-event\n";
    #   #  return TRUE;
    #  }
    # );
    # $g->signal_connect(
    #  'button-press-event' => sub {
    #   my ( $widget, $target, $ev ) = @_;
    #   print "group $widget button-press-event\n";
    #   my $n = $widget->get_n_children;
    #   for ( my $i = 0 ; $i < $n ; $i++ ) {
    #    my $item = $widget->get_child($i);
    #    if ( $item->isa('GooCanvas2::CanvasText') ) {
    #     print "contains $item\n", $item->get('text'), "\n";
    #     last;
    #    }
    #   }
    #   #  return TRUE;
    #  }
    # );
    return;
}

# Set the text in the given widget

sub set_box_text {
    my ( $self, $widget, $text ) = @_;

    # per above: group = text's parent, group's 1st child = rect
    my $g    = $widget->get_property('parent');
    my $rect = $g->get_child(0);
    if ( length $text ) {
        $widget->set( text => $text );
        $g->{text}       = $text;
        $g->{confidence} = $_100_PERCENT;

        # color for 100% confidence
        $rect->set_property( 'stroke-color' => '#efffefffefff' );

        # re-adjust text size & position
        if ( $g->{type} ne 'page' ) {
            my ( $x1, $y1, $x2, $y2 ) = @{ $g->{bbox} };
            my $x_size = abs $x2 - $x1;
            my $y_size = abs $y2 - $y1;
            $widget->set_simple_transform( 0, 0, 1, 0 );
            my $bounds = $widget->get_bounds;
            my $angle = $g->{_angle} || 0;
            my $scale =
              ( $angle ? $y_size : $x_size ) / ( $bounds->x2 - $bounds->x1 );

            _transform_text( $g, $widget, $scale, $angle );
        }
    }
    else {
        delete $g->{text};
        $g->remove_child(0);
        $g->remove_child(1);
    }
    return;
}

# scale, rotate & shift text

sub _transform_text {
    my ( $g, $text, $scale, $angle ) = @_;
    $angle ||= 0;

    if ( $g->{bbox} && $g->{text} ) {
        my ( $x1, $y1, $x2, $y2 ) = @{ $g->{bbox} };
        my $x_size = abs $x2 - $x1;
        my $y_size = abs $y2 - $y1;
        $g->{_angle} = $angle;
        $text->set_simple_transform( 0, 0, $scale, $angle );
        my $bounds   = $text->get_bounds;
        my $x_offset = ( $x1 + $x2 - $bounds->x1 - $bounds->x2 ) / 2;
        my $y_offset = ( $y1 + $y2 - $bounds->y1 - $bounds->y2 ) / 2;
        $text->set_simple_transform( $x_offset, $y_offset, $scale, $angle );
    }
    return;
}

# Convert the canvas into hocr

sub hocr {
    my ($self) = @_;
    if ( not defined $self->get_pixbuf_size ) { return }
    my ( $x, $y, $w, $h ) = $self->get_bounds;
    my $root = $self->get_root_item;
    my $string = _group2hocr( $root, 2 );
    return <<"EOS";
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
 "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
 <head>
  <meta http-equiv="Content-Type" content="text/html;charset=utf-8" />
  <meta name='ocr-system' content='gscan2pdf $Gscan2pdf::Canvas::VERSION' />
  <meta name='ocr-capabilities' content='ocr_page ocr_carea ocr_par ocr_line ocr_word'/>
 </head>
 <body>
$string
 </body>
</html>
EOS
}

sub _group2hocr {
    my ( $parent, $indent ) = @_;
    my $string = $EMPTY;

    for my $i ( 0 .. $parent->get_n_children - 1 ) {
        my $group = $parent->get_child($i);

        if ( ref($group) eq 'GooCanvas2::CanvasGroup' ) {

            # try to preserve as much information as possible
            if ( $group->{bbox} and $group->{type} ) {

                # determine hOCR element types & mapping to HTML tags
                my $type = 'ocr_' . $group->{type};
                my $tag  = 'span';
                given ( $group->{type} ) {
                    when ('page') {
                        $tag = 'div';
                    }
                    when (/^(?:carea|column)$/xsm) {
                        $type = 'ocr_carea';
                        $tag  = 'div';
                    }
                    when ('para') {
                        $type = 'ocr_par';
                        $tag  = 'p';
                    }
                }

                # build properties of hOCR elements
                my $id = $group->{id} ? "id='$group->{id}'" : $EMPTY;
                my $title =
                    'title=' . q{'} . 'bbox '
                  . join( $SPACE, @{ $group->{bbox} } )
                  . (
                      $group->{textangle} ? '; textangle ' . $group->{textangle}
                    : $EMPTY
                  )
                  . (
                    $group->{baseline}
                    ? '; baseline ' . join( $SPACE, @{ $group->{baseline} } )
                    : $EMPTY
                  )
                  . (
                      $group->{confidence} ? '; x_wconf ' . $group->{confidence}
                    : $EMPTY
                  ) . q{'};

                # append to output (recurse to nested levels)
                if ( $string ne $EMPTY ) { $string .= "\n" }
                $string .=
                    $SPACE x $indent
                  . "<$tag class='$type' "
                  . join( $SPACE, $id, $title ) . '>'
                  . (
                    $group->{text}
                    ? HTML::Entities::encode( $group->{text}, "<>&\"'" )
                    : "\n"
                      . _group2hocr( $group, $indent + 1 ) . "\n"
                      . $SPACE x $indent
                  ) . "</$tag>";
            }
        }
    }
    return $string;
}

# convert x, y in widget distance to image distance
sub _to_image_distance {
    my ( $self, $x, $y ) = @_;
    my $zoom = $self->get_scale;
    return $x / $zoom, $y / $zoom;
}

# set zoom with centre in image coordinates
sub _set_zoom_with_center {
    my ( $self, $zoom, $center_x, $center_y ) = @_;
    my $allocation = $self->get_allocation;
    my $offset_x   = $allocation->{width} / 2 / $zoom - $center_x;
    my $offset_y   = $allocation->{height} / 2 / $zoom - $center_y;
    $self->set_scale($zoom);
    $self->signal_emit( 'zoom-changed', $zoom );
    $self->set_offset( $offset_x, $offset_y );
    return;
}

sub _clamp_direction {
    my ( $offset, $allocation, $pixbuf_size ) = @_;

    # Centre the image if it is smaller than the widget
    if ( $allocation > $pixbuf_size ) {
        $offset = ( $allocation - $pixbuf_size ) / 2;
    }

    # Otherwise don't allow the LH/top edge of the image to be visible
    elsif ( $offset > 0 ) {
        $offset = 0;
    }

    # Otherwise don't allow the RH/bottom edge of the image to be visible
    elsif ( $offset < $allocation - $pixbuf_size ) {
        $offset = $allocation - $pixbuf_size;
    }
    return $offset;
}

sub _button_pressed {
    my ( $self, $event ) = @_;

    # left mouse button
    if ( $event->button != 1 ) { return FALSE }

    $self->{drag_start} = { x => $event->x, y => $event->y };
    $self->{dragging} = TRUE;

    #    $self->update_cursor( $event->x, $event->y );

    # allow the event to propagate in case the user was clicking on text to edit
    return;
}

sub _button_released {
    my ( $self, $event ) = @_;
    $self->{dragging} = FALSE;

    #    $self->update_cursor( $event->x, $event->y );
    return;
}

sub _motion {
    my ( $self, $event ) = @_;
    if ( not $self->{dragging} ) { return FALSE }

    my $offset = $self->get_offset;
    my $zoom   = $self->get_scale;
    my $offset_x =
      $offset->{x} + ( $event->x - $self->{drag_start}{x} ) / $zoom;
    my $offset_y =
      $offset->{y} + ( $event->y - $self->{drag_start}{y} ) / $zoom;
    ( $self->{drag_start}{x}, $self->{drag_start}{y} ) =
      ( $event->x, $event->y );
    $self->set_offset( $offset_x, $offset_y );
    return;
}

sub _scroll {
    my ( $self, $event ) = @_;
    my ( $center_x, $center_y ) =
      $self->convert_from_pixels( $event->x, $event->y );

    my $zoom;
    if ( $event->direction eq 'up' ) {
        $zoom = $self->get_scale * 2;
    }
    else {
        $zoom = $self->get_scale / 2;
    }
    $self->_set_zoom_with_center( $zoom, $center_x, $center_y );

    # don't allow the event to propagate, as this pans it in y
    return TRUE;
}

1;

__END__
