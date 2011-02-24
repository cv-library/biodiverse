package Biodiverse::Spatial;

## This block of comments is out of date...
#  Package containing methods to analyse a Biodiverse::BaseStruct object using spatial arrangements
#  These are just a set of methods linked directly into a Biodiverse object,
#  putting the output into a BaseStruct object.
#  Many of the methods call Biodiverse::Indices methods, these are handled by
#  the Biodiverse::BaseStruct @ISA list.
#  Generally this will consist of creating surfaces of index values based on a set of groups
#  These group elements do not need to be the same as in the GROUPS sub-object,
#  so we keep them in a separate hash
#  Note that we have yet to define methods to load a seperate set of coords.

use strict;
use warnings;

use Carp;
use English qw { -no_match_vars };

use Data::Dumper;
use Scalar::Util qw /weaken blessed/;
#use Time::HiRes qw /tv_interval gettimeofday/;

our $VERSION = '0.16';

use Biodiverse::SpatialParams;
use Biodiverse::Progress;
use Biodiverse::Indices;

use base qw /Biodiverse::BaseStruct/;

my $empty_string = q{};



########################################################
#  Compare one spatial output object against another
#  Works only with lists generated from Indices
#  Creates new lists in the base object containing
#  counts how many times the base value was greater,
#  the number of comparisons,
#  and the ratio of the two.
#  This is designed for the randomisation procedure, but has more
#  general applicability

sub compare {
    my $self = shift;
    my %args = @_;

    #  make all numeric warnings fatal to catch locale/sprintf issues
    use warnings FATAL => qw { numeric };
    
    my $comparison = $args{comparison};
    croak "Comparison not specified\n" if not defined $comparison;
    
    my $result_list_pfx = $args{result_list_name};
    croak qq{Argument 'result_list_pfx' not speficied\n}
        if ! defined $result_list_pfx;

    my $progress = Biodiverse::Progress->new();
    my $progress_text = 'Comparing '
                        . $self->get_param ('NAME')
                        . ' with '
                        . $comparison->get_param ('NAME')
                        . "\n";
    $progress->update ($progress_text, 0);

    my $bd = $self->get_param ('BASEDATA_REF');

    #  drop out if no elements to compare with
    my $e_list = $self->get_element_list;
    return 1 if not scalar @$e_list;


    my %base_list_indices = $self->find_list_indices_across_elements;
    $base_list_indices{SPATIAL_RESULTS} = 'SPATIAL_RESULTS';

    #  now we need to calculate the appropriate result list name
    # for example RAND25>>SPATIAL_RESULTS
    foreach my $list_name (keys %base_list_indices) {
        $base_list_indices{$list_name} = $result_list_pfx . '>>' . $list_name;
    }

    
    my $to_do = $self->get_element_count;
    my $i = 0;

    #  easy way of handling recycled lists
    my %done_base; 
    my %done_comp;
    
    my $recycled_results
      =    $self->get_param ('RESULTS_ARE_RECYCLABLE')
        && $comparison->get_param ('RESULTS_ARE_RECYCLABLE');
    if ($recycled_results && exists $args{no_recycle}) {  #  mostly for debug 
        $recycled_results = $args{no_recycle};
    }

    if ($recycled_results) {  #  set up some lists
        foreach my $list_name (keys %base_list_indices) {
            $done_base{$list_name} = {};
            $done_comp{$list_name} = {};
        }
    }    

    COMP_BY_ELEMENT:
    foreach my $element ($self->get_element_list) {
        $i++;

        $progress->update (
            $progress_text . "(element $i / $to_do)",
            $i / $to_do,
        );

        #  now loop over the list indices
        BY_LIST:
        while (my ($list_name, $result_list_name) = each %base_list_indices) {

            next BY_LIST
                if    $recycled_results
                   && $done_base{$list_name}{$element}
                   && $done_comp{$list_name}{$element};

            my $base_ref = $self->get_list_ref (
                element     => $element,
                list        => $list_name,
                autovivify  => 0,
            );
            my $comp_ref = $comparison->get_list_ref (
                element     => $element,
                list        => $list_name,
                autovivify  => 0,
            );

            next BY_LIST if ! $base_ref || ! $comp_ref; #  nothing to compare with...

            next BY_LIST if (ref $base_ref) =~ /ARRAY/;

            my $results_ref = $self->get_list_ref (
                element => $element,
                list    => $result_list_name,
            );
    
            $self->compare_lists_by_item (
                base_list_ref     => $base_ref,
                comp_list_ref     => $comp_ref,
                results_list_ref  => $results_ref,
            );

            #  if results from both base and comp
            #  are recycled then we can recycle the comparisons
            if ($recycled_results) {
                my $nbrs = $self->get_list_ref (
                    element => $element,
                    list    => 'RESULTS_SAME_AS',
                );

                my $results_ref = $self->get_list_ref (
                    element => $element,
                    list    => $result_list_name,
                );

                BY_RECYCLED_NBR:
                foreach my $nbr (keys %$nbrs) {
                    $self->add_to_lists (
                        element           => $nbr,
                        $result_list_name => $results_ref,
                        use_ref           => 1,
                    );
                }
                my $done_base_hash = $done_base{$list_name};
                my $done_comp_hash = $done_comp{$list_name};
                @{$done_base_hash}{keys %$nbrs}
                    = values %$nbrs;
                @{$done_comp_hash}{keys %$nbrs}
                    = values %$nbrs;
            }
        }

    }

    $self->set_last_update_time;

    return 1;
}

