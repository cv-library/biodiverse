package Biodiverse::GUI::Dendrogram;

use strict;
use warnings;
no warnings 'recursion';
use Data::Dumper;
use Carp;

use Time::HiRes qw /gettimeofday time/;

use Scalar::Util qw /weaken/;
use Tie::RefHash;

use Gtk2;
use Gnome2::Canvas;
use POSIX; # for ceil()

our $VERSION = '0.16';

use Scalar::Util qw /blessed/;

use Biodiverse::GUI::GUIManager;
use Biodiverse::TreeNode;

##########################################################
# Rendering constants
##########################################################
use constant BORDER_FRACTION => 0.05; # how much of total-length are the left/right borders (combined!)
use constant SLIDER_WIDTH => 3; # pixels
use constant LEAF_SPACING => 1; # arbitrary scale (length will be scaled to fit)

use constant HIGHLIGHT_WIDTH => 2; # width of highlighted horizontal lines (pixels)
use constant NORMAL_WIDTH => 1;       # width of normal lines (pixels)

use constant COLOUR_BLACK => Gtk2::Gdk::Color->new(0,0,0);
use constant COLOUR_WHITE => Gtk2::Gdk::Color->new(255*257, 255*257, 255*257);
use constant COLOUR_GRAY => Gtk2::Gdk::Color->new(210*257, 210*257, 210*257);
use constant COLOUR_RED => Gtk2::Gdk::Color->new(255*257,0,0);

use constant COLOUR_PALETTE_OVERFLOW => COLOUR_WHITE;
use constant COLOUR_OUTSIDE_SELECTION => COLOUR_WHITE;
use constant COLOUR_NOT_IN_TREE => COLOUR_BLACK;
use constant COLOUR_LIST_UNDEF => COLOUR_BLACK;

use constant DEFAULT_LINE_COLOUR => COLOUR_BLACK;
use constant DEFAULT_LINE_COLOUR_RGB => "#000000";

use constant HOVER_CURSOR => 'hand2';
##########################################################
# Construction
##########################################################

sub new {
    my $class           = shift;
    my $mainFrame       = shift;    # GTK frame to add dendrogram
    my $graphFrame      = shift;    # GTK frame for the graph (below!)
    my $hscroll         = shift;
    my $vscroll         = shift;
    my $map             = shift;    # Grid.pm object of the dataset to link in
    my $map_list_combo  = shift;    # Combo for selecting how to colour the grid (based on spatial result or cluster)
    my $map_index_combo = shift;    # Combo for selecting how to colour the grid (which spatial result)

    my $self = {
        map                 => $map,
        map_index_combo     => $map_index_combo,
        map_list_combo      => $map_list_combo,
        num_clusters        => 6,
        zoom_fit            => 1,
        dragging            => 0,
        sliding             => 0,
        unscaled_slider_x   => 0,
        group_mode          => 'length',
        width_px            => 0,
        height_px           => 0,
        render_width        => 0,
        render_height       => 0,
        graph_height_px     => 0,
        use_slider_to_select_nodes => 1,
    };

    $self->{hover_func}         = shift || undef; #Callback function for when users move mouse over a cell
    $self->{highlight_func}     = shift || undef; #Callback function to highlight elements
    $self->{use_highlight_func} = 1;  #  should we highlight?
    $self->{ctrl_click_func}    = shift || undef; #Callback function for when users control-click on a cell
    $self->{click_func}         = shift || undef; #Callback function for when users click on a cell

     # starting off with the "clustering" view, not a spatial analysis
    $self->{sp_list}  = undef;
    $self->{sp_index} = undef; 
    bless $self, $class;

    # Make and hook up the canvases
    $self->{canvas} = Gnome2::Canvas->new();
    $self->{graph}  = Gnome2::Canvas->new();
    $mainFrame->add( $self->{canvas} );
    $graphFrame->add( $self->{graph} );
    $self->{canvas}->signal_connect_swapped (
        size_allocate => \&onResize,
        $self,
    );
    $self->{graph}->signal_connect_swapped(
        size_allocate => \&onGraphResize,
        $self,
    );

    # Set up custom scrollbars due to flicker problems whilst panning..
    $self->{hadjust} = Gtk2::Adjustment->new(0, 0, 1, 1, 1, 1);
    $self->{vadjust} = Gtk2::Adjustment->new(0, 0, 1, 1, 1, 1);

    $hscroll->set_adjustment( $self->{hadjust} );
    $vscroll->set_adjustment( $self->{vadjust} );

    $self->{hadjust}->signal_connect_swapped('value-changed', \&onHScroll, $self);
    $self->{vadjust}->signal_connect_swapped('value-changed', \&onVScroll, $self);

    # Set up canvas
    $self->{canvas}->set_center_scroll_region(0);
    $self->{canvas}->show;
    $self->{graph}->set_center_scroll_region(0);
    $self->{graph}->show;

    $self->{length_scale} = 1;
    $self->{height_scale} = 1;

    # Create background rectange to receive mouse events for panning
    my $rect = Gnome2::Canvas::Item->new (
        $self->{canvas}->root,
        'Gnome2::Canvas::Rect',
        x1 => 0,
        y1 => 0,
        x2 => 1,
        y2 => 1,
        fill_color_gdk => COLOUR_WHITE
        #fill_color => "blue",
    );

    $rect->lower_to_bottom();
    $self->{canvas}->root->signal_connect_swapped (event => \&onBackgroundEvent, $self);
    $self->{back_rect} = $rect;

    # Process changes for the map
    if ($map_index_combo) {
        $map_index_combo->signal_connect_swapped(
            changed => \&onMapIndexComboChanged,
            $self,
        );
    }
    if ($map_list_combo) {
        $map_list_combo->signal_connect_swapped (
            changed => \&onMapListComboChanged,
            $self
        );
    }

    return $self;
}

#  
#sub DESTROY {
#    my $self = shift;
#    
#    no warnings "uninitialized";
#    
#    warn "[Dendrogram] Starting object cleanup\n";
#    
#    foreach my $key (keys %$self) {
#        if ((ref $self->{$key}) =~ '::') {
#            warn "Deleting $key - $self->{$key}\n";
#            $self->{$key} -> DESTROY if $self->{$key} -> can ('DESTROY');
#        }
#        delete $self->{$key};
#    }
#    $self = undef;
#    
#    warn "[Dendrogram] Completed object cleanup\n";
#}

sub destroy {
    my $self = shift;

    print "[Dendrogram] Trying to clean up references\n";

    $self->{node_lines} = undef;
    delete $self->{node_lines};

    if ($self->{lines_group}) {
        $self->{lines_group}->destroy();
    }

    delete $self->{slider};

    delete $self->{hover_func}; #??? not sure if helps
    delete $self->{highlight_func}; #??? not sure if helps
    delete $self->{ctrl_click_func}; #??? not sure if helps
    delete $self->{click_func}; #??? not sure if helps

    delete $self->{lines_group}; #!!!! Without this, GnomeCanvas __crashes__
                                # Apparently, a reference cycle prevents it from being destroyed properly,
                                # and a bug makes it repaint in a half-dead state
    delete $self->{back_rect};

    #delete $self->{node_lines};
    delete $self->{canvas};
    delete $self->{graph};

    return;
}

##########################################################
# The Slider
##########################################################

sub makeSlider {
    my $self = shift;

    # already exists?
    if ( $self->{slider} ) {
        $self->{slider}->show;
        $self->{graph_slider}->show;
        return;
    }

    $self->{slider} = Gnome2::Canvas::Item->new (
        $self->{canvas}->root,
        'Gnome2::Canvas::Rect',
        x1 => 0,
        y1 => 0,
        x2 => 1,
        y2 => 1,
        fill_color => 'blue',
    );
    $self->{slider}->signal_connect_swapped (event => \&onSliderEvent, $self);

    # Slider for the graph at the bottom
    $self->{graph_slider} = Gnome2::Canvas::Item->new (
        $self->{graph}->root,
        'Gnome2::Canvas::Rect',
        x1 => 0,
        y1 => 0,
        x2 => 1,
        y2 => 1,
        fill_color => 'blue',
    );
    $self->{graph_slider}->signal_connect_swapped (event => \&onSliderEvent, $self);

    # Make the #Clusters textbox
    $self->{clusters_group} = Gnome2::Canvas::Item->new (
        $self->{canvas}->root,
        'Gnome2::Canvas::Group',
        x => 0,
        y => 0,
    );
    $self->{clusters_group}->lower_to_bottom();

    $self->{clusters_rect} = Gnome2::Canvas::Item->new (
        $self->{clusters_group},
        'Gnome2::Canvas::Rect',
        x1 => 0,
        y1 => 0,
        x2 => 0,
        y2 =>0,
        'fill-color' => 'blue',
    );

    $self->{clusters_text} = Gnome2::Canvas::Item->new (
        $self->{clusters_group},
        'Gnome2::Canvas::Text',
        x => 0,
        y => 0,
        anchor => 'nw',
        fill_color_gdk => COLOUR_WHITE,
    );

    return;
}

