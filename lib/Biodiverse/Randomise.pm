package Biodiverse::Randomise;

#  methods to randomise a BaseData subcomponent

use strict;
use warnings;

use English ( -no_match_vars );

use Devel::Symdump;
use Data::Dumper qw { Dumper };
use Carp;
use POSIX qw { ceil floor };
use Time::HiRes qw { gettimeofday tv_interval };
use Scalar::Util qw { blessed };
#eval {use Data::Structure::Util qw /has_circular_ref get_refs/}; #  hunting for circular refs

require Biodiverse::BaseData;
use Biodiverse::Progress;

our $VERSION = '0.16';

my $EMPTY_STRING = q{};

require Biodiverse::Config;
my $progress_update_interval = $Biodiverse::Config::progress_update_interval;

use base qw {Biodiverse::Common};



sub new {
    my $class = shift;
    my %args = @_;

    #my %self;
    #my $self = {};
    my $self = bless {}, $class;

    if (defined $args{file}) {
        my $file_loaded = $self -> load_file (@_);
        return $file_loaded;
    }

    my %PARAMS = (  #  default parameters to load.  These will be overwritten as needed.
        OUTPFX              => 'BIODIVERSE_RANDOMISATION',  #  not really used anymore
        OUTSUFFIX           => 'brs',
        OUTSUFFIX_YAML      => 'bry',
        PARAM_CHANGE_WARN   => undef,
    );

    #  load the defaults, with the rest of the args as params
    my %args_for = (%PARAMS, %args);
    $self -> set_params (%args_for);

    #  avoid memory leak probs with circular refs
    $self -> weaken_basedata_ref;

    return $self;
}


sub _get_metadata_export {
    my $self = shift;

    #  need a list of export subs
    my %subs = $self -> get_subs_with_prefix (prefix => 'export_');

    #  hunt through the other export subs and collate their metadata
    my @export_sub_params;
    my @formats;
    my %format_labels;  #  track sub names by format label
    #  avoid double counting of options, and list is specified below
    my %done = (
        list    => 1,
        format  => 1,
        file    => 1,
    );
    
    foreach my $sub (sort keys %subs) {
        my %sub_args = $self -> get_args (sub => $sub);
        croak "Metadata item 'format' missing\n" if not defined $sub_args{format};
        
        my $params_array = $sub_args{parameters};
        foreach my $param_hash (@$params_array) {
            my $name = $param_hash->{name};
            if (!exists $done{$name}) {  #  does not allow mixed options and defaults etc - first in, best dressed
                push @export_sub_params, $param_hash;
                $done{$name} ++;
            }
        }
        
        push @formats, $sub_args{format};
        $format_labels{$sub_args{format}} = $sub; 
    }
    @formats = sort @formats;
    $self -> move_to_front_of_list (list => \@formats, item => 'Delimited text');

    my %args = (
        parameters => [ {
                name => 'file',
                type => 'file',
            },
            {
                name        => 'format',
                label_text  => 'What to export',
                type        => 'choice',
                choices     => \@formats,
                default     => 0,
            },
            @export_sub_params,
        ],
        format_labels => \%format_labels,
    );

    return wantarray ? %args : \%args;
}

#  same as Basestruct method - refactor needed
sub get_metadata_export {
    my $self = shift;

    #  need a list of export subs
    my %subs = $self -> get_subs_with_prefix (prefix => 'export_');

    my @formats;
    my %format_labels;  #  track sub names by format label

    #  loop through subs and get their metadata
    my %params_per_sub;
    
    LOOP_EXPORT_SUB:
    foreach my $sub (sort keys %subs) {
        my %sub_args = $self -> get_args (sub => $sub);

        my $format = $sub_args{format};

        croak "Metadata item 'format' missing\n"
            if not defined $format;

        $format_labels{$format} = $sub;

        next LOOP_EXPORT_SUB
            if $sub_args{format} eq $EMPTY_STRING;

        $params_per_sub{$format} = $sub_args{parameters};

        my $params_array = $sub_args{parameters};

        push @formats, $format;
    }
    
    @formats = sort @formats;
    $self -> move_to_front_of_list (
        list => \@formats,
        item => 'Initial PRNG state'
    );

    my %args = (
        parameters     => \%params_per_sub,
        format_choices => [{
                name        => 'format',
                label_text  => 'Format to use',
                type        => 'choice',
                choices     => \@formats,
                default     => 0
            },
        ],
        format_labels  => \%format_labels,
    ); 

    return wantarray ? %args : \%args;
}

sub export {
    my $self = shift;
    my %args = @_;
    
    #  get our own metadata...
    my %metadata = $self -> get_args (sub => 'export');
    
    my $sub_to_use = $metadata{format_labels}{$args{format}} || croak "Argument 'format' not specified\n";
    
    eval {$self -> $sub_to_use (%args)};
    croak $EVAL_ERROR if $EVAL_ERROR;
    
    return;
}

sub get_metadata_export_prng_init_state {
    my $self = shift;
    
    my %args = (
        format => 'Initial PRNG state',
        parameters => [{
                name       => 'file',
                type       => 'file'
            },
        ],
    );
    
    return wantarray ? %args : \%args;
}

