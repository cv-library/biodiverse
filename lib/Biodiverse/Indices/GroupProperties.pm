#  Summarise the group properties for a sample.
#  This is almost the same as LabelProperties
#  - need to abstract them to reduce maintenance burden.

package Biodiverse::Indices::GroupProperties;
use strict;
use warnings;

use Carp;

our $VERSION = '0.16';

use Biodiverse::Statistics;
my $stats_class = 'Biodiverse::Statistics';

use Data::Dumper;

sub get_metadata_get_gpp_stats_objects {
    my $self = shift;

    my $desc = 'Get the stats object for the property values '
             . " across both neighbour sets\n";
    my %arguments = (
        description     => $desc,
        name            => 'Group property stats objects',
        type            => 'Element Properties',
        pre_calc        => ['calc_element_lists_used'],
        uses_nbr_lists  => 1,  #  how many sets of lists it must have
        indices => {
            GPPROP_STATS_OBJECTS => {
                description => 'Hash of stats objects for the property values',
            },
        },
    );

    return wantarray ? %arguments : \%arguments;
}

sub get_gpp_stats_objects {
    my $self = shift;
    my %args = @_;

    my $element_list = $args{EL_LIST_ALL};

    my $bd = $self->get_basedata_ref;
    my $gp = $bd->get_groups_ref;

    my %stats_objects;
    my %data;
    #  process the properties and generate the stats objects
    foreach my $prop ($gp->get_element_property_keys) {
        my $key = $self->_get_gpprop_stats_hash_key(property => $prop);
        $stats_objects{$key} = $stats_class->new();
        $data{$prop} = [];
    }

    #  loop over the labels and collect arrays of their elements.
    #  These are then added to the stats objects to save it
    #  recalculating all its stats each time.
    my $count = 1;
    GROUP:
    foreach my $group (@$element_list) {
        my $properties = $gp->get_element_properties (element => $group);

        next GROUP if ! defined $properties;

        PROPERTY:
        while (my ($prop, $value) = each %$properties) {
            next PROPERTY if ! defined $value;

            my $data_ref = $data{$prop};
            push @$data_ref, ($value) x $count;
        }
    }
    
    ADD_DATA_TO_STATS_OBJECTS:
    foreach my $prop (keys %data) {
        my $stats_key = $self->_get_gpprop_stats_hash_key(property => $prop);
        my $stats = $stats_objects{$stats_key};
        my $data_ref = $data{$prop};
        $stats->add_data($data_ref);
    }

    my %results = (
        GPPROP_STATS_OBJECTS => \%stats_objects,
    );

    return wantarray ? %results : \%results;
}

sub _get_gpprop_stats_hash_key {
    my $self = shift;
    my %args = @_;
    my $prop = $args{property};
    return 'GPPROP_STATS_' . $prop . '_LIST';
}

sub _get_gpprop_names {
    my $self = shift;

    my $bd = $self->get_basedata_ref;
    my $gp = $bd->get_groups_ref;

    return $gp->get_element_property_keys;
}

sub _get_gpprop_stats_hash_keynames {
    my $self = shift;

    my $bd = $self->get_basedata_ref;
    my $gp = $bd->get_groups_ref;

    my %keys;
    #  what stats object names will we have?
    foreach my $prop ($gp->get_element_property_keys) {
        my $key = $self->_get_gpprop_stats_hash_key(property => $prop);
        $keys{$prop} = $key;
    }

    return wantarray ? %keys : \%keys;
}


sub get_metadata_calc_gpprop_lists {
    my $self = shift;

    my $desc = 'Lists of the groups and their property values '
             . 'used in the group properties calculations';

    my %indices;
    my %prop_hash_names = $self->_get_gpprop_stats_hash_keynames;
    while (my ($prop, $list_name) = each %prop_hash_names) {
        $indices{$list_name} = {
            $list_name => 'List of values for property ' . $prop,
            type       => 'list',
        };
    }

    my %arguments = (
        description     => $desc,
        name            => 'Group property lists',
        type            => 'Element Properties',
        pre_calc        => ['get_gpp_stats_objects'],
        uses_nbr_lists  => 1,
        indices         => \%indices,
    );

    return wantarray ? %arguments : \%arguments;
}