# Resize slider (after zooming)
sub repositionSliders {
    my $self = shift;

    my $xoffset = $self->{centre_x} * $self->{length_scale} - $self->{width_px} / 2;
    my $slider_x = ($self->{unscaled_slider_x} * $self->{length_scale}) - $xoffset;

    #print "[repositionSliders] centre_x=$self->{centre_x} length_scale=$self->{length_scale} unscaled_slider_x=$self->{unscaled_slider_x} width_px=$self->{width_px} slider_x=$slider_x\n";

    $self->{slider}->set(
        x1 => $slider_x,
        x2 => $slider_x + SLIDER_WIDTH,
        y2 => $self->{render_height},
    );

    $self->{graph_slider}->set(
        x1 => $slider_x,
        x2 => $slider_x + SLIDER_WIDTH,
        y2 => $self->{graph_height_units},
    );

    $self->repositionClustersTextbox($slider_x);

    return;
}

sub repositionClustersTextbox {
    my $self = shift;
    my $slider_x = shift;

    # Adjust backing rectangle to fit over the text
    my ($w, $h) = $self->{clusters_text}->get('text-width', 'text-height');

    if ($slider_x + $w >= $self->{render_width}) { 
        # Move textbox to the left of the slider
        $self->{clusters_rect}->set(x1 => -1 * $w, y2 => $h);
        $self->{clusters_text}->set(anchor => 'ne');
    }
    else {
        # Textbox to the right of the slider
        $self->{clusters_rect}->set(x1 => $w, y2 => $h);
        $self->{clusters_text}->set(anchor => 'nw');
    }

    return;
}

sub onSliderEvent {
    my ($self, $event, $item) = @_;

    if ($event->type eq 'enter-notify') {

        #print "Slider - enter\n";
        # Show #clusters
        $self->{clusters_group}->show;

        # Change the cursor
        my $cursor = Gtk2::Gdk::Cursor->new('sb-h-double-arrow');
        $self->{canvas}->window->set_cursor($cursor);
        $self->{graph}->window->set_cursor($cursor);

    }
    elsif ($event->type eq 'leave-notify') {

        #print "Slider - leave\n";
        # hide #clusters
        $self->{clusters_group}->hide;

        # Change cursor back to default
        $self->{canvas}->window->set_cursor(undef);
        $self->{graph}->window->set_cursor(undef);

    }
    elsif ( $event->type eq 'button-press') {

        #print "Slider - press\n";
        ($self->{pan_start_x}, $self->{pan_start_y}) = $event->coords;

        # Grab mouse
        $item->grab (
            [qw/pointer-motion-mask button-release-mask/],
            Gtk2::Gdk::Cursor->new ('fleur'),
            $event->time,
        );
        $self->{sliding} = 1;

    }
    elsif ( $event->type eq 'button-release') {

        #print "Slider - release\n";
        $item->ungrab ($event->time);
        $self->{sliding} = 0;

    }
    elsif ( $event->type eq 'motion-notify') {

        if ($self->{sliding}) {
            #print "Slider - slide\n";

            # Sliding..
            my ($x, $y) = $event->coords;

            # Clamp $x
            my $min_x = 0;
            my $max_x = $self->{width_px};

            if ($x < $min_x) {
                $x = $min_x ;
            }
            elsif ($x > $max_x) {
                $x = $max_x;
            }

            # Move slider and related graphics
            my $x2 = $x + SLIDER_WIDTH;
            $self->{slider}->        set(x1 => $x, x2 => $x2);
            $self->{graph_slider}->  set(x1 => $x, x2 => $x2);
            $self->{clusters_group}->set(x => $x2);

            # Calculate how far the slider is length-wise
            my $xoffset = $self->{centre_x}
                          * $self->{length_scale}
                          - $self->{width_px} / 2;

            $self->{unscaled_slider_x} = ($x + $xoffset) / $self->{length_scale};

            #print "[doSliderMove] x=$x pos=$self->{unscaled_slider_x}\n";

            $self->doSliderMove($self->{unscaled_slider_x});

            $self->repositionClustersTextbox($x);

        }
        else {
            #print "Slider - motion\n";
        }
    }

    return 1;    
}

#  should we highlight it or not?
#  by default we switch the setting
sub set_use_highlight_func {
    my $self = shift;
    my $value = shift;
    $value = not $self->{use_highlight_func} if ! defined $value;
    $self->{use_highlight_func} = $value;

    return;
}

##########################################################
# Colouring
##########################################################

sub getNumClusters {
    my $self = shift;
    return $self->{num_clusters} || 1;
}

sub setNumClusters {
    my $self = shift;
    $self->{num_clusters} = shift || 1;
    # apply new setting
    $self->recolour();
    return;
}

# whether to colour by 'length' or 'depth'
sub setGroupMode {
    my $self = shift;
    $self->{group_mode} = shift;
    # apply new setting
    $self->recolour();
    return;
}

sub recolour {
    my $self = shift;
    if ($self->{colour_start_node}) {
        $self->doColourNodesBelow($self->{colour_start_node});
    }
    return;
}

# Gets a hash of nodes which have been coloured
# Used by Spatial tab for getting an element's "cluster" (ie: coloured node that it's under)
#     hash of names (with refs as values)
sub getClusterNodeForElement {
    my $self = shift;
    my $element = shift;
    return $self->{element_to_cluster}{$element};
}

# Returns a list of colours to use for colouring however-many clusters
# returns STRING COLOURS
sub getPalette {
    my $self = shift;
    my $num_clusters = shift;
    #print "Choosing colour palette for $num_clusters clusters\n";

    return (wantarray ? () : []) if $num_clusters <= 0;  # trap bad numclusters

    my @colourset;

    if ($num_clusters <= 9) {
        # Set1 colour scheme from www.colorbrewer.org
        no warnings 'qw';  #  we know the hashes in this list are not comments
        @colourset = qw '#E41A1C #377EB8 #4DAF4A #984EA3
                         #FF7F00 #FFFF33 #A65628 #F781BF
                         #999999';

    }
    elsif ($num_clusters <= 13) {
        # Paired colour scheme from the same place, plus a dark grey
        #  note - this works poorly when 9 or fewer groups are selected
        no warnings 'qw';
        @colourset = qw '#A6CEE3 #1F78B4 #B2DF8A #33A02C
                         #FB9A99 #E31A1C #FDBF6F #FF7F00
                         #CAB2D6 #6A3D9A #FFFF99 #B15928
                         #4B4B4B';

    }
    else {
        # If more than get_palette_max_colours, separate by hue
        # ed: actually don't - adjacent clusters may get wildly different hues
        # because the hashes are randomly sorted...
        #my $hue_slice = 180 / $num_clusters;
        @colourset = (DEFAULT_LINE_COLOUR_RGB) x $num_clusters;  #  saves looping over them all
    }

    my @colours = @colourset[0 .. $num_clusters - 1]; #  return the relevant slice

    return (wantarray ? @colours : \@colours);
}

sub get_palette_max_colours {
    my $self = shift;
    if (blessed ($self)
        and blessed ($self->{cluster})
        and defined $self->{cluster} -> get_param ('MAX_COLOURS')) {

        return $self->{cluster} -> get_param ('MAX_COLOURS');
    }

    return 13;  #  modify if more are added above.
}