sub find_list_indices_across_elements {
    my $self = shift;
    my %args = @_;
    
    my @lists = $self->get_lists_across_elements;
    
    my %index_hash;
    my %analyses_by_index = $self->get_index_source_hash;

    #  loop over the lists and find those that are generated by a calculation
    #  This ensures we get all of them if subsets are used.
    foreach my $list_name (@lists) {
        if (exists $analyses_by_index{$list_name}) {
            $index_hash{$list_name} = $list_name;
        }
    }

    return wantarray ? %index_hash : \%index_hash;
}



#
########################################################

########################################################
#  spatial calculation methods

sub run_analysis {
    my $self = shift;
    return $self->sp_calc(@_);
}

#  calculate one or more spatial indices based on
#  a set of neighbourhood parameters
sub sp_calc {  
    my $self = shift;
    my %args = @_;

    print "[SPATIAL] Running analysis "
          . $self->get_param('NAME')
          . "\n";

    #  don't store this arg if specified
    my $use_nbrs_from = $args{use_nbrs_from};
    delete $args{use_nbrs_from};  
    
    #  flag for use if we drop out.  Set to 1 on completion.
    $self->set_param (COMPLETED => 0);
    
    #  load any predefined args - overriding user specified ones
    my $ref = $self->get_param ('SP_CALC_ARGS');
    if (defined $ref) {
        %args = %$ref;
    }
    
    # a little backwards compatibility since we've changed the nomenclature
    if (! exists $args{calculations} && exists $args{analyses}) {
        $args{calculations} = $args{analyses};
    }
    
    my $no_create_failed_def_query = $args{no_create_failed_def_query};

    #  can we copy the results from one element to another?
    #  e.g. for non-overlapping blocks
    my @recyclable_nbrhoods;
    my $results_are_recyclable = 0;
    
    my $spatial_params_ref = $self->get_param ('SPATIAL_PARAMS');
    #  if we don't already have spatial params then check the arguments
    if (! defined $spatial_params_ref) {

        croak "spatial_conditions not an array ref or not defined\n"
          if not (ref $args{spatial_conditions}) =~ /ARRAY/;
            
        $spatial_params_ref = $args{spatial_conditions};
        my $check = 1;
        
        while ($check) {  #  clean up undef params at the end
            
            if (scalar @$spatial_params_ref == 0) {
                warn "[Spatial] No valid spatial conditions specified\n";
                #  put an empty string as the only entry,
                #  saves problems down the line
                $spatial_params_ref->[0] = $empty_string;
                return;
            }
            
            #my $param = $spatial_params_ref->[$#$spatial_params_ref];
            my $param = $spatial_params_ref->[-1];
            $param =~ s/^\s*//;  #  strip leading and trailing whitespace
            $param =~ s/\s*$//;
            if (! defined $param || $param eq "") {
                print "[SPATIAL] Deleting undefined spatial condition\n";
                pop @$spatial_params_ref;
            }
            else {
                $check = 0;  #  stop checking
            }
        }
        #  Now loop over them and:
        #  1.  parse the spatial params into objects if needed
        #  2.  check for recycling opportunities.
        #      These are for nbrs and results
        for my $i (0 .. $#$spatial_params_ref) {
            if (! blessed $spatial_params_ref->[$i]) {
                $spatial_params_ref->[$i]
                    = Biodiverse::SpatialParams->new (
                        conditions => $spatial_params_ref->[$i],
                    );


                #  nbrhood can be recycled if this nbrhood is non-overlapping
                #  (is constant for all nbrs in nbrhood)
                #  and so are its predecessors
                my $result_type = $spatial_params_ref->[$i]->get_result_type;

                my %recyc_candidates = (
                    non_overlapping  => 0,     # only index 0
                    always_true      => undef, # any index
                    text_match_exact => undef, # any index
                );

                my $prev_nbr_is_recyclable = 1;  #  always check first one
                if ($i > 0) {  #  only check $i if $i-1 is true
                    $prev_nbr_is_recyclable = $recyclable_nbrhoods[$i-1];
                }

                if (    $prev_nbr_is_recyclable
                     && exists $recyc_candidates{$result_type} ) {

                    # only those in the first nbrhood,
                    # or if the previous nbrhood is recyclable
                    # and we allow recyc beyond first index
                    my $is_valid_recyc_index =
                      defined $recyc_candidates{$result_type}
                      ? $i <= $recyc_candidates{$result_type}
                      : 1;

                    if ( $is_valid_recyc_index ) { 
                        $recyclable_nbrhoods[$i] = 1;
                        $results_are_recyclable ++;
                    }
                }
            }
        }
        $self->set_param (SPATIAL_PARAMS => $spatial_params_ref);
        delete $args{spatial_params};
        $spatial_params_ref = $self->get_param ('SPATIAL_PARAMS');
    }
    
    #  we can only recycle the results if all nbr sets are recyclable 
    if ($results_are_recyclable != scalar @$spatial_params_ref) {
        $results_are_recyclable = 0;
    }

    if (1 and $results_are_recyclable) {
        print '[SPATIAL] Results are recyclable.  '
              . "This will save some processing\n";
    }
    #  need a better name - unique to nbrhood? same_for_whole_nbrhood?
    $self->set_param( RESULTS_ARE_RECYCLABLE => $results_are_recyclable );
    
    #  check the definition query
    my $definition_query = $self->get_param ('DEFINITION_QUERY')
                           || $args{definition_query};

    if ($definition_query) {
        if (length ($definition_query) == 0) {
            $definition_query = undef ;
        }
        #  now parse the query into an object if needed
        elsif (not blessed $definition_query) {
            $definition_query = Biodiverse::SpatialParams->new (
                conditions => $definition_query,
            );
        }

        $self->set_param (DEFINITION_QUERY => $definition_query);
    }
    
    
    my $start_time = time;

    my $bd = $self->get_param ('BASEDATA_REF');

    my $indices_object = Biodiverse::Indices->new(BASEDATA_REF => $bd);

    my $use_list_count = scalar @$spatial_params_ref;
    $indices_object->get_valid_calculations (
        %args,
        use_list_count => $use_list_count,
    );

    #  drop out if we have none to do and we don't have an override flag
    croak "[SPATIAL] No valid analyses, dropping out\n"
        if (        $indices_object->get_valid_calculation_count == 0
            and not $args{override_valid_analysis_check});
    
    #  this is for the GUI
    $self->set_param (CALCULATIONS_REQUESTED => $args{calculations});
    #  save the args, but override the calcs so we only store the valid ones
    $self->set_param (
        SP_CALC_ARGS => {
            %args,
            calculations => scalar $indices_object->get_valid_calculations_to_run,
        }
    );

    #  don't pass these onwards when we call the calcs
    delete @args{qw /calculations analyses/};  

    print "[SPATIAL] sp_calc running analyses "
          . (join (q{ }, sort keys %{$indices_object->get_valid_calculations_to_run}))
          . "\n";

    #  use whatever spatial index the parent is currently using if nothing already set
    #  if the basedata object has no index, then we won't either
    if (not $self->exists_param ('SPATIAL_INDEX')) {
        $self->set_param (
            SPATIAL_INDEX => $bd->get_param ('SPATIAL_INDEX')
                             || undef,
        );
    }
    my $sp_index = $self->get_param ('SPATIAL_INDEX');

    #  use existing offsets if they exist
    #  (eg if this is a randomisation based on some original sp_calc)
    my $search_blocks_ref = $self->get_param ('INDEX_SEARCH_BLOCKS')
                            || [];
    $spatial_params_ref   = $self->get_param ('SPATIAL_PARAMS')
                            || [];
    
    #  get the global pre_calc results - move lower down?
    $indices_object->run_precalc_globals(%args);

    if (! $use_nbrs_from) {
        #  first look for a sibling with the same spatial parameters
        $use_nbrs_from = eval {
            $bd->get_spatial_outputs_with_same_nbrs (compare_with => $self);
        };
    }
    #  try again if we didn't get it before, 
    #  but this time check the index
    if (! $use_nbrs_from) {
        
        SPATIAL_PARAMS_LOOP:
        for my $i (0 .. $#$spatial_params_ref) {
            my $set_i = $i + 1;
            my $result_type = $spatial_params_ref->[$i]->get_result_type;
            
            if ($result_type eq 'always_true') {
                #  no point using the index if we have to get them all
                print "[SPATIAL] All groups are neighbours.  Index will be ignored for neighbour set $set_i.\n";
                next SPATIAL_PARAMS_LOOP;
            }
            elsif ($result_type eq 'self_only') {
                print "[SPATIAL] No neighbours, processing group only.  Index will be ignored for neighbour set $set_i.\n";
                next SPATIAL_PARAMS_LOOP;
            }
            elsif ($spatial_params_ref->[$i]->get_param ('INDEX_NO_USE')) { #  or if the conditions won't cooperate with the index
                print "[SPATIAL] Index set to be ignored for neighbour set $set_i.\n";  #  put this feedback in the spatialparams?
                next SPATIAL_PARAMS_LOOP;
            }
            
            my $searchBlocks = $search_blocks_ref->[$i];
            
            if (defined $sp_index && ! defined $searchBlocks) {
                print "[SPATIAL] Using spatial index\n" if $i == 0;
                my $progress_text_pfx = 'Neighbour set ' . ($i+1);
                $searchBlocks = $sp_index->predict_offsets (
                    spatial_params    => $spatial_params_ref->[$i],
                    cellsizes         => $bd->get_param ('CELL_SIZES'),
                    progress_text_pfx => $progress_text_pfx,
                );
                $search_blocks_ref->[$i] = $searchBlocks;
            }
        }
    }

    $self->set_param (INDEX_SEARCH_BLOCKS => $search_blocks_ref);
    
    #  If we are using neighbours from another spatial object
    #  then we use its recycle setting, and store it for later
    if ($use_nbrs_from) {
        $results_are_recyclable =
          $use_nbrs_from->get_param ('RESULTS_ARE_RECYCLABLE');
        $self->set_param (RESULTS_ARE_RECYCLABLE => $results_are_recyclable);
    }
    
    
    #  maybe we only have a few we need to calculate?
    my %elements_to_use;
    #my $calc_element_subset;
    if (defined $args{elements_to_calc}) {
        #$calc_element_subset = 1;
        my $elts = $args{elements_to_calc}; 
        if ((ref $elts) =~ /ARRAY/) {
            @elements_to_use{@$elts} = @$elts;
        }
        elsif ((ref $elts) =~ /HASH/) {
            %elements_to_use = %$elts;
        }
        else {
            $elements_to_use{$elts} = $elts;
        }
    }
    else {  #  this is a clunky way of doing all of them,
            # but we need the full set for GUI purposes for now
        my @gps = $bd->get_groups;
        @elements_to_use{@gps} = @gps;
    }
    
    my @elements_to_calc;
    my @elements_to_exclude;
    if ($args{calc_only_elements_to_calc}) { #  a bit messy but should save RAM 
        @elements_to_calc = keys %elements_to_use;
        my %elements_to_exclude_h;
        @elements_to_exclude_h{$bd->get_groups} = undef;
        delete @elements_to_exclude_h{@elements_to_calc};
        @elements_to_exclude = keys %elements_to_exclude_h;
    }
    else {
        @elements_to_calc = $bd->get_groups;
    }
    
    #EL: Set our CELL_SIZES
    # SL: modified for new structure
    if (! defined $self->get_param ('CELL_SIZES')) {
        $self->set_param (CELL_SIZES => $bd->get_param('CELL_SIZES'));
    }
    my $name = $self->get_param ('NAME');
    my $progress_text = $args{progress_text} || $name;
    
    #  create all the elements and the SPATIAL_RESULTS list
    my $toDo = scalar @elements_to_calc;
    #my $timer = [gettimeofday];
    print "[SPATIAL] Creating target groups\n";
    
    my $progress_text_create
        = $progress_text . "\nCreating target groups";
    
    #  check the elements against the definition query
    my $pass_def_query;
    
    if ($definition_query) {
        my $element = $elements_to_calc[0];

        $pass_def_query
          = $bd->get_neighbours(
                element        => $element,
                spatial_params => $definition_query,
                is_def_query   => 1,
            );
        $self->set_param (PASS_DEF_QUERY => $pass_def_query);
    }
    
    my $progress = Biodiverse::Progress->new();

    my $failed_def_query_sp_res_hash = {};
    my $elt_count = -1;
    GET_ELEMENTS_TO_CALC:
    foreach my $element (@elements_to_calc) {
        $elt_count ++;
        
        my $progress_so_far = $elt_count / $toDo;
        my $progress_text = "Spatial analysis $progress_text_create\n";
        $progress->update ($progress_text, $progress_so_far);

        my $sp_res_hash = {};
        if (        $definition_query
            and not exists $pass_def_query->{$element}) {
            
            if ($no_create_failed_def_query) {
                if ($args{calc_only_elements_to_calc}) {
                    push @elements_to_exclude, $element;
                }
                next GET_ELEMENTS_TO_CALC;
            }
            
            $sp_res_hash = $failed_def_query_sp_res_hash;
        }

        $self->add_element (element => $element);

        # initialise the spatial_results with an empty hash
        $self->add_to_lists (
            element         => $element,
            SPATIAL_RESULTS => $sp_res_hash,
        );

    }
    $progress->update (undef, 1);
    $progress->reset;


    local $| = 1;  #  write to screen as we go
    my $using_index_text = defined $sp_index ? "" : "\nNot using spatial index";

    my ($count, $printedProgress) = (0, -1);
    print "[SPATIAL] Progress (% of $toDo elements):     ";
    #$timer = [gettimeofday];    # to use with progress bar
    my $recyc_count = 0;

    #  loop though the elements and calculate the outputs
    #  Currently we don't allow user specified coords not in the basedata
    #  - this is for GUI reasons such as nbr selection
    BY_ELEMENT:
    foreach my $element (sort @elements_to_calc) {
        #last if $count > 5;  #  FOR DEBUG
        $count ++;
        
        my $progress_so_far = $count / $toDo;
        my $progress_text =
              "Spatial analysis $progress_text\n"
            . "($count / $toDo)"
            . "$using_index_text";
        $progress->update ($progress_text, $progress_so_far);

        #  don't calculate unless in the list
        next BY_ELEMENT if not $elements_to_use{$element};  

        #  check the definition query to decide if we should do this one
        if ($definition_query) {
            my $pass = exists $pass_def_query->{$element};
            next BY_ELEMENT if not $pass;
        }

        #  skip if we've already copied them across
        next if (
            $results_are_recyclable
            and
            $self->exists_list (
                element => $element,
                list    => 'RESULTS_SAME_AS',
            )
        );

        my @exclude;
        my @nbr_list;
        my $nbrs_already_recycled;
        foreach my $i (0 .. $#$spatial_params_ref) {
            my $nbr_list_name = '_NBR_SET' . ($i+1);
            #  useful since we can have non-overlapping neighbourhoods
            #  where we set all the results in one go
            if ($self->exists_list (
                    element => $element,
                    list    => $nbr_list_name
                )) {

                my $nbrs
                  = $self->get_list_values (
                      element => $element,
                      list => $nbr_list_name,
                  )
                  || [];

                $nbr_list[$i] = $nbrs;
                push @exclude, @$nbrs;
                $nbrs_already_recycled = 1;  #  flag so we don't re-set them
            }
            else {
                if ($use_nbrs_from) {
                    $nbr_list[$i] = $use_nbrs_from->get_list_values (
                        element => $element,
                        list    => $nbr_list_name,
                    );
                    if (! defined $nbr_list[$i]) {
                        $nbr_list[$i] = [];  #  use empty list if necessary
                    }
                }
                #  if $use_nbrs_from lacks the list, or we're finding the neighbours ourselves
                if (not defined $nbr_list[$i]) {  
                    my $list;
                    #  get everything
                    if ($spatial_params_ref->[$i]->get_result_type eq 'always_true') {  
                        $list = $bd->get_groups;
                    }
                    #  nothing to work with
                    elsif ($spatial_params_ref->[$i]->get_result_type eq 'always_false') {  
                        $list = [];
                    }
                    #  no nbrs, just oneself
                    elsif ($spatial_params_ref->[$i]->get_result_type eq 'self_only') {
                        $list = [$element];
                    }
                    
                    if ($list) {
                        my %tmp;  #  remove any that should not be there
                        my $excl = [@exclude, @elements_to_exclude];
                        @tmp{@$list} = (1) x @$list;
                        delete @tmp{@$excl};
                        $nbr_list[$i] = [keys %tmp];
                    }
                    else {    #  no nbr list thus far so go looking

                        #  don't use the index if there are no search blocks
                        my $sp_index_i
                          = defined $search_blocks_ref->[$i]
                          ? $sp_index
                          : undef;

                        #  go search
                        $nbr_list[$i] = $bd->get_neighbours_as_array (
                            element         => $element,
                            spatial_params  => $spatial_params_ref->[$i],
                            index           => $sp_index_i,
                            index_offsets   => $search_blocks_ref->[$i],
                            exclude_list    => [@exclude, @elements_to_exclude],
                        );
                    }
                    
                    #  Add to the exclude list unless we are at the last spatial param,
                    #  in which case it is no longer needed.
                    #  Hopefully this will save meaningful memory for large neighbour sets
                    if ($i != $#$spatial_params_ref) {
                        push @exclude, @{$nbr_list[$i]};
                    }
                }
                $self->add_to_lists (
                    element        => $element,
                    $nbr_list_name => $nbr_list[$i],
                );
            }
        }

        my %elements = (
            element_list1 => $nbr_list[0],
            element_list2 => $nbr_list[1],
        );

        #  this is the meat of it all
        my %sp_calc_values = $indices_object->run_calculations(%args, %elements);

        my $recycle_lists = {};

        #  now add the results to the appropriate lists
        foreach my $key (keys %sp_calc_values) {
            my $list_ref = $sp_calc_values{$key};

            if (ref ($list_ref) =~ /ARRAY|HASH/) {
                $self->add_to_lists (
                    element => $element,
                    $key    => $sp_calc_values{$key},
                );

                #  if we can recycle results, then store these results 
                if ($results_are_recyclable) {
                    $recycle_lists->{$key} = $sp_calc_values{$key};
                }

                delete $sp_calc_values{$key};
            }
        }
        #  everything else goes into this hash
        $self->add_to_lists (
            element         => $element,
            SPATIAL_RESULTS => \%sp_calc_values,
        );

        #  If the results can be recycled then assign them
        #  to the relevant groups now
        #  Note - only applies to groups in first nbr set
        my %nbrs_1;  #  the first nbr list as a hash
        if ($recyclable_nbrhoods[0]) {
            @nbrs_1{@{$nbr_list[0]}} = (1) x scalar @{$nbr_list[0]};
            #  Ignore those we aren't interested in
            #  - does not affect calcs, only recycled results.
            foreach my $nbr (keys %nbrs_1) {
                if (! exists $elements_to_use{$nbr}) {
                    delete $nbrs_1{$nbr};
                }
            }

            if (not $nbrs_already_recycled) {
                #  for each nbr in %nbrs_1,
                #  copy the neighbour sets for those that are recyclable
                $self->recycle_nbr_lists (
                    recyclable_nbrhoods => \@recyclable_nbrhoods,
                    nbr_lists           => \@nbr_list,
                    nbrs_1              => \%nbrs_1,
                    definition_query    => $definition_query,
                    pass_def_query      => $pass_def_query,
                    element             => $element,
                );
            }
        }
        if ($results_are_recyclable) {
            $recyc_count ++;
            $sp_calc_values{RECYCLED_SET} = $recyc_count;

            $recycle_lists->{SPATIAL_RESULTS} = \%sp_calc_values;
            $recycle_lists->{RESULTS_SAME_AS} = \%nbrs_1;

            $self->recycle_list_results (
                definition_query => $definition_query,
                pass_def_query   => $pass_def_query,
                list_hash        => $recycle_lists,
                nbrs_1           => \%nbrs_1,
            );
        }

        #  debug stuff
        #$self->_check_results_recycled_properly (
        #    element       => $element,
        #    use_nbrs_from => $use_nbrs_from,
        #    results_are_recyclable => $results_are_recyclable,
        #);
        
    }  #  end BY_ELEMENT

    $progress->reset;
    
    #  run any global post_calcs
    my %post_calc_globals = $indices_object->run_postcalc_globals (%args);


    #  this will cache as well
    my $lists = $self->get_lists_across_elements();

    my $time_taken = time - $start_time;
    print "[SPATIAL] Analysis took $time_taken seconds.\n";
    $self->set_param (ANALYSIS_TIME_TAKEN => $time_taken);

    #  sometimes we crash out but the object still exists
    #  this setting allows checks of completion status
    $self->set_param (COMPLETED => 1);
    
    $self->set_last_update_time;

    return 1;
}