sub calc_gpprop_lists {
    my $self = shift;
    my %args = @_;

    #  just grab the hash from the precalc results
    my %objects = %{$args{GPPROP_STATS_OBJECTS}};
    my %results;

    while (my ($prop, $stats_object) = each %objects) {
        $results{$prop} = [ $stats_object->get_data() ];
    }

    return wantarray ? %results : \%results;
}


sub get_metadata_calc_gpprop_hashes {
    my $self = shift;

    my $desc = 'Hashes of the groups and their property values '
             . 'used in the group properties calculations. '
             . 'Hash keys are the property values, '
             . 'hash values are the property value frequencies.';

    my %indices;
    my %prop_hash_names = $self->_get_gpprop_stats_hash_keynames;
    while (my ($prop, $list_name) = each %prop_hash_names) {
        $list_name =~ s/LIST$/HASH/;
        $indices{$list_name} = {
            $list_name => 'Hash of values for property ' . $prop,
            type       => 'list',
        };
    }

    my %arguments = (
        description     => $desc,
        name            => 'Group property hashes',
        type            => 'Element Properties',
        pre_calc        => ['get_gpp_stats_objects'],
        uses_nbr_lists  => 1,
        indices         => \%indices,
    );
    
    #print Data::Dumper::Dump \%arguments;

    return wantarray ? %arguments : \%arguments;
}


#  data in hash form
sub calc_gpprop_hashes {
    my $self = shift;
    my %args = @_;

    #  just grab the hash from the precalc results
    my %objects = %{$args{GPPROP_STATS_OBJECTS}};
    my %results;

    while (my ($prop, $stats_object) = each %objects) {
        my @data = $stats_object->get_data();
        my $key = $prop;
        $key =~ s/LIST$/HASH/;
        foreach my $value (@data) {
            $results{$key}{$value} ++;
        }
    }

    return wantarray ? %results : \%results;
}


my @stats     = qw /count mean min max median sum standard_deviation/;
my %stat_name_short = (
    standard_deviation => 'SD',
);
my @quantiles = qw /10 20 30 40 50 60 70 80 90/;

sub get_metadata_calc_gpprop_stats {
    my $self = shift;

    my %indices;
    my %prop_hash_names = $self->_get_gpprop_stats_hash_keynames;
    while (my ($prop, $stat_pfx) = each %prop_hash_names) {
        $stat_pfx =~ s/LIST$//;
        foreach my $stat (@stats) {
            my $stat_name = exists $stat_name_short{$stat}
                        ? $stat_name_short{$stat}
                        : $stat;
            $stat_name = $stat_pfx . uc $stat_name;
            $indices{$stat_name} = {
                description => ucfirst $stat . ' of group property ' . $prop,
            };
        }
    }

    my $desc = 'Summary statistics for each group property across both neighbour sets';

    my %arguments = (
        description     => $desc,
        name            => 'Group property summary stats',
        type            => 'Element Properties',
        pre_calc        => ['get_gpp_stats_objects'],
        uses_nbr_lists  => 1,
        indices         => \%indices,
    );

    return wantarray ? %arguments : \%arguments;
}

sub calc_gpprop_stats {
    my $self = shift;
    my %args = @_;

    #  just grab the hash from the precalc results
    my %objects = %{$args{GPPROP_STATS_OBJECTS}};
    my %results;

    while (my ($prop, $stats_object) = each %objects) {
        my $pfx = $prop;
        $pfx =~ s/LIST$//;
        foreach my $stat (@stats) {
            my $stat_name = exists $stat_name_short{$stat}
                        ? $stat_name_short{$stat}
                        : $stat;

            $results{$pfx . uc $stat_name} = eval {$stats_object->$stat};
        }
    }

    return wantarray ? %results : \%results;
}


sub get_metadata_calc_gpprop_quantiles {
    my $self = shift;

    my %indices;
    my %prop_hash_names = $self->_get_gpprop_stats_hash_keynames;
    while (my ($prop, $stat_pfx) = each %prop_hash_names) {
        $stat_pfx =~ s/LIST$/Q/;
        foreach my $stat (@quantiles) {
            my $stat_name = $stat_pfx . $stat;
            $indices{$stat_name} = {
                description => $stat . 'th quantile of group property ' . $prop,
            };
        }
    }

    my $desc = 'Quantiles for each group property across both neighbour sets';

    my %arguments = (
        description     => $desc,
        name            => 'Group property quantiles',
        type            => 'Element Properties',
        pre_calc        => ['get_gpp_stats_objects'],
        uses_nbr_lists  => 1,
        indices         => \%indices,
    );

    return wantarray ? %arguments : \%arguments;
}