sub export_prng_init_state {
    my $self = shift;
    my %args = @_;
    
    my $init_state = $self -> get_param ('RAND_INIT_STATE');
    
    my $filename = $args{file};
    
    open (my $fh, '>', $filename) || croak "Unable to open $filename\n";
    print {$fh} Data::Dumper::Dumper ($init_state);
    $fh -> close;
    
    print "[RANDOMISE] Dumped initial PRNG state to $filename\n";
    
    return;
}

sub get_metadata_export_prng_current_state {
    my $self = shift;
    
    my %args = (
        format => 'Current PRNG state',
        parameters => [{
                name       => 'file',
                type       => 'file'
            },
        ],
    );
    
    return wantarray ? %args : \%args;
}

sub export_prng_current_state {
    my $self = shift;
    my %args = @_;
    
    my $init_state = $self -> get_param ('RAND_LAST_STATE');
    
    my $filename = $args{file};
    
    open (my $fh, '>', $filename) || croak "Unable to open $filename\n";
    print {$fh} Data::Dumper::Dumper ($init_state);
    $fh -> close;
    
    print "[RANDOMISE] Dumped current PRNG state to $filename\n";
    
    return;
}

#  get a list of the all the publicly available randomisations.
sub get_randomisations {
    my $self = shift;

    #  get the @ISA array for the current object.
    # This allows inheritance from user defined packages
    #  __PACKAGE__ is the current package and makes life easier if we rename or move the sub
    my $isa_tree = __PACKAGE__ . Devel::Symdump::_isa_tree (__PACKAGE__);
    my @isa_tree = split (/\s+/, $isa_tree);
    
    my $syms = Devel::Symdump -> rnew(@isa_tree);

    my %analyses;
    
    foreach my $analysis (sort $syms -> functions) {
        next if $analysis !~ /^.*::rand_./;
        $analysis =~ s/(.*::)*//;
        #print "RANDOMISATION IS $analysis\n";
        $analyses{$analysis}++;
    }
    
    return wantarray ? %analyses : \%analyses;
}



#####################################################################
#
#  run the randomisation analysis for a set number of iterations,
#  comparing a set of spatial and tree objects in the basedata object

sub run_analysis {  #  flick them straight through
    my $self = shift;
    
    my $success = eval {$self -> run_randomisation  (@_)};
    croak $EVAL_ERROR if $EVAL_ERROR;
    
    return $success;
}