#  recycle any list results
sub recycle_list_results {
    my $self = shift;
    my %args = @_;
    
    my $nbrs_1           = $args{nbrs_1};
    my $definition_query = $args{definition_query};
    my $pass_def_query   = $args{pass_def_query};
    my $list_hash        = $args{list_hash};

    RECYC_INTO_NBRS1:
    foreach my $nbr (keys %$nbrs_1) {
        if ($definition_query) {
            my $pass = exists $pass_def_query->{$nbr};
            next RECYC_INTO_NBRS1 if not $pass;
        }

        while (my ($listname, $list_ref) = each %$list_hash) {
            $self->add_to_lists (
                element   => $nbr,
                $listname => $list_ref,
                use_ref   => 1,
            );
        }
    }

    
    return;
}

sub recycle_nbr_lists {
    my $self = shift;
    my %args = @_;
    
    my $recyclable_nbrhoods = $args{recyclable_nbrhoods};
    my $nbr_lists           = $args{nbr_lists};
    my $nbrs_1              = $args{nbrs_1};
    my $definition_query    = $args{definition_query};
    my $pass_def_query      = $args{pass_def_query};
    my $element             = $args{element};
    
    #  for each nbr in %nbrs_1,
    #  copy the neighbour sets for those that overlap
    LOOP_RECYC_NBRHOODS:
    foreach my $i (0 .. $#$recyclable_nbrhoods) {
        #  all preceding must be recyclable
        last LOOP_RECYC_NBRHOODS
            if ! $recyclable_nbrhoods->[$i];  

        #  this is set above
        #next LOOP_RECYC_NBRHOODS if $nbrs_recycled;

        my $nbr_list_name = '_NBR_SET' . ($i+1);
        my $nbr_list_ref = $nbr_lists->[$i];

        LOOP_RECYC_NBRS:
        foreach my $nbr (keys %$nbrs_1) {
            #  don't append to processing element - we set it above
            next LOOP_RECYC_NBRS if $nbr eq $element;  

            if ($definition_query) {
                my $pass = exists $pass_def_query->{$nbr};
                next LOOP_RECYC_NBRS if not $pass;
            }

            #  recycle the array using a ref to save space
            $self->add_to_lists (
                element         => $nbr,
                $nbr_list_name  => $nbr_lists->[$i],
                use_ref         => 1,  
            );
        }
    }
    
    return;
}