sub calc_gpprop_quantiles {
    my $self = shift;
    my %args = @_;

    #  just grab the hash from the precalc results
    my %objects = %{$args{GPPROP_STATS_OBJECTS}};
    my %results;

    while (my ($prop, $stats_object) = each %objects) {
        my $pfx = $prop;
        $pfx =~ s/LIST$/Q/;
        foreach my $stat (@quantiles) {
            $results{$pfx . $stat} = eval {$stats_object->percentile($stat)};
        }
    }

    return wantarray ? %results : \%results;
}


sub get_metadata_calc_gpprop_gistar {
    my $self = shift;

    my %indices;
    
    foreach my $prop ($self->_get_gpprop_names) {
        my $stat_name = 'GPPROP_GISTAR_' . $prop;
        $indices{$stat_name} = {
            description => 'Gi* score for group property ' . $prop,
        };
    }

    my $desc = 'Getis-Ord Gi* statistic for each group property across both neighbour sets';

    my %arguments = (
        description     => $desc,
        name            => 'Group property Gi* statistics',
        type            => 'Element Properties',
        pre_calc        => ['get_gpp_stats_objects'],
        pre_calc_global => [qw /_get_gpprop_global_summary_stats/],
        uses_nbr_lists  => 1,
        indices         => \%indices,
        reference       => 'need to add',
    );

    return wantarray ? %arguments : \%arguments;
}

sub calc_gpprop_gistar {
    my $self = shift;
    my %args = @_;

    my %results;

    my $global_hash   = $args{GPPROP_GLOBAL_SUMMARY_STATS};
    my %local_objects = %{$args{GPPROP_STATS_OBJECTS}};

    while (my ($prop, $global_data) = each %$global_hash) {
        #  bodgy - need generic method
        my $local_data = $local_objects{'GPPROP_STATS_' . $prop . '_LIST'};

        my $n  = $global_data->{count};  #  these are hash values
        my $W  = $local_data->count;     #  these are objects
        my $S1 = $W;  #  binary weights here
        my $sum = $local_data->sum;
        my $expected = $W * $global_data->{mean};

        my $numerator = $sum - $expected;

        my $denominator = $W
            ? $global_data->{standard_deviation}
                * sqrt (
                    (($n * $S1) - $W ** 2)
                    / ($n - 1)
                )
            : undef;
        
        my $res;
        if ($W) {
            $res = $denominator ? $numerator / $denominator : 0;
        }

        $results{'GPPROP_GISTAR_' . $prop} = $res;
    }

    return wantarray ? %results : \%results;
}

sub get_metadata__get_gpprop_global_summary_stats {
    my $self = shift;
    
    my $descr = 'Global summary stats for group properties';

    my %arguments = (
        description     => $descr,
        name            => $descr,
        type            => 'Element Properties',
        indices         => {
            GPPROP_GLOBAL_SUMMARY_STATS => {
                description => $descr,
            }
        },
    );

    return wantarray ? %arguments : \%arguments;
}

sub _get_gpprop_global_summary_stats {
    my $self = shift;

    my $bd = $self->get_basedata_ref;
    my $gp = $bd->get_groups_ref;
    my $hash = $gp->get_element_properties_summary_stats;
    
    my %results = (
        GPPROP_GLOBAL_SUMMARY_STATS => $hash,
    );
    
    return wantarray ? %results : \%results;
}


1;


__END__

=head1 NAME

Biodiverse::Indices::GroupProperties

=head1 SYNOPSIS

  use Biodiverse::Indices;

=head1 DESCRIPTION

Group property indices for the Biodiverse system.
It is inherited by Biodiverse::Indices and not to be used on it own.

See L<http://code.google.com/p/biodiverse/wiki/Indices> for more details.

=head1 METHODS

=over

=item INSERT METHODS

=back

=head1 REPORTING ERRORS

Use the issue tracker at http://www.purl.org/biodiverse

=head1 COPYRIGHT

Copyright (c) 2010 Shawn Laffan. All rights reserved.  

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

For a full copy of the license see <http://www.gnu.org/licenses/>.

=cut