sub run_randomisation {
    my $self = shift;
    my %args = @_;
    
    my $bd = $self -> get_param ('BASEDATA_REF') || $args{basedata_ref};

    my $function = $self -> get_param ('FUNCTION')
                   || $args{function}
                   || croak "Randomisation function not specified\n";
    delete $args{function};  #  don't want to pass unnecessary args on to the function
    $self -> set_param (FUNCTION => $function);  #  store it
    
    my $iterations = $args{iterations} || 1;
    delete $args{iterations};
    
    my $max_iters = $args{max_iters};
    
    #print "\n\n\nMAXITERS IS $max_iters\n\n\n";
    
    my $rand = $self -> initialise_rand (%args);
    
    #  get a list of refs for objects that are to be compared
    #  get the lot by default
    my @targets = defined $args{targets}
                ? @{$args{targets}}
                : ($bd -> get_cluster_output_refs,
                   $bd -> get_spatial_output_refs,
                   );
    delete $args{targets};
    
    #  loop through and get all the key/value pairs that are not refs.
    #  Assume these are arguments to the randomisation
    my $single_level_args = "";
    foreach my $key (sort keys %args) {
        my $val = $args{$key};
        $val = 'undef' if not defined $val;
        if (not ref ($val)) {
            $single_level_args .= "$key=>$val,";
        }
    }
    $single_level_args =~ s/,$//;  #  remove any trailing comma
    
    my $results_list_name
        = $self -> get_param ('NAME')
        || $args{results_list_name}
        || uc (
            $function   #  add the args to the list name
            . (length $single_level_args
                ? "_$single_level_args"
                : $EMPTY_STRING)
            );

    #$results_list_name =~ s/^RAND/R/;  #  shorten the name

    #  counts are stored on the outputs, as they can be different if
    #    an output is created after some randomisations have been run
    my $rand_iter_param_name = "RAND_ITER_$results_list_name";
    
    my $total_iterations = $self -> get_param_as_ref ('TOTAL_ITERATIONS');
    if (! defined $total_iterations) {
        $self -> set_param (TOTAL_ITERATIONS => 0);
        $total_iterations = $self -> get_param_as_ref ('TOTAL_ITERATIONS');
    }

    ##$self -> find_circular_refs ($bd);
    
    my $return_success_code = 1;
    
    #  do stuff here
    ITERATION:
    foreach my $i (1 .. $iterations) {

        if ($max_iters && $$total_iterations >= $max_iters) {
            print "[RANDOMISE] Maximum iteration count reached: $max_iters\n";
            $return_success_code = 2;
            last ITERATION;
        }

        $$total_iterations++;

        print "[RANDOMISE] $results_list_name iteration $$total_iterations "
            . "($i of $iterations this run)\n";

        my $rand_bd = eval {
            $self -> $function (
                %args,
                rand_object => $rand,
                rand_iter   => $$total_iterations,
            );
        };
        croak $EVAL_ERROR if $EVAL_ERROR || ! defined $rand_bd;

        $rand_bd -> rename (
            name => $bd -> get_param ('NAME') . "_$function"."_$$total_iterations"
        );

        TARGET:
        foreach my $target (@targets) {
            my $rand_analysis;
            print "target: ", $target -> get_param ('NAME') || $target, "\n";

            next TARGET if ! defined $target;
            next TARGET if ! $target->can('run_analysis');
            my $completed = $target -> get_param ('COMPLETED');
            #  allow for older data sets that did not flag this
            $completed = 1 if not defined $completed;

            next TARGET if not $completed;  # skip this one, no analyses that worked
            
            my $rand_count
                = $i + ($target -> get_param($rand_iter_param_name) || 0);
            
            my $name
                = $target -> get_param ('NAME') . " Randomise $$total_iterations";
            my $progress_text
                = $target -> get_param ('NAME') . "\nRandomise $$total_iterations";
            
            #  create a new object of the same class
            my %params = $target -> get_params_hash;
            
            #  create the object and add it
            $rand_analysis = ref ($target) -> new (
                %params,
                NAME => $name,
            );

            my $check = $rand_bd -> add_output (
                %params,
                name    => $name,
                object  => $rand_analysis
            );

            eval {
                $rand_analysis -> run_analysis (
                    #progress        => $args{progress},
                    progress_text   => $progress_text,
                    use_nbrs_from   => $target,
                    #rand_object => $rand,
                )
            };
            croak $EVAL_ERROR if $EVAL_ERROR;
            
            eval {
                $target -> compare (
                    comparison       => $rand_analysis,
                    result_list_name => $results_list_name,
                    #progress         => $args{progress},
                )
            };
            croak $EVAL_ERROR if $EVAL_ERROR;
            
            #  and now remove this output to save a bit of memory
            #  unless we've been told to keep it
            #  (this has not been exposed to the GUI yet)
            if (! $args{retain_outputs}) {
                $rand_bd -> delete_output (output => $rand_analysis);
            }
        }
        
        #$self -> find_circular_refs_in_package;
        #$self -> find_circular_refs ($rand_bd);
        #$self -> find_circular_refs_above (top_level => 5);
        #use Devel::Refcount qw( refcount );
        #print "REFCOUNT IS " . refcount($rand_bd) . "\n";
        #print "";
        #use Devel::FindRef;
        #print Devel::FindRef::track $rand_bd;

        
        #  this argument is not yet exposed to the GUI
        if ($args{save_rand_bd}) {
            print "[Randomise] Saving randomised basedata\n";
            $rand_bd -> save;
        }
        
        #  save incremental basedata file
        if (   defined $args{save_checkpoint}
            && $$total_iterations =~ /$args{save_checkpoint}$/
            ) {

            print "[Randomise] Saving incremental basedata\n";
            my $file_name = $bd -> get_param ('NAME');
            $file_name .= '_' . $function . '_iter_' . $$total_iterations;
            eval {
                $bd -> save (filename => $file_name);
            };
            croak $EVAL_ERROR if $EVAL_ERROR;
        }

    }
    
    #  now we're done, increment the randomisation counts
    foreach my $target (@targets) {
        my $count = $target -> get_param ($rand_iter_param_name) || 0;
        $count += $iterations;
        $target -> set_param ($rand_iter_param_name => $count);
        #eval {$target -> clear_lists_across_elements_cache};
    }
    
    #  and keep a track of the randomisation state,
    #  even though we are storing the object
    #  this is just in case YAML will not work with MT::Auto
    $self -> store_rand_state (rand_object => $rand);
    
    #  return 1 if successful and ran some iterations
    #  return 2 if successful but did not need to run anything
    return $return_success_code;
}



#####################################################################
#
#  a set of functions to return a randomised basedata object

sub get_metadata_rand_nochange {
    my $self = shift;
    
    my %args = (
        Description => 'No change - just a cloned data set',
    );

    return wantarray ? %args : \%args;
}

#  does not actually change anything - handy for cluster trees to try different selections
sub rand_nochange {
    my $self = shift;
    my %args = @_;
    
    print "[RANDOMISE] Running 'no change' randomisation\n";
    
    my $bd = $self -> get_param ('BASEDATA_REF') || $args{basedata_ref};
    
    #  create a clone with no outputs
    my $new_bd = $bd -> clone (no_outputs => 1);
    
    return $new_bd;
}

sub get_metadata_rand_csr_by_group {
    my $self = shift;
    
    my %args = (
        Description => 'Complete spatial randomisation by group (currently ignores labels without a group)',
    ); 
    
    return wantarray ? %args : \%args;
}

