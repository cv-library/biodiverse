package Biodiverse::GUI::MatrixImport;

use strict;
use warnings;
use File::Basename;
use Carp;

use Gtk2;
use Gtk2::GladeXML;

our $VERSION = '0.16';

use Biodiverse::GUI::Project;
use Biodiverse::GUI::BasedataImport;  #  needed for the ramp dialogue - should shift that to its own package
use Biodiverse::ElementProperties;
use Biodiverse::Common;

##################################################
# High-level procedure
##################################################

sub run {
    my $gui = shift;

    #########
    # 1. Get the matrix name & filename
    #########
    my ($name, $filename) = Biodiverse::GUI::OpenDialog::Run('Import Matrix', ['csv', 'txt'], 'csv', 'txt', '*');

    return if ! ($filename && $name);

    # Get header columns
    print "[GUI] Discovering columns from $filename\n";
    
    my $line;
    
    open (my $fh, '<', $filename) || croak "Unable to open $filename\n";

    BY_LINE:
    while (<$fh>) { # get first non-blank line
        $line = $_;
        chomp $line;
        last BY_LINE if $line;
    }
    my $header = $line;
    $line = <$fh>; #  don't test on the header - can sometimes have one column
    $fh -> close;
    
    my $sep_char = $gui->getProject->guess_field_separator (string => $line);
    my $eol = $gui->getProject->guess_eol (string => $line);
    my @headers_full
        = $gui -> getProject -> csv2list(
            string   => $header,
            sep_char => $sep_char,
            eol      => $eol
        );
    
    my $is_r_data_frame
        = Biodiverse::GUI::BasedataImport::check_if_r_data_frame (
            file     => $filename,
            #quotes   => $quotes,
            sep_char => $sep_char,
        );
    #  add a field to the header if needed
    if ($is_r_data_frame) {
        unshift @headers_full, 'R_data_frame_col_0';
    }
    
    # Add non-blank columns
    my @headers;
    foreach my $header (@headers_full) {
        push @headers, $header if $header;
    }


    #########
    # 2. Get column types
    #########
    my ($dlg, $col_widgets) = makeColumnsDialog(\@headers, $gui->getWidget('wndMain'));
    my ($column_settings, $response);
    
    GET_RESPONSE:
    while (1) { # Keep showing dialog until have at least one label & one matrix-start column
        $response = $dlg->run();

        last GET_RESPONSE if $response ne 'ok';

        $column_settings = getColumnSettings($col_widgets, \@headers);
        my $num_labels = @{$column_settings->{labels}};
        my $num_start  = @{$column_settings->{start}};

        last GET_RESPONSE if $num_start == 1 && $num_labels > 0;
        
        #  try again if we get to here
        my $msg = Gtk2::MessageDialog->new(
            undef,
            'modal',
            'error',
            'close',
            'Please select at least one label and only one start-of-matrix column',
        );
        $msg->run();
        $msg->destroy();
        $column_settings = undef;
    }

    $dlg->destroy();

    return if ! $column_settings;
    
    #  do we need a remap table?
    my $remap;
    my $remap_response
        = Biodiverse::GUI::YesNoCancel -> run ({
            title => 'Remap option',
            text  => 'Remap element names and set include/exclude?'
            }
        );
        
    return if lc $remap_response eq 'cancel';
    
    if (lc $remap_response eq 'yes') {
        my %remap_data
            = Biodiverse::GUI::BasedataImport::getRemapInfo ($gui, $filename, 'remap');
    
        #  now do something with them...
        if ($remap_data{file}) {
            #my $file = $remap_data{file};
            $remap = Biodiverse::ElementProperties -> new;
            $remap -> import_data (%remap_data);
        }
    }

    #########
    # 3. Add the matrix
    #########
    my $matrix_ref = Biodiverse::Matrix -> new (NAME => $name);

    # Set parameters
    my @label_columns;
    my $matrix_start_column;

    foreach my $col (@{$column_settings->{labels} }) {
        push (@label_columns, $col->{id});
        print "[Matrix import] label column is $col->{id}\n";
    }
    $matrix_start_column = $column_settings->{start}[0]->{id};
    print "[Matrix import] start column is $matrix_start_column\n";

    $matrix_ref->set_param('ELEMENT_COLUMNS', \@label_columns);
    $matrix_ref->set_param('MATRIX_STARTCOL', $matrix_start_column);
    
    # Load file
    $matrix_ref->load_data(
        file               => $filename,
        element_properties => $remap,
        #input_quotes       => $quotes,
        sep_char           => $sep_char,
    );

    $gui->getProject->addMatrix ($matrix_ref);

    return $matrix_ref;


}

##################################################
# Extracting information from widgets
##################################################

