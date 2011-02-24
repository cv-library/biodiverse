package Biodiverse::GUI::PopupObject;

use strict;
use warnings;

our $VERSION = '0.16';

use Gtk2;

##########################################################
# Small object for the popup dialog. Passed to sources for
# them to put their data onto the list
##########################################################

sub setValueColumn {
    my $popup = shift;
    my $col = shift;
    my $list = $popup->{list};

    $list->{colValue}->clear_attributes($list->{valueRenderer}); #!!! This (bug?) cost me a lot of time
    $list->{colValue}->set_attributes($list->{valueRenderer}, text => $col) if $col;
    $popup->{value_column} = $col;
}

sub setListModel {
    my $popup = shift;
    my $model = shift;
    $popup->{list}->set_model($model);
}


1;