# Finds which nodes the slider intersected and selects them for analysis
sub doSliderMove {
    my $self = shift;
    my $length_along = shift;

    #my $time = time();
    #return 1 if defined $self->{last_slide_time} &&
    #    ($time - $self->{last_slide_time}) < 0.2;

    # Find how far along the tree the slider is positioned
    # Saving slider position - to move it back in place after resize
    #print "[doSliderMove] Slider @ $length_along\n";

    # Find nodes that intersect the slides

    my $using_length = 1;
    if ($self->{plot_mode} eq 'length') {
        $length_along -= $self->{border_len};
        #FIXME: putting this fixes position errors, but don't understand how
        $length_along -= $self->{neg_len};
    }
    elsif ($self->{plot_mode} eq 'depth') {
        $length_along -= $self->{border_len};
        $length_along -= $self->{neg_len}; 
        $length_along = $self->{max_len} - $length_along;
        $using_length = 0;
    }
    else {
        croak "invalid plot mode: $self->{plot_mode}\n";
    }

    my $node_hash = $self->{tree_node} -> group_nodes_below (
        target_value => $length_along,
        type         => $self->{plot_mode},
    );

    my @intersecting_nodes = values %$node_hash;

    # Update the slider textbox
    #   [Number of nodes intersecting]
    #   Above as percentage of total elements
    my $num_intersecting = scalar @intersecting_nodes;
    my $percent = sprintf('%.1f', $num_intersecting * 100 / $self->{num_nodes}); # round to 1 d.p.
    my $l_text  = sprintf('%.2f', $length_along);
    my $text = "$num_intersecting nodes\n$percent%\n"
                . ($using_length ? 'L' : 'D')
                . ": $l_text";
    $self->{clusters_text}->set( text => $text );

    # Highlight the lines in the dendrogram
    $self -> clearHighlights;
    foreach my $node (values %$node_hash) {
        $self->highlightNode($node);
    }

    return if ! $self->{use_slider_to_select_nodes};

    # Set up colouring
    $self->assignClusterPaletteColours(\@intersecting_nodes);
    $self->mapElementsToClusters(\@intersecting_nodes);

    $self->recolourClusterElements();
    $self->recolourClusterLines(\@intersecting_nodes);
    $self->setProcessedNodes(\@intersecting_nodes);

    #$self->{last_slide_time} = time;
    return;
}

sub toggle_use_slider_to_select_nodes {
    my $self = shift;

    $self->{use_slider_to_select_nodes} = ! $self->{use_slider_to_select_nodes};

    return;
}

# Colours a certain number of nodes below
sub doColourNodesBelow {
    my $self = shift;
    my $start_node = shift;
    $self->{colour_start_node} = $start_node;

    my $num_clusters = $self -> getNumClusters;
    my $original_num_clusters = $num_clusters;
    my $excess_flag = 0;
    my @colour_nodes;

    if (defined $start_node) {

        # Get list of nodes to colour
        #print "[Dendrogram] Grouping...\n";
        my %node_hash = $start_node -> group_nodes_below (
            num_clusters => $num_clusters,
            type => $self->{group_mode}
        );
        @colour_nodes = values %node_hash;
        #print "[Dendrogram] Done Grouping...\n";

        # FIXME: why loop instead of just grouping with num_clusters => $self->get_palette_max_colours
        #  make sure we don't exceed the maximum number of colours
        while (scalar @colour_nodes > $self -> get_palette_max_colours) {  
            $excess_flag = 1;

            # Group again with 1 fewer colours
            $num_clusters --;
            my %node_hash = $start_node -> group_nodes_below (
                num_clusters => $num_clusters,
                type => $self->{group_mode},
            );
            @colour_nodes = values %node_hash;
        }
        $num_clusters = scalar @colour_nodes;  #not always the same, so make them equal now

        #  keep the user informed of what happened
        if ($original_num_clusters != $num_clusters) {
            print "[Dendrogram] Could not colour requested number of clusters ($original_num_clusters)\n";

            if ($original_num_clusters < $num_clusters) {
                if ($excess_flag) {
                    print "[Dendrogram] More clusters were requested ("
                          . "$original_num_clusters) than available colours ("
                          . $self -> get_palette_max_colours
                          . ")\n";
                }
                else {
                    print "[Dendrogram] Requested number not feasible.  "
                          . "Returned $num_clusters.\n";
                }
            }
            else {
                print "[Dendrogram] Fewer clusters were identified ($num_clusters)\n";
            }
        }
    }
    else {
        print "[Dendrogram] Clearing colouring\n"
    }

    # Set up colouring
    #print "num clusters = $num_clusters\n";
    $self->assignClusterPaletteColours(\@colour_nodes);
    $self->mapElementsToClusters(\@colour_nodes);

    $self->recolourClusterElements();
    $self->recolourClusterLines(\@colour_nodes);
    $self->setProcessedNodes(\@colour_nodes);

    return;
}

# Assigns palette-based colours to selected nodes
sub assignClusterPaletteColours {
    my $self = shift;
    my $cluster_nodes = shift;

    # don't set cluster colours if don't have enough palette values
    if (scalar @$cluster_nodes > $self -> get_palette_max_colours()) {
        #print "[Dendrogram] not assigning palette colours (too many clusters)\n";

        # clear existing values
        foreach my $j (0..$#{$cluster_nodes}) {
            #$cluster_nodes->[$j]->set_cached_value(__gui_palette_colour => undef);
            $self->{node_palette_colours}{$cluster_nodes->[$j] -> get_name} = undef;
        }

    }
    else {

        my @palette = $self->getPalette (scalar @$cluster_nodes);

        # so we sort them to make the colour order consistent
        my %sort_by_firstnode;
        my $i = 0;  #  in case we dont have numbered nodes
        foreach my $node_ref (@$cluster_nodes) {
            my $firstnode = $node_ref -> get_value ('TERMINAL_NODE_FIRST');
            $sort_by_firstnode{$firstnode} = $node_ref;
            $i++;
        }

        my @sorted_clusters = @sort_by_firstnode{sort numerically keys %sort_by_firstnode};

        # assign colours
        my $colour_ref;
        foreach my $k (0..$#sorted_clusters) {
            $colour_ref = Gtk2::Gdk::Color->parse($palette[$k]);
            #$sorted_clusters[$k]->set_cached_value(__gui_palette_colour => $colour_ref);
            $self->{node_palette_colours}{$sorted_clusters[$k] -> get_name} = $colour_ref;
        }
    }

    return;
}

sub mapElementsToClusters {
    my $self = shift;
    my $cluster_nodes = shift;

    my %map;

    foreach my $node_ref (@$cluster_nodes) {

        my $terminal_elements = $node_ref -> get_terminal_elements();

        foreach my $elt (keys %$terminal_elements) {
            $map{ $elt } = $node_ref;
            #print "[mapElementsToClusters] $elt -> $node_ref\n";
        }

    }

    $self->{element_to_cluster} = \%map;

    return;
}