# Extract column types and sizes into lists that can be passed to the reorder dialog
#  NEED TO GENERALISE TO HANDLE ANY NUMBER
sub getColumnSettings {
    my $cols = shift;
    my $headers = shift;
    my $num = @$cols;
    my (@labels, @start);

    foreach my $i (0..($num - 1)) {
        my $widgets = $cols->[$i];
        # widgets[0] - Ignore
        # widgets[1] - Label
        # widgets[2] - Matrix start

        if ($widgets->[1]->get_active()) {
            push (@labels, { name => $headers->[$i], id => $i });

        }
        elsif ($widgets->[2]->get_active()) {
            push (@start, { name => $headers->[$i], id => $i });
        }

    }

    return { start => \@start, labels => \@labels };
}

##################################################
# Column selection dialog
##################################################

sub makeColumnsDialog {
    # We have to dynamically generate the choose columns dialog since
    # the number of columns is unknown

    my $header = shift; # ref to column header array
    my $wndMain = shift;
    my $type_options = shift;  #  array of types
    if (not defined $type_options or (ref $type_options) !~ /ARRAY/) {
        $type_options = ['Ignore', 'Label', 'Matrix Start'];
    }

    my $num_columns = @$header;
    print "[GUI] Generating make columns dialog for $num_columns columns\n";

    # Make dialog
    my $dlg = Gtk2::Dialog->new("Choose columns", $wndMain, "modal", "gtk-cancel", "cancel", "gtk-ok", "ok");
    my $label = Gtk2::Label->new("<b>Select column types</b>\n(choose only one start matrix column)");
    $label->set_use_markup(1);
    $dlg->vbox->pack_start ($label, 0, 0, 0);

    # Make table
    my $table = Gtk2::Table->new(4,$num_columns + 1);
    $table->set_row_spacings(5);
    #$table->set_col_spacings(20);

    # Make scroll window for table
    my $scroll = Gtk2::ScrolledWindow->new;
    $scroll->add_with_viewport($table);
    $scroll->set_policy('automatic', 'never');
    $dlg->vbox->pack_start($scroll, 1, 1, 5);

    # Make header column
    $label = Gtk2::Label->new("<b>Column</b>");
    $label->set_use_markup(1);
    $label->set_alignment(1, 0.5);
    $table->attach_defaults($label, 0, 1, 0, 1);

    #$label = Gtk2::Label->new($type_options->[0]);
    #$label->set_alignment(1, 0.5);
    #$table->attach_defaults($label, 0, 1, 1, 2);
    #
    #$label = Gtk2::Label->new($type_options->[1]);
    #$label->set_alignment(1, 0.5);
    #$table->attach_defaults($label, 0, 1, 2, 3);
    #
    #$label = Gtk2::Label->new($type_options->[2]);
    #$label->set_alignment(1, 0.5);
    #$table->attach_defaults($label, 0, 1, 3, 4);
    
    my $iter = 0;
    foreach my $type (@$type_options) {
        $iter ++;
        $label = Gtk2::Label->new($type);
        $label->set_alignment(1, 0.5);
        $table->attach_defaults($label, 0, 1, $iter, $iter + 1);
    }

    # Add columns
    # use col_widgets to store the radio buttons, spinboxes
    my $col_widgets = [];
    foreach my $i (0..($num_columns - 1)) {
        my $header = ${$header}[$i];
        addColumn($col_widgets, $table, $i, $header);
    }

    $dlg->set_resizable(1);
    $dlg->set_default_size(500,0);
    $dlg->show_all();
    return ($dlg, $col_widgets);
}

sub addColumn {
    my ($col_widgets, $table, $colId, $header) = @_;

    # Column header
    my $label = Gtk2::Label->new("<tt>$header</tt>");
    $label->set_use_markup(1);

    # Type radio button
    my $radio1 = Gtk2::RadioButton->new(undef, '');        # Ignore
    my $radio2 = Gtk2::RadioButton->new($radio1, '');    # Label
    my $radio3 = Gtk2::RadioButton->new($radio2, '');    # Matrix start
    $radio1->set('can-focus', 0);
    $radio2->set('can-focus', 0);
    $radio3->set('can-focus', 0);

    # Attack to table
    $table->attach_defaults($label, $colId + 1, $colId + 2, 0, 1);
    $table->attach($radio1, $colId + 1, $colId + 2, 1, 2, 'shrink', 'shrink', 0, 0);
    $table->attach($radio2, $colId + 1, $colId + 2, 2, 3, 'shrink', 'shrink', 0, 0);
    $table->attach($radio3, $colId + 1, $colId + 2, 3, 4, 'shrink', 'shrink', 0, 0);

    # Store widgets
    $col_widgets->[$colId] = [$radio1, $radio2, $radio3];
}

1;