#  internal sub to check results are recycled properly
#  Note - only valid for randomisations when nbrhood is
#  sp_self_only() or sp_select_all()
#  as other neighbourhoods result in varied results per cell
sub _check_results_recycled_properly {
    my $self = shift;
    my %args = @_;
    
    my $element = $args{element};
    my $use_nbrs_from = $args{use_nbrs_from};
    
    my $results_are_recyclable = $args{results_are_recyclable};

    if ($use_nbrs_from && $results_are_recyclable) {
        my $list1_ref = $self->get_list_ref (
            element => $element,
            list    => 'SPATIAL_RESULTS',
        );
        
        my $list2_ref = $use_nbrs_from->get_list_ref (
            element => $element,
            list    => 'SPATIAL_RESULTS',
        );
        
        while (my ($key, $value1) = each %$list1_ref) {
            my $value2 = $list2_ref->{$key};
            croak "$value1 != $value2, $element\n" if $value1 != $value2;
        }
    }
    
    return;
}


#
########################################################


sub get_embedded_tree {
    my $self = shift;
    
    my $args = $self->get_param ('SP_CALC_ARGS');

    return $args->{tree_ref} if exists $args->{tree_ref};

    return;
}

sub get_embedded_matrix {
    my $self = shift;
    
    my $args = $self->get_param ('SP_CALC_ARGS');

    return $args->{matrix_ref} if exists $args->{matrix_ref};

    return;
}

