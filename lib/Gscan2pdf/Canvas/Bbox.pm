package Gscan2pdf::Canvas::Bbox;

use strict;
use warnings;
use feature 'switch';
no if $] >= 5.018, warnings => 'experimental::smartmatch';
use GooCanvas2;
use Glib ':constants';
use HTML::Entities;
use Carp;
use POSIX qw/ceil/;
use Readonly;
Readonly my $FULLPAGE_OCR_SCALE => 0.8;
Readonly my $MAX_COLOR_INT      => 65_535;
Readonly my $COLOR_GREEN        => 2;
Readonly my $COLOR_CYAN         => 3;
Readonly my $COLOR_BLUE         => 4;
Readonly my $_60_DEGREES        => 60;

my ( $EMPTY, $_100_PERCENT, $_360_DEGREES );

BEGIN {
    Readonly $_100_PERCENT => 100;
    Readonly $_360_DEGREES => 360;
    $EMPTY = q{};
}
my $SPACE = q{ };
our $VERSION = '2.9.0';

use Glib::Object::Subclass GooCanvas2::CanvasGroup::, signals => {
    'text-changed' => {
        param_types => ['Glib::String'],    # new text
    },
    'bbox-changed' => {
        param_types => ['Glib::Scalar']
        ,    # new bbox, Gdk::Rectangle hash of x, y, width, height
    },
    'clicked' => {},
  },
  properties => [
    Glib::ParamSpec->string(
        'text',                  # name
        'Text',                  # nick
        'String of box text',    # blurb
        $EMPTY,                  # default
        G_PARAM_READWRITE,       # flags
    ),
    Glib::ParamSpec->scalar(
        'bbox',                                          # name
        'Bounding box',                                  # nick
        'Gdk::Rectangle hash of x, y, width, height',    # blurb
        G_PARAM_READWRITE,                               # flags
    ),
    Glib::ParamSpec->scalar(
        'transformation',                                # name
        'Transformation',                                # nick
        'Hash of angle, x, y',                           # blurb
        G_PARAM_READWRITE,                               # flags
    ),
    Glib::ParamSpec->int(
        'confidence',                                    # name
        'Confidence',                                    # nick
        'Confidence of bbox',                            # blurb
        0,                                               # min
        $_100_PERCENT,                                   # max
        $_100_PERCENT,                                   # default
        G_PARAM_READWRITE,                               # flags
    ),
    Glib::ParamSpec->int(
        'textangle',                                     # name
        'Text angle',                                    # nick
        'Angle of text in bbox',                         # blurb
        -$_360_DEGREES,                                  # min
        $_360_DEGREES,                                   # max
        0,                                               # default
        G_PARAM_READWRITE,                               # flags
    ),
    Glib::ParamSpec->string(
        'type',                                          # name
        'Type',                                          # nick
        'Type of box',                                   # blurb
        'word',                                          # default
        G_PARAM_READWRITE,                               # flags
    ),
    Glib::ParamSpec->string(
        'id',                                            # name
        'ID',                                            # nick
        'ID of box as given by OCR engine',              # blurb
        $EMPTY,                                          # default
        G_PARAM_READWRITE,                               # flags
    ),
    Glib::ParamSpec->scalar(
        'baseline',                                      # name
        'Baseline',                                      # nick
        'Baseline of box as given by OCR engine',        # blurb
        G_PARAM_READWRITE,                               # flags
    ),
  ];

sub new {
    my ( $class, %options ) = @_;
    my $self = Glib::Object::new( $class, %options );

    my ( $rotation, $x0, $y0 ) = @{ $self->{transformation} };

    my ( $x, $y, $width, $height ) = (
        $self->{bbox}{x},     $self->{bbox}{y},
        $self->{bbox}{width}, $self->{bbox}{height},
    );
    $self->translate( $x - $x0, $y - $y0 );
    my $textangle = $self->get('textangle');
    my $color     = $self->confidence2color;

    # draw the rect first to make sure the text goes on top
    # and receives any mouse clicks
    my $rect = GooCanvas2::CanvasRect->new(
        parent         => $self,
        x              => 0,
        y              => 0,
        width          => $width,
        height         => $height,
        'stroke-color' => $color,
        'line-width'   => ( $self->{text} ? 2 : 1 )
    );

    # show text baseline (currently of no use)
    #if ( $box->{baseline} ) {
    #    my ( $slope, $offs ) = @{ $box->{baseline} }[-2,-1];
    #    # "real" baseline with slope
    #    $rect = GooCanvas2::CanvasPolyline->new_line( $g,
    #        0, $height + $offs, $width, $height + $offs + $width * $slope,
    #        'stroke-color' => 'green' );
    #    # virtual, horizontally aligned baseline
    #    my $y_offs = $height + $offs + 0.5 * $width * $slope;
    #    $rect = GooCanvas2::CanvasPolyline->new_line( $g,
    #        0, $y_offs, $width, $y_offs,
    #        'stroke-color' => 'orange' );
    #}

    if ( $self->{text} ) {

        # create text and then scale, shift & rotate it into the bounding box
        my $text = GooCanvas2::CanvasText->new(
            parent       => $self,
            text         => $self->{text},
            x            => ( $width / 2 ),
            y            => ( $height / 2 ),
            width        => -1,
            anchor       => 'center',
            'font'       => 'Sans',
            'fill-color' => $color,
        );
        my $angle  = -( $textangle + $rotation ) % $_360_DEGREES;
        my $bounds = $text->get_bounds;
        if ( ( $bounds->x2 - $bounds->x1 ) == 0 ) {
            Glib->warning( __PACKAGE__, "text $text has no width, skipping" );
            return;
        }
        my $scale =
          ( $angle ? $height : $width ) / ( $bounds->x2 - $bounds->x1 );

        # gocr case: gocr creates text only which we treat as page text
        if ( $self->get('type') eq 'page' ) {
            $scale *= $FULLPAGE_OCR_SCALE;
        }

        $self->transform_text( $scale, $angle );
    }

    return $self;
}