sub rand_csr_by_group {  #  complete spatial randomness by group - just shuffles the subelement lists between elements
    my $self = shift;
    my %args = @_;
        
    my $bd = $self -> get_param ('BASEDATA_REF') || $args{basedata_ref};
    
    #my $progress_bar = $args{progress};
    #delete $args{progress};  #  the progress bar can get nasty if stored and then defrosted
    my $progress_bar = Biodiverse::Progress->new();
    
    my $rand = $args{rand_object};  #  can't store to all output formats and then recreate
    delete $args{rand_object};
    
    #  load any predefined args - overriding user specified ones
    my $ref = $self -> get_param ('ARGS');
    if (defined $ref) {
        %args = %$ref;
    }
    else {
        $self -> set_param (ARGS => \%args);
    }
    
    my $progress_text = "rand_csr_by_group: complete spatial randomisation\n";

    my $new_bd = blessed($bd)->new ($bd->get_params_hash);
    $new_bd->get_groups_ref->set_param ($bd -> get_groups_ref -> get_params_hash);
    $new_bd->get_labels_ref->set_param ($bd -> get_labels_ref -> get_params_hash);
    
    my @orig_groups = sort $bd -> get_groups;
    #my @tmp = @origData;  #  needed lest shuffle works on the origData in place
    #  make sure shuffle does not work on the original data
    my $randOrder = $rand -> shuffle ([@orig_groups]);

    print "[RANDOMISE] CSR Shuffling ".(scalar @orig_groups)." groups\n";

    #print join ("\n", @candidates) . "\n";
    
    my $total_to_do = $#orig_groups;
    my $last_update_time = [gettimeofday];
    
    foreach my $i (0 .. $#orig_groups) {
        
        #if ($progress_bar
        #    and tv_interval ($last_update_time) > $progress_update_interval) {
            
            my $progress = $i / $total_to_do;
            my $p_text
                = "$progress_text\n"
                . "Shuffling labels from\n"
                . "\t$orig_groups[$i]\nto\n\t$randOrder->[$i]\n"
                . "(element $i of $total_to_do)";

            $progress_bar -> update (
                $p_text,
                $progress,
            );
            #$last_update_time = [gettimeofday];
        #}
        
        #  create the group (this allows for empty groups with no labels)
        $new_bd -> add_element(group => $randOrder->[$i]);
        
        #  get the labels from the original group and assign them to the random group
        my %tmp = $bd -> get_labels_in_group_as_hash (group => $orig_groups[$i]);
        
        while (my ($label, $counts) = each %tmp) {
            $new_bd -> add_element(
                label => $label,
                group => $randOrder->[$i],
                count => $counts,
            );
        }
    }
    
    $self -> transfer_label_properties (
        %args,
        receiver => $new_bd,
    );

    return $new_bd;
    
}


sub get_metadata_rand_structured {
    my $self = shift;
    
    my $tooltip_mult =<<'END_TOOLTIP_MULT'
The target richness of each group in the randomised
basedata will be its original richness multiplied
by this value.
END_TOOLTIP_MULT
;

    my $tooltip_addn =<<'END_TOOLTIP_ADDN'
The target richness of each group in the randomised
basedata will be its original richness plus this value.

This is applied after the multiplier parameter so you have:
    target_richness = orig * multiplier + addition.
END_TOOLTIP_ADDN
;

    my %args = (
        parameters  => [ 
            {name       => 'richness_multiplier',
             type       => 'float',
             default    => 1,
             increment  => 1,
             tooltip    => $tooltip_mult,
             },
            {name       => 'richness_addition',
             type       => 'float',
             default    => 0,
             increment  => 1,
             tooltip    => $tooltip_addn,
             },
        ],
        Description => "Randomly allocate labels to groups,\n"
                       . 'but keep the richness the same or within '
                       . 'some multiplier factor.',
    );
    
    return wantarray ? %args : \%args;
}