#sub numerically {$a <=> $b};
sub max {
    return $_[0] > $_[1] ? $_[0] : $_[1];
}

1;


__END__

=head1 NAME

Biodiverse::Spatial - a set of spatial functions for a
Biodiverse::BaseStruct object.  POD IS MASSIVELY OUT OF DATE

=head1 SYNOPSIS

  use Biodiverse::Spatial;

=head1 DESCRIPTION

These functions should be inherited by higher level objects through their @ISA
list.

MANY OF THESE HAVE BEEN MOVED BACK TO Biodiverse::BaseData.

=head2 Assumptions

Assumes C<Biodiverse::Common> is in the @ISA list.

Almost all methods in the Biodiverse library use {keyword => value} pairs as a policy.
This means some of the methods may appear to contain unnecessary arguments,
but it makes everything else more consistent.

List methods return a list in list context, and a reference to that list
in scalar context.

=head1 Methods

These assume you have declared an object called $self of a type that
inherits these methods, normally:

=over 4

=item  $self = Biodiverse::BaseData->new;

=back

=head2 Function Calls

=over 5

=item $self->add_spatial_output;

Adds a spatial output object to the list of spatial outputs.  This is of
type C<Biodiverse::BaseStruct>.

=item $self->get_spatial_outputs;

Returns the hash containing the Spatial Output names and their references.