# Colours the element map with colours for the established clusters
sub recolourClusterElements {
    my $self = shift;

    my $map = $self->{map};
    return if not defined $map;

    my $list_name = $self->{analysis_list_name};
    my $list_index = $self->{analysis_list_index};
    my $analysis_min = $self->{analysis_min};
    my $analysis_max = $self->{analysis_max};
    my $terminal_elements = $self->{terminal_elements};

    # sets colours according to palette
    my $palette_colour_func = sub {
        my $elt = shift;
        my $cluster_node = $self->{element_to_cluster}{$elt};

        if ($cluster_node) {

            #my $colour_ref = $cluster_node->get_cached_value('__gui_palette_colour');
            my $colour_ref = $self->{node_palette_colours}{$cluster_node -> get_name};
            if ($colour_ref) {
                #print "[palette_colour_func] $elt: $colour_ref\n";
                return $colour_ref;
            }
            else {
                return COLOUR_PALETTE_OVERFLOW;
            }
        }
        else {
            #print "[palette_colour_func] $elt: no cluster\n";
            if (exists $terminal_elements->{$elt}) {
                # in tree
                return COLOUR_OUTSIDE_SELECTION;
            }
            else {
                # not even in the tree
                return COLOUR_NOT_IN_TREE;
            }
        }

        die "how did I get here?\n";
    };

    # sets colours according to (usually spatial) list value for the element's cluster
    my $list_value_colour_func = sub {
        my $elt = shift;

        my $cluster_node = $self->{element_to_cluster}{$elt};

        if ($cluster_node) {

            my $list_ref = $cluster_node -> get_list_ref (list => $list_name);
            my $val = defined $list_ref
                ? $list_ref->{$list_index}
                : undef;  #  allows for missing lists

            if (defined $val) {
                return $map -> getColour ($val, $analysis_min, $analysis_max);
            }
            else {
                return COLOUR_LIST_UNDEF;
            }
        }
        else {
            if (exists $terminal_elements->{$elt}) {
                # in tree
                return COLOUR_OUTSIDE_SELECTION;
            }
            else {
                # not even in the tree
                return COLOUR_NOT_IN_TREE;
            }
        }

        die "how did I get here?\n";
    };

    #print Data::Dumper::Dumper(keys %{$self->{element_to_cluster}});

    if ($self->{cluster_colour_mode} eq 'palette') {

        $map->colour($palette_colour_func);
        #FIXME: should hide the legend (currently broken - legend never shows up again)
        $map->setLegendMinMax(0, 0);

    }
    elsif ($self->{cluster_colour_mode} eq 'list-values') {

        $map->colour($list_value_colour_func);
        $map->setLegendMinMax($analysis_min, $analysis_max);
    }
    else {
        die "bad cluster colouring mode: " . $self->{cluster_colour_mode};
    }

}

# Colours the dendrogram lines with palette colours
sub recolourClusterLines {
    my $self = shift;
    my $cluster_nodes = shift;

    my ($colour_ref, $line, $list_ref, $val);
    my %coloured_nodes;
    tie %coloured_nodes, 'Tie::RefHash';

    my $map = $self->{map};
    my $list_name = $self->{analysis_list_name};
    my $list_index = $self->{analysis_list_index};
    my $analysis_min = $self->{analysis_min};
    my $analysis_max = $self->{analysis_max};

    foreach my $node_ref (@$cluster_nodes) {

        if ($self->{cluster_colour_mode} eq 'palette') {

            #$colour_ref = $node_ref->get_cached_value('__gui_palette_colour') || COLOUR_RED;
            $colour_ref = $self->{node_palette_colours}{$node_ref->get_name} || COLOUR_RED;

        }
        elsif ($self->{cluster_colour_mode} eq 'list-values') {

            $list_ref = $node_ref->get_list_ref (list => $list_name);
            $val = defined $list_ref
                ? $list_ref->{$list_index}
                : undef;  #  allows for missing lists

            if (defined $val) {
                $colour_ref = $map -> getColour ($val, $analysis_min, $analysis_max);
            }
            else {
                $colour_ref = undef;
            }
        }
        else {
            die "unknown colouring mode";
        }

        #$node_ref->set_cached_value(__gui_colour => $colour_ref);
        $self->{node_colours_cache}{$node_ref -> get_name} = $colour_ref;
        $colour_ref = $colour_ref || DEFAULT_LINE_COLOUR; # if colour undef -> we're clearing back to default

        #$line = $node_ref->get_cached_value('__gui_line');
        #$line = $self->{node_lines_cache}->{$node_ref->get_name};
        $line = $self->{node_lines}->{$node_ref->get_name};
        $line->set(fill_color_gdk => $colour_ref);

        # And also colour all nodes below
        foreach my $child_ref (@{$node_ref->get_children}) {
            $self->colourLines($child_ref, $colour_ref, \%coloured_nodes);
        }

        $coloured_nodes{$node_ref} = (); # mark as coloured
    }

    #print Data::Dumper::Dumper(keys %coloured_nodes);

    if ($self->{recolour_nodes}) {
        #print "[Dendrogram] Recolouring ", scalar keys %{ $self->{recolour_nodes} }, " nodes\n";
        # uncolour previously coloured nodes that aren't being coloured this time
        foreach my $node (keys %{ $self->{recolour_nodes} }) {

            if (not exists $coloured_nodes{$node}) {
                my $name = $node->get_name;
                $self->{node_lines}->{$name}->set(fill_color_gdk => DEFAULT_LINE_COLOUR);
                #$node->set_cached_value(__gui_colour => DEFAULT_LINE_COLOUR);
                $self->{node_colours_cache}{$name} = DEFAULT_LINE_COLOUR;
            }
        }
        #print "[Dendrogram] Recoloured nodes\n";
    }

    $self->{recolour_nodes} = \%coloured_nodes;

    return;
}

sub colourLines {
    my ($self, $node_ref, $colour_ref, $coloured_nodes) = @_;

    # We set the cached value to make it easier to recolour if the tree has to be re-rendered
    #$node_ref->set_cached_value(__gui_colour => $colour_ref);
    my $name = $node_ref -> get_name;
    $self->{node_colours_cache}{$name} = $colour_ref;

    $self->{node_lines}->{$name}->set(fill_color_gdk => $colour_ref);
    $coloured_nodes->{ $node_ref } = (); # mark as coloured

    foreach my $child_ref (@{$node_ref->get_children}) {
        $self->colourLines($child_ref, $colour_ref, $coloured_nodes);
    }

    return;
}

sub restoreLineColours {
    my $self = shift;

    if ($self->{recolour_nodes}) {

        my $colour_ref;
        foreach my $node_ref (keys %{ $self->{recolour_nodes} }) {

            #$colour_ref = $node_ref->get_cached_value('__gui_palette_colour');
            $colour_ref = $self->{node_palette_colours}{$node_ref->get_name};
            $colour_ref = $colour_ref || DEFAULT_LINE_COLOUR; # if colour undef -> we're clearing back to default

            $self->{node_lines}->{$node_ref->get_name}->set(fill_color_gdk => $colour_ref);

        }
    }

    return;
}

sub setProcessedNodes {
    my $self = shift;
    $self->{processed_nodes} = shift;

    return;
}

##########################################################
# The map combobox business
# This is the one that selects how to colour the map
##########################################################

# Combo-box for the list of results (eg: REDUNDANCY or ENDC_SINGLE) to use for the map
sub setupMapListModel {
    my $self  = shift;
    my $lists = shift;

    my $model = Gtk2::ListStore->new("Glib::String");
    my $iter;

    # Add all the analyses
    foreach my $list (sort @$lists) {
        #print "[Dendrogram] Adding map list $list\n";
        $iter = $model->append;
        $model->set($iter, 0, $list);
    }

    # Add & select, the "cluster" analysis (distinctive colour for every cluster)
    $iter = $model->insert(0);
    $model->set($iter, 0, '<i>Cluster</i>');

    $self->{map_list_combo}->set_model($model);
    $self->{map_list_combo}->set_active_iter($iter);

    return;
}

# Combo-box for analysis within the list of results (eg: REDUNDANCY or ENDC_ROSAUER)
sub setupMapIndexModel {
    my $self = shift;
    my $analyses = shift;

    my $model = Gtk2::ListStore->new("Glib::String");
    $self->{map_index_combo}->set_model($model);
    my $iter;

    # Add all the analyses
    if ($analyses) { # can be undef if we want to clear the list (eg: selecting "Cluster" mode)

        # restore previously selected index for this list
        my $selected_index = $self->{selected_list_index}{$analyses};
        my $selected_iter = undef;

        foreach my $key (sort keys %$analyses) {
            #print "[Dendrogram] Adding map analysis $key\n";
            $iter = $model->append;
            $model->set($iter, 0, $key);

            if (defined $selected_index && $selected_index eq $key) {
                $selected_iter = $iter;
            }
        }

        if ($selected_iter) {
            $self->{map_index_combo}->set_active_iter($selected_iter);
        }
        else {
            $self->{map_index_combo}->set_active_iter($model->get_iter_first);
        }
    }

    return;
}