#  randomly allocate labels to groups, but keep the richness the same or within some multiplier
sub rand_structured {
    my $self = shift;
    my %args = @_;
    
    my $start_time = [gettimeofday];
    
    my $bd = $self -> get_param ('BASEDATA_REF')
            || $args{basedata_ref};
    
    #my $progress_bar = $args{progress};  #  can't store to output file and then recreate
    #delete $args{progress};
    my $progress_bar = Biodiverse::Progress->new();
    
    my $rand = $args{rand_object};  #  can't store to all output formats and then recreate
    delete $args{rand_object};
    
    #  load any predefined args - overriding user specified ones
    my $ref = $self -> get_param ('ARGS');
    if (defined $ref) {
        %args = %$ref;
    }
    else {
        $self -> set_param (ARGS => \%args);
    }
    
    #  need to get these from the params if available
    my $multiplier = $args{richness_multiplier} || 1;
    my $addition = $args{richness_addition} || 0;
    my $name = $self -> get_param ('NAME');
    
    my $progress_text =<<"END_PROGRESS_TEXT"
$name
rand_structured:
\trichness multiplier = $multiplier,
\trichness addition = $addition
END_PROGRESS_TEXT
;
    

    my $new_bd = blessed($bd)->new ($bd -> get_params_hash);
    $new_bd -> get_groups_ref->set_param ($bd -> get_groups_ref -> get_params_hash);
    $new_bd -> get_labels_ref->set_param ($bd -> get_labels_ref -> get_params_hash);
    my $new_bd_name = $new_bd->get_param ('NAME');
    $new_bd -> rename (name => $new_bd_name . "_$name" . '');
    
    print "[RANDOMISE] Creating clone for destructive sampling\n";
    #if ($progress_bar) {
        $progress_bar -> update (
            "$progress_text\n"
            . "Creating clone for destructive sampling\n",
            0.1,
        );
    #}
    
    #  create a clone for destructive sampling
    #  clear out the outputs - we seem to get a memory leak otherwise
    my $cloned_bd = $bd -> clone (no_outputs => 1);
    
    $progress_bar->reset;
    
    #  make sure we randomly select from the same set of groups each time
    my @sorted_groups = sort $bd -> get_groups;
    #  make sure shuffle does not work on the original data
    my $rand_gp_order = $rand -> shuffle ([@sorted_groups]);
    
    my @sorted_labels = sort $bd -> get_labels;
    #  make sure shuffle does not work on the original data
    my $rand_label_order = $rand -> shuffle ([@sorted_labels]);
    
    print "[RANDOMISE] Richness Shuffling " . scalar @sorted_labels . " labels from " . (scalar @sorted_groups) . " groups\n";
    
    #  generate a hash with the target richness values
    my %target_richness;
    my $i = 0;
    my $total_to_do = scalar @sorted_groups;
    my $last_update_time = [gettimeofday];
    
    foreach my $group (@sorted_groups) {
        #if ($progress_bar
        #    and tv_interval ($last_update_time) > $progress_update_interval) {
            
            my $progress = $i / $total_to_do;
            
            $progress_bar -> update (
                "$progress_text\n"
                . "Assigning richness targets\n"
                . int (100 * $i / $total_to_do)
                . '%',
                  $progress,
            );
        #    $last_update_time = [gettimeofday];
        #}
        #  round threshold up to nearest integer
        #$target_richness{$group} = ceil (
        #    $bd -> get_richness (
        #        element => $group
        #    )
        #    * $multiplier
        #);
        #  no, don't round up, but maybe make it an option later
        #  round down
        $target_richness{$group} = floor (
            $bd -> get_richness (
                element => $group
            )
            * $multiplier
            + $addition
        );
        $i++;
    }

    $progress_bar->reset;

    #  algorithm:
    #  pick a label at random and then scatter its occurrences across
    #  other groups that don't already contain it
    #  and that does not exceed the richness threshold factor
    #  (multiplied by the original richness)
    
    my @target_groups = $bd -> get_groups;
    my %all_target_groups
        = $bd -> array_to_hash_keys (list => \@target_groups);
    my %filled_groups;
    my %unfilled_groups = %target_richness;
    my $last_filled = "";
    $i = 0;
    $total_to_do = scalar @$rand_label_order;
    print "[RANDOMISE] Target is $total_to_do.  Running.\n";

    BY_LABEL:
    foreach my $label (@$rand_label_order) {
        
        #if ($progress_bar
        #    and tv_interval ($last_update_time) > $progress_update_interval) {
            
            my $progress = $i / $total_to_do;
            $progress_bar -> update (
                "Allocating labels to groups\n"
                . "$progress_text\n"
                . "($i / $total_to_do)",
                $progress,
            );
        #    $last_update_time = [gettimeofday];
        #}
        $i++;

        ###  get the new groups not containing this label
        ###  - no point aiming for those that have it already
        ###  call will croak if label does not exist, so default to a blank hash
        my $new_bd_has_label
            = eval {$new_bd -> get_groups_with_label_as_hash (label => $label)}
            || {};

        #  cannot use $cloned_bd here, as it may not have the full set of groups yet
        my %target_groups = %all_target_groups;

        #  don't consider groups that are full or that already have this label
        if (scalar keys %$new_bd_has_label) {
            delete @target_groups{keys %$new_bd_has_label} ;
        }

        my $check = scalar keys %target_groups;
        my $check2 = $check;
        if (scalar keys %filled_groups) {
            delete @target_groups{keys %filled_groups};
            $check = scalar keys %target_groups;
        }
        @target_groups = sort keys %target_groups;

        ###  get the remaining original groups containing the original label.  Make sure it's a copy
        my %tmp
            = $cloned_bd -> get_groups_with_label_as_hash (label => $label);
        my $tmp_rand_order = $rand -> shuffle ([keys %tmp]);

        BY_GROUP:
        foreach my $from_group (@$tmp_rand_order) {
            my $count = $tmp{$from_group};

            #  select a group at random to assign to
            my $j = int ($rand -> rand (scalar @target_groups));
            my $to_group = $target_groups[$j];
            #  make sure we don't select this group again
            #  for this label this time round
            splice (@target_groups, $j, 1);


            #  drop out criterion, occurs when $richness_multiplier < 1
            last BY_GROUP if not defined $to_group;  

            warn "SELECTING GROUP THAT IS ALREADY FULL $to_group,"
                 . "$filled_groups{$to_group}, $target_richness{$to_group}, "
                 . "$check $check2 :: $i\n"
                    if defined $to_group and exists $filled_groups{$to_group};

            # assign this label to its new group
            $new_bd -> add_element (
                label => $label,
                group => $to_group,
                count => $count,
            );

            #  now delete it from the list of candidates
            $cloned_bd -> delete_sub_element (
                label => $label,
                group => $from_group,
            );
            delete $tmp{$from_group};

            #  check if we've filled this group.
            my $richness = $new_bd -> get_richness (element => $to_group);

            if ($richness >= $target_richness{$to_group}) {

                warn "ISSUES $to_group $richness > $target_richness{$to_group}\n"
                    if ($richness > $target_richness{$to_group});

                $filled_groups{$to_group} = $richness;
                delete $unfilled_groups{$to_group};
                $last_filled = $to_group;
            };

            last BY_GROUP if scalar @target_groups == 0;  #  no more targets for this label, move to next label
        }
    }
    #print "\n";

    my $target_label_count = $cloned_bd -> get_label_count;
    my $target_group_count = $cloned_bd -> get_group_count;

    my $format
        = "[RANDOMISE] \n"
          . "New: gps filled, gps unfilled. Old: labels to assign, gps not emptied\n"
          ."\t%d\t\t%d\t\t%d\t\t%d\n";

    printf $format,
           (scalar keys %filled_groups),
           (scalar keys %unfilled_groups),
           $target_label_count,
           $target_group_count;


    #  need to fill in the missing groups with empties
    if ($bd -> get_group_count != $new_bd -> get_group_count) {
        my %target_gps;
        @target_gps{$bd -> get_groups} = ((undef) x $bd -> get_group_count);
        delete @target_gps{$new_bd -> get_groups};

        my $count = scalar keys %target_gps;
        print '[Randomise structured] '
              . "Creating $count empty groups in new basedata\n";

        foreach my $gp (keys %target_gps) {
            $new_bd -> add_element (group => $gp);
        }
    }

    #$self -> find_circular_refs (label => "checker");


    $self -> swap_to_reach_targets (
        basedata_ref    => $bd,
        cloned_bd       => $cloned_bd,
        new_bd          => $new_bd,
        filled_groups   => \%filled_groups,
        unfilled_groups => \%unfilled_groups,
        #progress        => $progress_bar,
        rand_object     => $rand,
        target_richness => \%target_richness,
        progress_text   => $progress_text,
    );


    $self -> transfer_label_properties (
        %args,
        receiver => $new_bd
    );
    
    my $time_taken = sprintf "%d", tv_interval ($start_time);
    print "[RANDOMISE] Time taken for rand_structured: $time_taken seconds\n";

    #$self -> find_circular_refs_in_package;

    #  we used to have a memory leak somewhere, but this doesn't hurt anyway.    
    $cloned_bd = undef;

    return $new_bd;
}