=item $self->delete_spatial_output (name => 'somename');

Deletes the spatial output referred to as name C<somename>.  

=item $self->get_spatial_output_ref (name => $name);

Gets the reference to the named spatial output object.

=item $self->get_spatial_output_list;

Gets an array of the spatial output objects in this BaseData object.

=item $self->get_spatial_output_refs;

Gets an array of references to the spatial output objects in this
Biodiverse::BaseData object.  These are of type C<Biodiverse::BaseStruct>.

=item $self->get_spatial_output_names (name => 'somename');

Returns the reference to the named spatial output.
Returns C<undef> if it does not exist or if argument
C<name> is not specified.

=item $self->predict_offsets (spatial_paramshashref => $hash_ref);

Predict the maximum spatial distances needed to search based on an indexed
Groups object within the Basedata object.

The input hash can be generated using C<Biodiverse::Common::parse_spatial_params>,
and the index using C<Biodiverse::BaseData::build_index>.

=item $self->get_neighbours (element => $element, parsed_spatial_params => \%spatialParams, exclude_list => \@list);

Gets a hash of the neighbours around $element that satisfy the conditions
in %spatialParams.  Calls C<parse_spatial_params> if not specified.
The exclusion list is the set of elements not to be added.  This makes it
easy to avoid double counting of neighbours and simplifies spatial parameters
settings.

