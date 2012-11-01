package Biodiverse::GUI::Exclusions;

use strict;
use warnings;
use Gtk2;

our $VERSION = '0.18003';

use Biodiverse::GUI::GUIManager;

=head1
Implements the Run Exclusions dialog

=cut

##########################################################
# Globals
##########################################################

use constant DLG_NAME => 'dlgRunExclusions';

# Maps dialog widgets into fields in BaseData's exclusionHash
#  should really build widget_map from %BaseData::exclusionHash
my %g_widget_map = (
    LabelsMaxVar        => ['LABELS', 'maxVariety'   ],
    LabelsMinVar        => ['LABELS', 'minVariety'   ],
    LabelsMaxSamp       => ['LABELS', 'maxSamples'   ],
    LabelsMinSamp       => ['LABELS', 'minSamples'   ],
    LabelsMaxRedundancy => ['LABELS', 'maxRedundancy'],
    LabelsMinRedundancy => ['LABELS', 'minRedundancy'],
    LabelsMaxRange      => ['LABELS', 'max_range'    ],
    LabelsMinRange      => ['LABELS', 'min_range'    ],

    GroupsMaxVar        => ['GROUPS', 'maxVariety'   ],
    GroupsMinVar        => ['GROUPS', 'minVariety'   ],
    GroupsMaxSamp       => ['GROUPS', 'maxSamples'   ],
    GroupsMinSamp       => ['GROUPS', 'minSamples'   ],
    GroupsMaxRedundancy => ['GROUPS', 'maxRedundancy'],
    GroupsMinRedundancy => ['GROUPS', 'minRedundancy'],
);

#my %g_widget_map2;
#foreach my $type (qw /LABELS GROUPS/) {
#    ...
#}



sub showDialog {
    my $exclusionsHash = shift;

    my $gui = Biodiverse::GUI::GUIManager->instance;
    my $dlgxml = Gtk2::GladeXML->new($gui->getGladeFile, DLG_NAME);
    my $dlg = $dlgxml->get_widget(DLG_NAME);

    # Put it on top of main window
    $dlg->set_transient_for($gui->getWidget('wndMain'));

    # Init the widgets
    foreach my $name (keys %g_widget_map) {
        my $checkbox = $dlgxml->get_widget('chk' . $name);
        my $spinbutton = $dlgxml->get_widget('spin' . $name);
#print "$name : $checkbox : $spinbutton\n";
        # Load initial value
        my $fields = $g_widget_map{$name};
        my $value = $exclusionsHash->{$fields->[0]}{$fields->[1]};
        
        if (defined $value) {
            $checkbox->set_active(1);
            $spinbutton->set_value($value);
        }
        else {
            $spinbutton->set_sensitive(0);
        }

        # Set up the toggle checkbox signals
        $checkbox->signal_connect(toggled => \&onToggled, $spinbutton);

    }
    
    #  and the text matching
    my $label_filter_checkbox = $dlgxml->get_widget('chk_enable_label_exclusion_regex');
    my @label_filter_widget_names = qw /
        Entry_label_exclusion_regex
        chk_label_exclusion_regex
        Entry_label_exclusion_regex_modifiers
    /;

    foreach my $widget_name (@label_filter_widget_names) {
        my $widget = $dlgxml->get_widget($widget_name);

        $widget->set_sensitive(0);

        my $callback = sub {
            my ($checkbox, $option_widget) = @_;
            $option_widget->set_sensitive( $checkbox->get_active );
        };

        $label_filter_checkbox->signal_connect(toggled => $callback, $widget);
    }

    #  and the file list
    my $file_list_checkbox = $dlgxml->get_widget('chk_label_exclude_use_file');
    my @file_list_filter_widget_names = qw /
        chk_label_exclusion_label_file
    /;

    foreach my $widget_name (@file_list_filter_widget_names ) {
        my $widget = $dlgxml->get_widget($widget_name);

        $widget->set_sensitive(0);

        my $callback = sub {
            my ($checkbox, $option_widget) = @_;
            $option_widget->set_sensitive( $checkbox->get_active );
        };

        $file_list_checkbox->signal_connect(toggled => $callback, $widget);
    }
    

    # Show the dialog
    my $response = $dlg->run();
    my $ret = 0;

    if ($response eq 'ok') {

        $ret = 1;

        # Set fields
        foreach my $name (keys %g_widget_map) {
            my $checkbox = $dlgxml->get_widget('chk' . $name);
            my $spinbutton = $dlgxml->get_widget('spin' . $name);

            my $fields = $g_widget_map{$name};
            if ($checkbox->get_active()) {
                my $value = $spinbutton->get_value();
                #  round any decimals to six places to avoid floating point issues.
                #  could cause trouble later on, but the GUI only allows two decimals now anyway...
                $value = sprintf ("%.6f", $value) if $value =~ /\./;  
                $exclusionsHash->{$fields->[0]}{$fields->[1]} = $value;
            }
            else {
                delete $exclusionsHash->{$fields->[0]}{$fields->[1]};
            }
        }
        
        my $regex_widget = $dlgxml->get_widget('Entry_label_exclusion_regex');
        my $regex        = $regex_widget->get_text;
        if ($label_filter_checkbox->get_active && length $regex) {

            my $regex_negate_widget = $dlgxml->get_widget('chk_label_exclusion_regex');
            my $regex_negate        = $regex_negate_widget->get_active;

            my $regex_modifiers_widget = $dlgxml->get_widget('Entry_label_exclusion_regex_modifiers');
            my $regex_modifiers        = $regex_modifiers_widget->get_text;

            $exclusionsHash->{LABELS}{regex}{regex}  = $regex;
            $exclusionsHash->{LABELS}{regex}{negate} = $regex_negate;
        }

        if ($file_list_checkbox->get_active) {
            print "";
            my $negate_widget = $dlgxml->get_widget('chk_label_exclusion_label_file');
            my $negate        = $negate_widget->get_active;

            my %options = Biodiverse::GUI::BasedataImport::getRemapInfo (
                $gui,
                undef,
                undef,
                undef,
                ['Input_element'],
            );

            ##  now do something with them...
            if ($options{file}) {

                my $check_list = Biodiverse::ElementProperties->new;
                $check_list->import_data (%options);

                $exclusionsHash->{LABELS}{element_check_list}{list}   = $check_list;
                $exclusionsHash->{LABELS}{element_check_list}{negate} = $negate;
            }
        }
    }

    $dlg->destroy();
    return $ret;
}


sub onToggled {
    my ($checkbox, $spinbutton) = @_;
    $spinbutton->set_sensitive( $checkbox->get_active );
}


1;