# Convert confidence percentage into colour
# Any confidence level greater than max_conf is treated as max_conf and given
# max_color. Any confidence level less than min_conf is treated as min_conf and
# given min_color. Anything inbetween is appropriately interpolated in HSV space.

sub confidence2color {
    my ($self)     = @_;
    my $confidence = $self->get('confidence');
    my $canvas     = $self->get_canvas;
    my $max_conf   = $canvas->get('max-confidence');
    if ( $confidence >= $max_conf ) {
        return $canvas->get('max-color');
    }
    my $min_conf = $canvas->get('min-confidence');
    if ( $confidence <= $min_conf ) {
        return $canvas->get('min-color');
    }
    my %max_hsv = %{ $canvas->get_max_color_hsv };
    my %min_hsv = %{ $canvas->get_min_color_hsv };
    my $m       = ( $confidence - $min_conf ) / ( $max_conf - $min_conf );
    my %hsv;
    ( $hsv{h}, $hsv{s}, $hsv{v}, ) = (
        linear_interpolation( $min_hsv{h}, $max_hsv{h}, $m ),
        linear_interpolation( $min_hsv{s}, $max_hsv{s}, $m ),
        linear_interpolation( $min_hsv{v}, $max_hsv{v}, $m ),
    );
    my %rgb = hsv2rgb(%hsv);
    return sprintf '#%04x%04x%04x', $rgb{r}, $rgb{g}, $rgb{b};
}

sub linear_interpolation {
    my ( $x1, $x2, $m ) = @_;
    return $x1 * ( 1 - $m ) + $x2 * $m;
}

sub hsv2rgb {
    my (%in) = @_;

    my %out;
    if ( $in{s} <= 0.0 ) {    # < is bogus, just shuts up warnings
        $out{r} = $in{v};
        $out{g} = $in{v};
        $out{b} = $in{v};
        return %out;
    }
    my $hh = $in{h};
    if ( $hh >= $_360_DEGREES ) { $hh = 0.0 }
    $hh /= $_60_DEGREES;
    my $i  = $hh;
    my $ff = $hh - $i;
    my $p  = $in{v} * ( 1.0 - $in{s} );
    my $q  = $in{v} * ( 1.0 - ( $in{s} * $ff ) );
    my $t  = $in{v} * ( 1.0 - ( $in{s} * ( 1.0 - $ff ) ) );

    given ($i) {
        when (0) {
            $out{r} = $in{v};
            $out{g} = $t;
            $out{b} = $p;
        }
        when (1) {
            $out{r} = $q;
            $out{g} = $in{v};
            $out{b} = $p;
        }
        when ($COLOR_GREEN) {
            $out{r} = $p;
            $out{g} = $in{v};
            $out{b} = $t;
        }
        when ($COLOR_CYAN) {
            $out{r} = $p;
            $out{g} = $q;
            $out{b} = $in{v};
        }
        when ($COLOR_BLUE) {
            $out{r} = $t;
            $out{g} = $p;
            $out{b} = $in{v};
        }
        default {
            $out{r} = $in{v};
            $out{g} = $p;
            $out{b} = $q;
        }
    }
    ( $out{r}, $out{g}, $out{b}, ) = (
        $out{r} * $MAX_COLOR_INT,
        $out{g} * $MAX_COLOR_INT,
        $out{b} * $MAX_COLOR_INT,
    );
    return %out;
}

sub get_box_widget {
    my ($self) = @_;
    return $self->get_child(0);
}

sub get_text_widget {
    my ($self) = @_;
    my $child = $self->get_child(1);
    if ( $child->isa('GooCanvas2::CanvasText') ) {
        return $child;
    }
    return;
}

sub get_children {
    my ($self) = @_;
    my @children;
    for my $i ( 0 .. $self->get_n_children - 1 ) {
        my $child = $self->get_child($i);
        if ( $child->isa('Gscan2pdf::Canvas::Bbox') ) {
            push @children, $child;
        }
    }
    return @children;
}