# Change of list to display on the map
# Can either be the Cluster "list" (coloured by node) or a spatial analysis list
sub onMapListComboChanged {
    my $self = shift;
    my $combo = shift || $self->{map_list_combo};

    my $iter = $combo->get_active_iter;
    my $model = $combo->get_model;
    my $list = $model->get($iter, 0);

    if ($list eq '<i>Cluster</i>') {
        # Selected cluster-palette-colouring mode
        #print "[Dendrogram] Setting grid to use palette-based cluster colours\n";

        $self->{analysis_list_name}  = undef;
        $self->{analysis_list_index} = undef;
        $self->{analysis_min}        = undef;
        $self->{analysis_max}        = undef;

        $self->{cluster_colour_mode} = 'palette';
        $self->recolourClusterElements();

        $self->recolourClusterLines($self->{processed_nodes});

        # blank out the other combo
        $self->setupMapIndexModel(undef);
    }
    else {
        # Selected analysis-colouring mode
        $self->{analysis_list_name} = $list;

        $self->setupMapIndexModel($self->{tree_node}->get_list_ref(list => $list));
        $self->onMapIndexComboChanged();
    }

    return;
}

sub onMapIndexComboChanged {
    my $self = shift;
    my $combo = shift || $self->{map_index_combo};

    my $analysis = undef;
    my $iter = $combo->get_active_iter;

    if ($iter) {

        $analysis = $combo->get_model->get($iter, 0);
        my %stats = $self->{cluster} -> get_list_stats (
            list => $self->{analysis_list_name},
            index => $analysis
        );

        $self->{analysis_list_index} = $analysis;
        $self->{analysis_min}              = $stats{MIN};
        $self->{analysis_max}              = $stats{MAX};

        #print "[Dendrogram] Setting grid to use (spatial) analysis $analysis\n";
        $self->{cluster_colour_mode} = 'list-values';
        $self->recolourClusterElements();

        $self->recolourClusterLines($self->{processed_nodes});

    }
    else {
        $self->{analysis_list_index} = undef;
        $self->{analysis_min}        = undef;
        $self->{analysis_max}        = undef;
    }

    return;
}

##########################################################
# Highlighting a path up the tree
##########################################################

# Remove any existing highlights
sub clearHighlights {
    my $self = shift;
    if ($self->{highlighted_lines}) {
        foreach my $line (@{$self->{highlighted_lines}}) {

            $line->set(width_pixels => NORMAL_WIDTH);
        }
    }
    $self->{highlighted_lines} = undef;

    return;
}

sub highlightNode {
    my ($self, $node_ref) = @_;

    my $line = $self->{node_lines}->{$node_ref->get_name};
    $line->set(width_pixels => HIGHLIGHT_WIDTH);
    push @{$self->{highlighted_lines}}, $line;

    return;
}

# Highlights all nodes above and including the given node
sub highlightPath {
    my ($self, $node_ref) = @_;
    my @highlighted_lines;

    while ($node_ref) {
        my $line = $self->{node_lines}->{$node_ref->get_name};
        $line->set(width_pixels => HIGHLIGHT_WIDTH);
        push @{$self->{highlighted_lines}}, $line;

        $node_ref = $node_ref->get_parent;
    }

    return;
}

# Circles a node's terminal elements. Clear marks if $node undef
sub markElements {
    my $self = shift;
    my $node = shift;

    my $terminal_elements = (defined $node) ? $node->get_terminal_elements : {};
    $self->{map}->markIfExists( $terminal_elements, 'circle' );

    return;
}

##########################################################
# Tree operations
##########################################################

# Sometimes, tree lengths are negative and nodes get pushed back behind the root
# This will calculate how far they're pushed back so that we may render them
#
# Returns an absolute value or zero
sub getMaxNegativeLength {
    my $treenode = shift;
    my $min_length = 0;

    getMaxNegativeLengthInner($treenode, 0, \$min_length);
    if ($min_length < 0) {
        return -1 * $min_length;
    }
    else {
        return 0;
    }

    return;
}

sub getMaxNegativeLengthInner {
    my ($node, $cur_len, $min_length_ref) = @_;

    if (${$min_length_ref} > $cur_len) {
        ${$min_length_ref} = $cur_len;
    }
    foreach my $child ($node->get_children) {
        getMaxNegativeLengthInner($child, $cur_len + $node->get_length, $min_length_ref);
    }

    return;
}

sub initYCoords {
    my ($tree) = @_;

    # This is passed by reference
    # Will be increased as each leaf is allocated coordinates
    my $current_y = 0;
    initYCoordsInner($tree, \$current_y);

    return;
}

sub initYCoordsInner {
    my ($node, $current_y_ref) = @_;

    if ($node->is_terminal_node) {

        $node->set_value('_y', $$current_y_ref);
        ${$current_y_ref} = ${$current_y_ref} + LEAF_SPACING;

    }
    else {
        my $y_sum;
        my $count = 0;

        foreach my $child ($node->get_children) {
            initYCoordsInner($child, $current_y_ref);
            $y_sum += $child->get_value('_y');
            $count++;
        }
        $node->set_value('_y', $y_sum / $count); # y-value is average of children's y values
    }

    return;
}

# Returns first element equal-or-lower than target
    # FIXME: still need to check all the corner cases
    # ie: if 2222 333 444 searching for 2, will it start from the first 2?
sub binarySearch {
    my ($array, $target) = @_;
    my $last = $#{$array};
    my ($l, $r) = (0, $last);
    my ($m, $elt);

    while ($l < $r) {
        $m = ceil ( ($l+$r)/2 );
        $elt = $array->[$m]->get_value('total_length_gui');

        if ($elt < $target) {
            $l = $m + 1; # search in upper half
        }
        else {
            $r = $m - 1; # search in lower half
        }
        #print "$l $r $m\n";
    }

    $l = $last if $l > $last;

    # Might have landed too far above 
    while ($l > 0 && ($array->[$l]->get_value('total_length_gui') > $target)) { $l--; }

    return $l;
}

# These make an array out of the tree nodes
# sorted based on total length up to the node
#  (ie: excluding the node's own length)
sub makeTotalLengthArray {
    my $self = shift;
    my @array;
    my $lf = $self->{length_func};

    makeTotalLengthArrayInner($self->{tree_node}, 0, \@array, $lf);

    # Sort it
    @array = sort {
        $a->get_value('total_length_gui') <=> $b->get_value('total_length_gui')
        } @array;

    $self->{total_lengths_array} = \@array;

    return;
}

sub makeTotalLengthArrayInner {
    my ($node, $length_so_far, $array, $lf) = @_;

    $node->set_value('total_length_gui', $length_so_far);
    push @{$array}, $node;

    # Do the children
    my $length_total = &$lf($node) + $length_so_far;
    foreach my $child ($node->get_children) {
        makeTotalLengthArrayInner($child, $length_total, $array, $lf);
    }

    return;
}

##########################################################
# Drawing the tree
##########################################################

# whether to plot by 'length' or 'depth'
sub setPlotMode {
    my $self = shift;
    my $plot_mode = shift;
    $self->{plot_mode} = $plot_mode;

    # Work out how to get the "length" based on mode
    if ($plot_mode eq 'length') {
        $self->{length_func}     = \&Biodiverse::TreeNode::get_length;
        $self->{max_length_func} = \&Biodiverse::TreeNode::get_max_total_length;
        $self->{neg_length_func} = \&getMaxNegativeLength;
    }
    elsif ($plot_mode eq 'depth') {
        $self->{length_func}     = sub { return 1; }; # each node is "1" depth level below the previous one
        $self->{max_length_func} = \&Biodiverse::TreeNode::get_depth_below;
        $self->{neg_length_func} = sub { return 0; };
    }
    else {
        die "Invalid cluster-plotting mode - $plot_mode";
    }

    # Work out dimensions in canvas units
    my $f = $self->{max_length_func};
    my $g = $self->{neg_length_func};
    $self->{unscaled_height} = $self->{num_leaves} * LEAF_SPACING; 
    $self->{max_len}         = &$f($self->{tree_node}); # this is in (unscaled) cluster-length units
    $self->{neg_len}         = &$g($self->{tree_node});
    $self->{border_len}      = 0.5 * BORDER_FRACTION * ($self->{max_len} + $self->{neg_len}) / (1 - BORDER_FRACTION);
    $self->{unscaled_width}  = 2 * $self->{border_len} + $self->{max_len} + $self->{neg_len};

    $self->{centre_x} = $self->{unscaled_width} / 2;
    $self->{centre_y} = $self->{unscaled_height} / 2;

    $self->{unscaled_slider_x} = $self->{unscaled_width} - $self->{border_len} / 2;
    #print "[Dendrogram] slider position is $self->{unscaled_slider_x}\n";
    #
    #print "[Dendrogram] max len = " . $self->{max_len} . " neg len = " . $self->{neg_len} . "\n";
    #print "[Dendrogram] unscaled width: $self->{unscaled_width}, unscaled height: $self->{unscaled_height}\n";

    # Make sorted total length array to make slider and graph fast
    $self->makeTotalLengthArray;

    # (redraw)
    $self->renderTree;
    $self->renderGraph;
    $self->setupScrollbars;
    $self->resizeBackgroundRect;

    return;
}