=item $self->get_neighbours_as_array (element => $element, parsed_spatial_params => \%spatialParams, exclude_list = \@list);

Returns an array instead of a hash.  Just calls get_neighbours and sorts the keys.

=item $self->get_distances (coord_array1 => $element1, coord_array2 => $element2);

ALL THIS IS OUT OF DATE.

Calculate the distances between the coords in two sets of elements using
parameters derived from C<Biodiverse::Common::parse_spatial_params>.

As of version 1 we only use Euclidean distance
denoted by $D, $D[0], $D[1], $d[0], $d[1] etc.  The actual values are
determined using C<Biodiverse::Spatial::get_distances>.

$D is the absolute euclidean distance across all dimensions.

$D[0], $D[1] and so forth are the absolute distance in dimension 0, 1 etc.
In most cases this $D[0] will be the X dimension, $D[1] will be the y dimension.

$d[0], $d[1] and so forth are the signed distance in dimension 0, 1 etc.
This allows us to extract all groups within some distance in some direction.
As with standard cartesion plots, negative values are to the left or below (west or south),
positive values to the right or above (east or north).
As with $D[0], $d[0] will normally be the X dimension,
$d[1] will be the y dimension.

=item $sp->sp_calc(calculations => \%calculations);

Calculate one or more spatial indices specified in %analyses using 
neighbourhood parameters stored in the objects's parameters.

The results are stored in spatial object $sp.

%analyses must have the same structure as that returned by
C<Biodiverse::Indices::get_calculations>.

Runs all available calculations if none are specified.

Any other arguments are passed straight through to the indices.

The C<cache_*> options allow the user to cache the element, label and ABC lists
for direct export,
although we will be adding methods to do this to save on storage space when it
is exported (perl stores hash keys in a global list, so there is
little overhead when using hash keys multiple times).

The ABC lists are stored by default, as it is useful to display them and all
the indices depend on them.

Scalar results are added to the Spatial Output object's SPATIAL_OUTPUT hash.
Any lists are added as separate lists in the object, rather than pollute
the SPATIAL_OUTPUT hash with additional lists.


=back

=head1 REPORTING ERRORS

I read my email frequently, so use that.  It should be pretty stable, though.

=head1 AUTHOR

Shawn Laffan

Shawn.Laffan@unsw.edu.au


=head1 COPYRIGHT

Copyright (c) 2006 Shawn Laffan. All rights reserved.  This
program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 REVISION HISTORY

=over 5

=item Version ???

May 2006.  Source libraries developed to the point where they can be
distributed.

=back

=cut