sub swap_to_reach_targets {
    my $self = shift;
    my %args = @_;
    
    my $cloned_bd       = $args{cloned_bd};
    my $new_bd          = $args{new_bd};
    my %filled_groups   = %{$args{filled_groups}};
    my %unfilled_groups = %{$args{unfilled_groups}};
    my %target_richness = %{$args{target_richness}};
    #my $progress_bar    = $args{progress};
    my $rand            = $args{rand_object};
    my $progress_text   = $args{progress_text};

    my $bd = $self -> get_param ('BASEDATA_REF')
             || $args{basedata_ref};
    my $progress_bar = Biodiverse::Progress->new();
    
    #  and now we do some amazing cell swapping work to
    #  shunt labels in and out of groups until we're happy
    
    #  algorithm:
    #   Select an unassigned label.
    #   Find a group that does not contain it.
    #   Swap this label with one of the labels in the group if it is full.
    #   Repeat until we have no more to assign or all groups are full

    my $total_to_do =   (scalar keys %filled_groups)
                      + (scalar keys %unfilled_groups);
    
    if ($total_to_do) {
        print "[RANDOMISE] Swapping labels to reach richness targets\n";
    }


    my $swap_count = 0;
    my $last_filled = "";
    my $last_update_time = [gettimeofday];

    #  keep going until we've reached the fill threshold for each group
    BY_UNFILLED_GP:
    while (scalar keys %unfilled_groups) {
        #  keep a track of what's left
        #my @target_labels = $cloned_bd -> get_labels;  #  work with whatever is left
        #@target_groups = $cloned_bd -> get_groups;
        
        my $target_label_count = $cloned_bd -> get_label_count;
        my $target_group_count = $cloned_bd -> get_group_count; 

        #if ($progress_bar
        #    and tv_interval ($last_update_time) > $progress_update_interval) {
            
            my $precision = '%8d';
            my $fmt = "Total gps:\t\t\t$precision\n"
                        . "Unfilled groups:\t\t$precision\n"
                        . "Filled groups:\t\t$precision\n"
                        . "Labels to assign:\t\t$precision\n"
                        . "Old gps to empty:\t$precision\n"
                        . "Swap count:\t\t\t$precision\n"
                        . "Last group filled: %s\n";
            my $check_text
                = sprintf $fmt,
                    $total_to_do,
                    (scalar keys %unfilled_groups),
                    (scalar keys %filled_groups),
                    $target_label_count,
                    $target_group_count,
                    $swap_count,
                    $last_filled;

            my $progress_i = scalar keys %filled_groups;
            my $progress = $progress_i / $total_to_do;
            $progress_bar -> update (
                "Swapping labels to reach richness targets\n"
                . "$progress_text\n"
                . $check_text,
                $progress,
            );
        #    $last_update_time = [gettimeofday];
        #}

        if ($target_label_count == 0) {
            #  we ran out of labels before richness criterion is met,
            #  eg if multiplier is >1.
            print "[Randomise structured] No more Labels to assign\n";
            last BY_UNFILLED_GP;  
        }

        #  select an unassigned label and group pair
        my @labels = sort $cloned_bd -> get_labels;
        my $i = int $rand -> rand (scalar @labels);
        my $add_label = $labels[$i];
        my %from_groups_hash = $cloned_bd -> get_groups_with_label_as_hash (
            label => $add_label,
        );
        my @from_groups_array = sort keys %from_groups_hash;

        $i = int ($rand -> rand (scalar @from_groups_array));

        my $from_group = $from_groups_array[$i];
        my $add_count  = $from_groups_hash{$from_group};

        #  clear the pair out of cloned_self
        $cloned_bd -> delete_sub_element (
            group => $from_group,
            label => $add_label,
        );

        #  Now add this label to a group that does not already contain it.
        #  Ideally we want to find a group that has not yet
        #  hit its richness target, but that is unlikely wo we don't look anymore.
        #  Instead we select one at random.
        #  This also avoids the overhead of sorting and
        #  shuffling lists many times.
        my @target_groups
            = sort $new_bd -> get_groups_without_label (label => $add_label);
        $i = int $rand->rand(scalar @target_groups);
        my $target_group = $target_groups[$i];
        my $target_gp_richness
            = $new_bd -> get_richness (element => $target_group);

        ## the following used large amounts of time, and to no great effect
        ## as all the target groups were usually filled
        #my $target_list_shuffled = $rand -> shuffle ([sort @target_groups]);
        #
        ##  some defaults in case all targets are full
        #my $target_group = $target_list_shuffled->[0];
        #my $target_gp_richness
        #        = $new_bd -> get_richness (element => $target_group);
        #
        #BY_TARGET:
        #foreach my $target (@$target_list_shuffled) {
        #    #  skip if already full
        #    next BY_TARGET if exists $filled_groups{$target};
        #
        #    #  grab the first that fits the bill
        #    if ($target_gp_richness < $target_richness{$target_group}) {
        #        $target_group = $target;
        #        $target_gp_richness
        #            = $new_bd -> get_richness (element => $target);
        #        last BY_TARGET;
        #    }
        #}

        #  If the target group is at its richness threshold then
        #  we must first remove one label.
        #  Get a list of labels in this group and select one to remove.
        #  Preferably remove one that can be put into the unfilled groups.
        #  (Should move this to its own sub).
        if ($target_gp_richness >= $target_richness{$target_group})  {
            #  candidates to swap out are ideally
            #  those not in the unfilled groups
            #  (Do we want this?)
            my %labels_in_unfilled;
            foreach my $gp (keys %unfilled_groups) {
                my @list = $new_bd -> get_labels_in_group (group => $gp);
                @labels_in_unfilled{@list} = undef;
            }

            #$self -> find_circular_refs (label => 'tgt_gp_richness');

            #  we will remove one of these labels
            my %loser_labels = $new_bd -> get_labels_in_group_as_hash (
                group => $target_group,
            );
            my %loser_labels2 = %loser_labels;  #  keep a copy
            #  get those not in the unfilled groups
            delete @loser_labels{keys %labels_in_unfilled};

            #  use the lot if all labels are in the unfilled groups
            my $loser_labels_hash_to_use = ! scalar keys %loser_labels
                                            ? \%loser_labels2
                                            : \%loser_labels;

            my $loser_labels_array
                = $rand -> shuffle ([sort keys %$loser_labels_hash_to_use]);

            #  now we loop over the labels and choose the first one that
            #  can be placed in an unfilled group,
            #  otherwise just take the first one

            #  set some defaults
            my $remove_label  = $loser_labels_array->[0];
            my $removed_count = $loser_labels_hash_to_use->{$remove_label};
            my $swap_to_unfilled = undef;

            BY_LOSER_LABEL:
            foreach my $label (@$loser_labels_array) {
                #  find those unfilled groups without this label
                my %check_hash = $new_bd -> get_groups_without_label_as_hash (
                    label => $label,
                );

                delete @check_hash{keys %filled_groups};

                if (scalar keys %check_hash) {
                    $remove_label  = $label;
                    $removed_count = $loser_labels_hash_to_use->{$remove_label};
                    $swap_to_unfilled = $label;
                    last BY_LOSER_LABEL;
                }
            }

            #  Remove it from new_bd and add it to an unfilled group
            $new_bd -> delete_sub_element (
                label => $remove_label,
                group => $target_group,
            );

            if (! $swap_to_unfilled) {
                #  We can't swap it, so put it back into the
                #  unallocated lists.
                #  Use one of its old locations.
                #  (Just use the first one).
                my %old_groups
                    = $bd -> get_groups_with_label_as_hash (
                        label => $remove_label,
                    );

                my @cloned_self_gps_with_label
                    = $cloned_bd -> get_groups_with_label_as_hash (
                        label => $remove_label,
                    );

                #  make sure it does not add to an existing case
                delete @old_groups{@cloned_self_gps_with_label}; 
                my @old_gps = sort keys %old_groups;
                my $old_gp = shift @old_gps;
                $cloned_bd -> add_element   (
                    label => $remove_label,
                    group => $old_gp,
                    count => $removed_count,
                );
            }
            else {
                #  get a list of unfilled candidates to move it to
                #  do this by removing those that have the label
                #  from the list of unfilled groups
                my $gps_with_label = $new_bd -> get_groups_with_label (
                    label => $remove_label,
                )
                || [];

                my %unfilled_tmp = %unfilled_groups;
                delete @unfilled_tmp{@$gps_with_label};

                croak "ISSUES WITH RETURN GROUPS\n"
                    if (scalar keys %unfilled_tmp == 0);

                #  and get one of them at random
                $i = int $rand -> rand (scalar keys %unfilled_tmp);
                my @tmp = sort keys %unfilled_tmp;
                my $return_gp = $tmp[$i];

                # warn "$return_gp is already at the richness target\n"
                #    if ($new_bd -> get_richness (element => $return_gp)
                #        == $target_richness{$return_gp});

                #print "R: $remove_label, $return_gp, $removed_count\n";
                $new_bd -> add_element   (
                    label => $remove_label,
                    group => $return_gp,
                    count => $removed_count
                );

                my $new_richness = $new_bd -> get_richness (
                    element => $return_gp,
                );

                warn "ISSUES WITH RETURN $return_gp\n"
                    if $new_richness > $target_richness{$return_gp};

                if ($new_richness >= $target_richness{$return_gp}) {
                    #print "NEWLY FILLED GROUP $target_group\n"
                    #    if ! exists $filled_groups{$target_group};
                    $filled_groups{$return_gp} = $new_richness;
                    delete $unfilled_groups{$return_gp};  #  no effect if it's not in the list
                    $last_filled = $return_gp;
                    #print "Return: Last filled $last_filled\n";
                }
            }
            
            $swap_count ++;

            if (($swap_count % 500) == 0) {
                print "Swap count $swap_count\n";
            }
        }
        
        #  add the new label to new_bd
        #print "A: $add_label, $target_group, $add_count\n";
        $new_bd -> add_element (
            label => $add_label,
            group => $target_group,
            count => $add_count,
        );

        #  check if we've filled this group, if nothing was swapped out
        my $new_richness = $new_bd -> get_richness (element => $target_group);

        warn "ISSUES WITH TARGET $target_group\n"
            if $new_richness > $target_richness{$target_group};

        if ($target_gp_richness != $new_richness
            and $new_richness >= $target_richness{$target_group}) {
            #print "NEWLY FILLED GROUP $target_group\n"
            #    if ! exists $filled_groups{$target_group};
            $filled_groups{$target_group} = $new_richness;
            delete $unfilled_groups{$target_group};  #  no effect if it's not in the list
            $last_filled = $target_group;
            #print "Target: Last filled $last_filled\n";
        }
        
    }

    print "[Randomise structured] Final swap count is $swap_count\n";

    return;
}