# Sets a new tree to draw (TreeNode)
#   Performs once-off init such as getting number of leaves and
#   setting up the Y coords
sub setCluster {
    my $self = shift;
    my $cluster = shift;
    my $plot_mode = shift; # (cluster) 'length' or 'depth'

    # Clear any palette colours
    foreach my $node_ref (values %{$cluster->get_node_hash}) {
        #$node_ref->set_cached_value(__gui_palette_colour => undef);
        $self->{node_palette_colours}{$node_ref->get_name} = undef;
    }

    # Init variables
    $self->{cluster} = $cluster;
    return if ! defined $cluster;  #  trying to avoid warnings
    #  skip incomplete clusterings (where the tree was not built)
    my $completed = $cluster->get_param('COMPLETED');
    return if defined $completed and $completed != 1;

    $self->{tree_node} = $cluster->get_tree_ref;
    $self->{element_to_cluster} = {};
    $self->{selected_list_index} = {};
    $self->{cluster_colour_mode} = 'palette';
    $self->{recolour_nodes} = undef;
    $self->{processed_nodes} = undef;

    #  number the nodes if needed
    if (! defined $self->{tree_node} -> get_value ('TERMINAL_NODE_FIRST')) {
        $self->{tree_node} -> number_terminal_nodes;
    }

    my $terminal_nodes_ref = $cluster->get_terminal_nodes();
    $self->{num_leaves} = scalar (keys %{$terminal_nodes_ref});
    $self->{terminal_elements} = $cluster->get_tree_ref->get_terminal_elements();

    $self->{num_nodes} = $cluster->get_node_count;

    # Initialise Y coordinates
    initYCoords($self->{tree_node});

    # Make slider
    $self->makeSlider();

    # draw
    $self->setPlotMode($plot_mode);

    # Initialise map analysis-selection comboboxen
    if ($self->{map_list_combo}) {
        $self->setupMapListModel( scalar $self->{tree_node}->get_hash_lists() );
    }

    return;
}

sub clear {
    my $self = shift;

    $self -> clearHighlights;

    $self->{node_lines} = {};
    $self->{node_colours_cache} = {};

    delete $self->{unscaled_width};
    delete $self->{unscaled_height};
    delete $self->{tree_node};

    if ($self->{lines_group}) {
        $self->{lines_group}->destroy();
    }
    if ($self->{graph_group}) {
        $self->{graph_group}->destroy();
    }
    if ($self->{slider}) {
        $self->{slider}->hide;
    }
    if ($self->{graph_slider}) {
        $self->{graph_slider}->hide;
    }

    return;
}

# (re)draws the tree (...every time canvas is resized)
sub renderTree {
    my $self = shift;
    my $tree = $self->{tree_node};

    if ($self->{render_width} == 0) {
        return;
    }

    # Remove any highlights. The lines highlightened are destroyed next,
    # and may cause a crash when they get unhighlighted
    $self->clearHighlights;

    $self->{node_lines} = {};

    # Delete any old nodes
    $self->{lines_group}->destroy() if $self->{lines_group};
    $self->{root_circle}->destroy() if $self->{root_circle};

    # Make group so we can transform everything together
    my $lines_group = Gnome2::Canvas::Item->new (
        $self->{canvas}->root,
        "Gnome2::Canvas::Group",
        x => 0,
        y => 0
    );
    $self->{lines_group} = $lines_group;

    # Scaling values to make the rendered tree render_width by render_height
    $self->{length_scale} = $self->{render_width}  / ($self->{unscaled_width}  || 1);
    $self->{height_scale} = $self->{render_height} / ($self->{unscaled_height} || 1);

    #print "[Dendrogram] Length scale = $self->{length_scale} Height scale = $self->{height_scale}\n";

    # Recursive draw
    my $length_func = $self->{length_func};
    my $root_offset = $self->{render_width}
                      - ($self->{border_len}
                         + $self->{neg_len}
                         )
                      * $self->{length_scale}
                      ;
    #print "[Dendrogram] root offset = $root_offset\n";
    #print "$self->{render_width} - ($self->{border_len} + $self->{neg_len}) * $self->{length_scale}\n";
    $self->drawNode($tree, $root_offset, $length_func, $self->{length_scale}, $self->{height_scale});

    # Draw a circle to mark out the root node
    my $root_y = $tree->get_value('_y') * $self->{height_scale};
    my $diameter = 0.5 * $self->{border_len} * $self->{length_scale};
    $self->{root_circle} = Gnome2::Canvas::Item->new (
        $self->{lines_group},
        'Gnome2::Canvas::Ellipse',
        x1 => $root_offset,
        y1 => $root_y + $diameter / 2,
        x2 => $root_offset + $diameter,
        y2 => $root_y - $diameter / 2,
        fill_color => 'brown'
    );
    # Hook up the root-circle to the root!
    $self->{root_circle}->signal_connect_swapped (event => \&onEvent, $self);
    $self->{root_circle}->{node} =  $tree; # Remember the root (for hovering, etc...)

    $lines_group->lower_to_bottom();
    $self->{root_circle}->lower_to_bottom();
    $self->{back_rect}->lower_to_bottom();

    if (0) {
        # Spent ages on this - not working - NO IDEA WHY!!

        # Draw an equilateral triangle to mark out the root node
        # Vertex pointing at the root, the up-down side half border_len behind
        my $perp_height = 0.5 * $self->{length_scale} *  $self->{border_len} / 1.732;  # 1.723 ~ sqrt(3)
        my $triangle_path = Gnome2::Canvas::PathDef->new;
        $triangle_path->moveto($root_offset, $root_y);
        $triangle_path->lineto($root_offset - 0.5 * $self->{border_len}, $root_y + $perp_height);
        $triangle_path->lineto($root_offset - 0.5 * $self->{border_len}, $root_y - $perp_height);
        $triangle_path->closepath();

        my $triangle = Gnome2::Canvas::Item->new (  $lines_group,
                                                    "Gnome2::Canvas::Shape",
                                                    fill_color => "green",
                                                    );
        $triangle->set_path_def($triangle_path);
    }

    #$self->restoreLineColours();

    return;
}

##########################################################
# The graph
# Shows what percentage of nodes lie to the left
##########################################################