sub walk_children {
    my ( $self, $callback ) = @_;
    for my $child ( $self->get_children ) {
        if ( defined $callback ) {
            $callback->($child);
            $child->walk_children($callback);
        }
    }
    return;
}

# scale, rotate & shift text

sub transform_text {
    my ( $self, $scale, $angle ) = @_;
    my $text_widget = $self->get_text_widget;
    my $bbox        = $self->get('bbox');
    my $text        = $self->get('text');
    $angle ||= 0;

    if ( $bbox && $text ) {
        my ( $x, $y, $width, $height ) =
          ( $bbox->{x}, $bbox->{y}, $bbox->{width}, $bbox->{height} );
        my ( $x2, $y2 ) = ( $x + $width, $y + $height );
        $text_widget->set_simple_transform( 0, 0, $scale, $angle );
        my $bounds   = $text_widget->get_bounds;
        my $x_offset = ( $x + $x2 - $bounds->x1 - $bounds->x2 ) / 2;
        my $y_offset = ( $y + $y2 - $bounds->y1 - $bounds->y2 ) / 2;
        $text_widget->set_simple_transform( $x_offset, $y_offset, $scale,
            $angle );
    }
    return;
}

# Set the text in the given widget

sub update_box {
    my ( $self, $text, $selection ) = @_;

    my $rect_w = $self->get_box_widget;
    $rect_w->set_property(
        'stroke-color' => 'black',
        width          => $selection->{width},
        height         => $selection->{height},
    );

    my $old_box = $self->get('bbox');
    $self->translate( $selection->{x} - $old_box->{x},
        $selection->{y} - $old_box->{y} );

    my $text_w = $self->get_text_widget;
    if ( length $text ) {
        $text_w->set( text => $text );
        $self->set( text       => $text );
        $self->set( confidence => $_100_PERCENT );

        # colour for 100% confidence
        $text_w->set_property( 'fill-color' => 'black' );

        # re-adjust text size & position
        if ( $self->get('type') ne 'page' ) {
            $self->set( bbox => $selection );
            $text_w->set_simple_transform( 0, 0, 1, 0 );
            my $bounds    = $text_w->get_bounds;
            my $textangle = $self->get('textangle');
            my $scale =
              ( $textangle ? $selection->{height} : $selection->{width} ) /
              ( $bounds->x2 - $bounds->x1 );

            $self->transform_text( $scale, $textangle );
        }

        my $canvas = $self->get_canvas;
        $canvas->remove_current_box_from_index;
        $canvas->add_box_to_index($self);
    }
    else {
        $self->delete_box;
    }
    return;
}

sub delete_box {
    my ($self) = @_;
    $self->get_canvas->remove_current_box_from_index;
    my $parent = $self->get_property('parent');
    for my $i ( 0 .. $parent->get_n_children - 1 ) {
        my $group = $parent->get_child($i);
        if ( $group eq $self ) {
            $parent->remove_child($i);
            last;
        }
    }
    Glib->message( __PACKAGE__,
        "deleted box $self->{text} at $self->{bbox}{x}, $self->{bbox}{y}" );
    return;
}

sub recthash2bboxarray {
    my ($rect) = @_;
    return [
        int $rect->{x},
        int $rect->{y},
        int( $rect->{x} + $rect->{width} ),
        int( $rect->{y} + $rect->{height} )
    ];
}

sub to_hocr {
    my ( $self, $indent ) = @_;
    my $string = $EMPTY;

    # try to preserve as much information as possible
    if ( $self->{bbox} and $self->{type} ) {

        # determine hOCR element types & mapping to HTML tags
        my $type = 'ocr_' . $self->{type};
        my $tag  = 'span';
        given ( $self->{type} ) {
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
        my $id = $self->{id} ? "id='$self->{id}'" : $EMPTY;
        my $title =
            'title=' . q{'} . 'bbox '
          . join( $SPACE, @{ recthash2bboxarray( $self->{bbox} ) } )
          . (
              $self->{textangle} ? '; textangle ' . $self->{textangle}
            : $EMPTY
          )
          . (
            $self->{baseline}
            ? '; baseline ' . join( $SPACE, @{ $self->{baseline} } )
            : $EMPTY
          )
          . (
              $self->{confidence} ? '; x_wconf ' . $self->{confidence}
            : $EMPTY
          ) . q{'};

        # append to output (recurse to nested levels)
        if ( $string ne $EMPTY ) { $string .= "\n" }
        $string .=
            $SPACE x $indent
          . "<$tag class='$type' "
          . join( $SPACE, $id, $title ) . '>'
          . (
            $self->{text}
            ? HTML::Entities::encode( $self->{text}, "<>&\"'" )
            : "\n"
          );

        my $childstr = $EMPTY;
        for my $bbox ( $self->get_children ) {
            $childstr .= $bbox->to_hocr( $indent + 1 );
        }
        if ( $childstr ne $EMPTY ) {
            $childstr .= $SPACE x $indent;
        }
        $string .= $childstr . "</$tag>\n";
    }
    return $string;
}

1;

__END__