#  sometimes we have label properties defined like species ranges.
#  need to copy these across
sub transfer_label_properties {
    my $self = shift;
    my %args = @_;
    
    my $to_bd = $args{receiver} || croak "Missing receiver argument\n";
    
    #my $progress_bar = $args{progress};
    my $progress_bar = Biodiverse::Progress->new();
    
    my $bd = $self -> get_param ('BASEDATA_REF') || $args{basedata_ref};

    my $labels_ref = $bd -> get_labels_ref;
    my $to_labels_ref = $to_bd -> get_labels_ref;
    
    my $last_update_time = [gettimeofday];
    
    my $labels = $bd -> get_labels;
    my $total_to_do = scalar @$labels;
    my $name = $bd -> get_param ('NAME');
    my $to_name = $to_bd -> get_param ('NAME');
    my $text = "Transferring label properties from $name to $to_name";
    
    print "[RANDOMISE] Transferring label properties for $total_to_do labels\n";
    
    my $count = 0;
    my $i = 0;
    
    BY_LABEL:
    foreach my $label (@$labels) {
        
        #if ($progress_bar
        #    and tv_interval ($last_update_time) > $progress_update_interval) {
            
            my $progress = $i / $total_to_do;
            $progress_bar -> update (
                "$text\n"
                . "(label $i of $total_to_do)",
                $progress
            );
        #    $last_update_time = [gettimeofday];
        #}
        
        #  avoid working with those not in the receiver
        next BY_LABEL if not $to_labels_ref -> exists_element (element => $label);
        
        my $props = $labels_ref -> get_list_values (
            element => $label,
            list => 'PROPERTIES'
        );
        
        next BY_LABEL if ! defined $props;  #  none there
        
        $to_labels_ref -> add_to_lists (
            element    => $label,
            PROPERTIES => {%$props},  #  make sure it's a copy so bad things don't happen
        );
        $count ++;
    }
    
    #$self -> find_circular_refs;
    
    return $count;
}




1;


__END__

=head1 NAME

Biodiverse::Randomise

=head1 SYNOPSIS

  use Biodiverse::Randomise;
  $object = Biodiverse::Randomise->new();

=head1 DESCRIPTION

TO BE FILLED IN

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