sub renderGraph {
    my $self = shift;
    my $lengths = $self->{total_lengths_array};

    if ($self->{render_width} == 0) {
        return;
    }

    my $graph_height_units = $self->{graph_height_px};
    $self->{graph_height_units} = $graph_height_units;

    # Delete old lines
    if ($self->{graph_group}) {
        $self->{graph_group}->destroy();
    }

    # Make group so we can transform everything together
    my $graph_group = Gnome2::Canvas::Item->new (
        $self->{graph}->root,
        'Gnome2::Canvas::Group',
        x => 0,
        y => 0
    );
    $graph_group->lower_to_bottom();
    $self->{graph_group} = $graph_group;

    # Draw the graph from right-to-left
    #  starting from the top of the tree
    # Note: "length" here usually means length to the right of the node (towards root)
    my $start_length = $lengths->[0]->get_value('total_length_gui') * $self->{length_scale};
    my $start_index = 0;
    my $current_x = $self->{render_width}
                    - ($self->{border_len}
                       + $self->{neg_len}
                       )
                    * $self->{length_scale}
                    ;
    my $previous_y;
    my $y_offset; # this puts the lowest y-value at the bottom of the graph - no wasted space

    my @num_lengths = map { $_->get_value('total_length_gui') } @$lengths;
    #print "[renderGraph] lengths: @num_lengths\n";

    #for (my $i = 0; $i <= $#{$lengths}; $i++) {
    foreach my $i (0 .. $#{$lengths}) {

        my $this_length = $lengths->[$i]->get_value('total_length_gui') * $self->{length_scale};

        # Start a new segment. We do this if since a few nodes can "line up" and thus have the same length
        if ($this_length > $start_length) {

            my $segment_length = ($this_length - $start_length);
            $start_length = $this_length;

            # Line height proportional to the percentage of nodes to the left of this one
            # At the start, it is max to give value zero - the y-axis goes top-to-bottom
            $y_offset = $y_offset || $#{$lengths};
            my $segment_y = ($i * $graph_height_units) / $y_offset;
            #print "[renderGraph] segment_y=$segment_y current_x=$current_x\n";

            my $hline =  Gnome2::Canvas::Item->new (
                $graph_group,
                'Gnome2::Canvas::Line',
                points          => [$current_x - $segment_length, $segment_y, $current_x, $segment_y],
                fill_color_gdk  => COLOUR_BLACK,
                width_pixels    => NORMAL_WIDTH
            );

            # Now the vertical line
            if ($previous_y) {
                my $vline = Gnome2::Canvas::Item->new (
                    $graph_group,
                    'Gnome2::Canvas::Line',
                    points          => [$current_x, $previous_y, $current_x, $segment_y],
                    fill_color_gdk  => COLOUR_BLACK,
                    width_pixels    => NORMAL_WIDTH
                );
            }

            $previous_y = $segment_y;
            $current_x -= $segment_length;
        }

    }

    $self->{graph}->set_scroll_region(0, 0, $self->{render_width}, $graph_height_units);

    return;
}

sub resizeBackgroundRect {
    my $self = shift;

    $self->{back_rect}->set(    x2 => $self->{render_width}, y2 => $self->{render_height});
    $self->{back_rect}->lower_to_bottom();

    return;
}

##########################################################
# Drawing
##########################################################

sub drawNode {
    my ($self, $node, $current_xpos, $length_func, $length_scale, $height_scale) = @_;

    my $length = &$length_func($node) * $length_scale;
    my $new_current_xpos = $current_xpos - $length;
    my $y = $node->get_value('_y') * $height_scale;
    #my $colour_ref = $node->get_cached_value('__gui_colour') || DEFAULT_LINE_COLOUR;
    my $colour_ref = $self->{node_colours_cache}{$node -> get_name} || DEFAULT_LINE_COLOUR;

    #print "[Dendrogram] new current length = $new_current_xpos\n";

    # Draw our horizontal line
    my $line = $self->drawLine($current_xpos, $y, $new_current_xpos, $y, $colour_ref);
    $line->signal_connect_swapped (event => \&onEvent, $self);
    $line->{node} =  $node; # Remember the node (for hovering, etc...)

    # Remember line (for colouring, etc...)
    #$self->{node_lines_cache}->{$node->get_name} = $line;
    $self->{node_lines}->{$node->get_name} = $line;
    #$node->set_cached_value(__gui_line => $line);  #  don't cache glib stuff - serialisation causes crashes

    # Draw children
    my ($ymin, $ymax);

    foreach my $child ($node->get_children) {
        my $child_y = $self->drawNode($child, $new_current_xpos, $length_func, $length_scale, $height_scale);

        $ymin = $child_y if ( (not defined $ymin) || $child_y <= $ymin);
        $ymax = $child_y if ( (not defined $ymax) || $child_y >= $ymax);
    }

    # Vertical line
    if (defined $ymin) { 
        $self->drawLine($new_current_xpos, $ymin, $new_current_xpos, $ymax, DEFAULT_LINE_COLOUR);
    }
    return $y;
}

sub drawLine {
    my ($self, $x1, $y1, $x2, $y2, $colour_ref) = @_;
    #print "Line ($x1,$y1) - ($x2,$y2)\n";

    my $line_style;
    if ($x1 >= $x2) {
        $line_style = 'solid';
    }
    else {
        $line_style = 'on-off-dash';
    }

    return Gnome2::Canvas::Item->new (
        $self->{lines_group},
        "Gnome2::Canvas::Line",
        points => [$x1, $y1, $x2, $y2],
        fill_color_gdk => $colour_ref,
        line_style => $line_style,
        width_pixels => NORMAL_WIDTH
    );
}

##########################################################

# Call callback functions and mark elements under the node
# If clicked on, marks will be retained. If only hovered, they're
# cleared when user leaves node
sub onEvent {
    my ($self, $event, $line) = @_;

    my $node = $line->{node};
    my $f;

    if ($event->type eq 'enter-notify') {
        #print "enter - " . $node->get_name() . "\n";

        # Call client-defined callback function
        if (defined $self->{hover_func}) {
            $f = $self->{hover_func};
            &$f($node);
        }

        # Call client-defined callback function
        if (defined $self->{highlight_func}
            and $self->{use_highlight_func}
            and not $self->{click_line}) {

            $f = $self->{highlight_func};
            &$f($node);
        }

        #if (not $self->{click_line}) {
            #$self->{hover_line}->set(fill_color => 'black') if $self->{hover_line};
            #$line->set(fill_color => 'red') if (not $self->{click_line});
            #$self->{hover_line} = $line;
        #}

        # Change the cursor
        my $cursor = Gtk2::Gdk::Cursor->new(HOVER_CURSOR);
        $self->{canvas}->window->set_cursor($cursor);

    }
    elsif ($event->type eq 'leave-notify') {
        #print "leave - " . $node->get_name() . "\n";

        # Call client-defined callback function
        if (defined $self->{hover_func}) {
            $f = $self->{hover_func};
            &$f(undef);
        }

        # Call client-defined callback function
        if (defined $self->{highlight_func} and not $self->{click_line}) {
            $f = $self->{highlight_func};
            &$f(undef);
        }

        #$line->set(fill_color => 'black') if (not $self->{click_line});

        # Change cursor back to default
        $self->{canvas}->window->set_cursor(undef);

    }
    elsif ($event->type eq 'button-press') {

        # If middle-click or control-click call Clustering tab's callback (show/Hide popup dialog)
        if ($event->button == 2 || ($event->button == 1 and $event->state >= [ 'control-mask' ]) ) {
            if (defined $self->{ctrl_click_func}) {
                $f = $self->{ctrl_click_func};
                &$f($node);
            }
        # Just click - colour nodes
        }
        elsif ($event->button == 1) {
            $self->doColourNodesBelow($node);
            if (defined $self->{click_func}) {
                $f = $self->{click_func};
                &$f($node);
            }
        # Right click - set marks semi-permanently
        }
        elsif ($event->button == 3) {

            # Restore previously clicked/hovered line
            #$self->{click_line}->set(fill_color => 'black') if $self->{click_line};
            #$self->{hover_line}->set(fill_color => 'black') if $self->{hover_line};

            # Call client-defined callback function
            if (defined $self->{highlight_func}) {
                $f = $self->{highlight_func};
                &$f($node);
            }
            #$line->set(fill_color => 'red');
            $self->{click_line} = $line;
        }
    }

    return 1;    
}

# Implements panning the grid
sub onBackgroundEvent {
    my ($self, $event, $item) = @_;

    if ( $event->type eq 'button-press') {
        if ($event->button == 1) {
            $self -> doColourNodesBelow;  #  no arg will clear colouring
            if (defined $self->{click_func}) {
                my $f = $self->{click_func};
                &$f();
            }
        }
        else {
            ($self->{drag_x}, $self->{drag_y}) = $event->coords;

            # Grab mouse
            $item->grab ([qw/pointer-motion-mask button-release-mask/],
                         Gtk2::Gdk::Cursor->new ('fleur'),
                        $event->time
                        );
            $self->{dragging} = 1;
            $self->{dragged}  = 0;
        }

    }
    elsif ( $event->type eq 'button-release') {

        $item->ungrab ($event->time);
        $self->{dragging} = 0;

        # FIXME: WHAT IS THIS (obsolete??)
        # If clicked without dragging, we also remove the element mark (see onEvent)
        if (not $self->{dragged}) {
            #$self->markElements(undef);
            if ($self->{click_line}) {
                $self->{click_line}->set(fill_color => 'black');
            }
            $self->{click_line} = undef;
        }
    }
    elsif ( $event->type eq 'motion-notify') {

        #if ($self->{dragging} && $event->state >= 'button1-mask' ) {
        if ($self->{dragging}) {
            # Work out how much we've moved away from last time
            my ($x, $y) = $event->coords;
            my ($dx, $dy) = ($x - $self->{drag_x}, $y - $self->{drag_y});
            $self->{drag_x} = $x;
            $self->{drag_y} = $y;

            # Convert into scaled coords
            $self->{centre_x} = $self->{centre_x} * $self->{length_scale};
            $self->{centre_y} = $self->{centre_y} * $self->{height_scale};

            # Scroll
            $self->{centre_x} = clamp (
                $self->{centre_x} - $dx,
                $self->{width_px}/2,
                $self->{render_width}-$self->{width_px}/2
            ) ;
            $self->{centre_y} = clamp (
                $self->{centre_y}-$dy,
                $self->{height_px}/2,
                $self->{render_height}-$self->{height_px}/2
            );

            # Convert into world coords
            $self->{centre_x} = $self->{centre_x} / $self->{length_scale};
            $self->{centre_y} = $self->{centre_y} / $self->{height_scale};

            #print "[Pan] panned\n";
            $self->centreTree();
            $self->updateScrollbars();

            $self->{dragged} = 1;
        }
    }

    return 0;    
}

#FIXME: we render our canvases twice!! 
#  here and in the main dendrogram's onResize()
#  as far as I remember, this was due to issues keeping both graphs in sync
sub onGraphResize {
    my ($self, $size) = @_;
    $self->{graph_height_px} = $size->height;

    if (exists $self->{unscaled_width}) {
        $self->renderTree;
        $self->renderGraph;
        $self->repositionSliders;

        $self->centreTree;
        $self->repositionSliders;
        $self->setupScrollbars;
    }

    return;
}

sub onResize {
    my ($self, $size)  = @_;
    $self->{width_px}  = $size->width;
    $self->{height_px} = $size->height;

    #  for debugging
    #$self->{render_width} = $self->{width_px};
    #$self->{render_height} = $self->{height_px};

    my $resize_bk = 0;
    if ($self->{render_width} == 0 || $self->{zoom_fit} == 1) {
        $self->{render_width} = $size->width;
        $resize_bk = 1;
        #$self->resizeBackgroundRect();
    }
    if ($self->{render_height} == 0 || $self->{zoom_fit} == 1) {
        $self->{render_height} = $size->height;
        $resize_bk = 1;
        #$self->resizeBackgroundRect();
    }

    $self->resizeBackgroundRect() if $resize_bk;

    if (exists $self->{unscaled_width}) {

        #print "[onResize] width px=$self->{width_px} render=$self->{render_width}\n";
        #print "[onResize] height px=$self->{height_px} render=$self->{render_height}\n";

        $self->renderTree();
        $self->renderGraph();
        $self->centreTree();

        $self->repositionSliders();

        $self->setupScrollbars();

        # Set visible region
        $self->{canvas}->set_scroll_region(0, 0, $size->width, $size->height);
    }

    return;
}

sub clamp {
    my ($val, $min, $max) = @_;
    return $min if $val < $min;
    return $max if $val > $max;
    return $val;
}

##########################################################
# Scrolling
##########################################################
sub setupScrollbars {
    my $self = shift;
    return if not $self->{render_width};

    #print "[setupScrolllbars] render w:$self->{render_width} h:$self->{render_height}\n";
    #print "[setupScrolllbars]   px   w:$self->{width_px} h:$self->{height_px}\n";

    $self->{hadjust}->upper( $self->{render_width} );
    $self->{vadjust}->upper( $self->{render_height} );

    $self->{hadjust}->page_size( $self->{width_px} );
    $self->{vadjust}->page_size( $self->{height_px} );

    $self->{hadjust}->page_increment( $self->{width_px} / 2 );
    $self->{vadjust}->page_increment( $self->{height_px} / 2 );

    $self->{hadjust}->changed;
    $self->{vadjust}->changed;

    return;
}

sub updateScrollbars {
    my $self = shift;

    #print "[updateScrollbars] centre x:$self->{centre_x} y:$self->{centre_y}\n";
    #print "[updateScrollbars] scale  x:$self->{length_scale} y:$self->{height_scale}\n";

    $self->{hadjust}->set_value($self->{centre_x} * $self->{length_scale} - $self->{width_px} / 2);
    #print "[updateScrollbars] set hadjust to ";
    #print ($self->{centre_x} * $self->{length_scale} - $self->{width_px} / 2);
    #print "\n";

    $self->{vadjust}->set_value($self->{centre_y} * $self->{height_scale} - $self->{height_px} / 2);
    #print "[updateScrollbars] set vadjust to ";
    #print ($self->{centre_y} * $self->{height_scale} - $self->{height_px} / 2);
    #print "\n";

    return;
}

sub onHScroll {
    my $self = shift;

    if (not $self->{dragging}) {
        my $h = $self->{hadjust}->get_value;
        $self->{centre_x} = ($h + $self->{width_px} / 2) / $self->{length_scale};

        #print "[onHScroll] centre x:$self->{centre_x}\n";
        $self->centreTree;
    }

    return;
}

sub onVScroll {
    my $self = shift;

    if (not $self->{dragging}) {
        my $v = $self->{vadjust}->get_value;
        $self->{centre_y} = ($v + $self->{height_px} / 2) / $self->{height_scale};

        #print "[onVScroll] centre y:$self->{centre_y}\n";
        $self->centreTree;
    }

    return;
}

sub centreTree {
    my $self = shift;
    return if !defined $self->{lines_group};
    
    my $xoffset = $self->{centre_x} * $self->{length_scale} - $self->{width_px} / 2;
    my $yoffset = $self->{centre_y} * $self->{height_scale} - $self->{height_px} / 2;

    #print "[centreTree] scroll xoffset=$xoffset  yoffset=$yoffset\n";

    my $matrix = [1,0,0,1, -1 * $xoffset, -1 * $yoffset];
    eval {$self->{lines_group}->affine_absolute($matrix)};
    $self->{back_rect}->affine_absolute($matrix);

    # for the graph only move sideways
    $matrix->[5] = 0;
    eval {$self->{graph_group}->affine_absolute($matrix)};

    $self->repositionSliders();

    return;
}

##########################################################
# Zoom
##########################################################

sub zoomIn {
    my $self = shift;

    $self->{render_width} = $self->{render_width} * 1.5;
    $self->{render_height} = $self->{render_height} * 1.5;

    $self->{zoom_fit} = 0;
    $self->postZoom();

    return;
}

sub zoomOut {
    my $self = shift;

    $self->{render_width} = $self->{render_width} / 1.5;
    $self->{render_height} = $self->{render_height} / 1.5;

    $self->{zoom_fit} = 0;
    $self->postZoom();

    return;
}

sub zoomFit {
    my $self = shift;
    $self->{render_width} = $self->{width_px};
    $self->{render_height} = $self->{height_px};
    $self->{zoom_fit} = 1;
    $self->postZoom();

    return;
}

sub postZoom {
    my $self = shift;

    $self->renderTree();
    $self->renderGraph();
    $self->repositionSliders();
    $self->resizeBackgroundRect();

    # Convert into scaled coords
    $self->{centre_x} = $self->{centre_x} * $self->{length_scale};
    $self->{centre_y} = $self->{centre_y} * $self->{height_scale};

    # Scroll
    $self->{centre_x} = clamp($self->{centre_x}, $self->{width_px}/2, $self->{render_width}-$self->{width_px}/2) ;
    $self->{centre_y} = clamp($self->{centre_y}, $self->{height_px}/2, $self->{render_height}-$self->{height_px}/2);

    # Convert into world coords
    $self->{centre_x} = $self->{centre_x} / $self->{length_scale};
    $self->{centre_y} = $self->{centre_y} / $self->{height_scale};

    $self->centreTree();
    $self->setupScrollbars();
    $self->updateScrollbars();

    return;
}

##########################################################
# Misc
##########################################################

sub numerically {$a <=> $b};

# Resize background rectangle which is dragged for panning
sub max {
    return ($_[0] > $_[1]) ? $_[0] : $_[1];
}

1;