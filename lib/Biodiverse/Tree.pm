package Biodiverse::Tree;

#  Package to build and store trees.
#  includes clustering methods


use Carp;
use strict;
use warnings;
use Data::Dumper;
use Devel::Symdump;
use Scalar::Util;
#use Scalar::Util qw /looks_like_number/;
use Time::HiRes qw /tv_interval gettimeofday/;

use English qw ( -no_match_vars );

our $VERSION = '0.16';

our $AUTOLOAD;

use Statistics::Descriptive;
my $stats_class = 'Statistics::Descriptive::Full';

use Biodiverse::Matrix;
use Biodiverse::TreeNode;
use Biodiverse::BaseStruct;
use Biodiverse::Progress;

use base qw /
    Biodiverse::Common
    Biodiverse::Indices
/;

my $EMPTY_STRING = q{};


sub new {
    my $class = shift;

    my $self = bless {}, $class;

    my %args = @_;

    # do we have a file to load from?
    my $file_loaded;
    if (defined $args{file}) {
        $file_loaded = $self -> load_file(@_);
    }

    return $file_loaded if defined $file_loaded;
    
    my %PARAMS = (  #  default params
        TYPE => 'TREE',
        OUTSUFFIX => 'bts',
        OUTSUFFIX_YAML => 'bty',
        CACHE_TREE_AS_MATRIX => 1,
    );
    $self -> set_params (%PARAMS, %args);
    $self -> set_default_params;  #  load any user overrides
    
    
    $self->{TREE_BY_NAME} = {};

    #  avoid memory leak probs with circular refs to parents
    #  ensures children are destroyed when parent is destroyed
    $self->weaken_basedata_ref;  
    
    return $self;
}

sub rename {
    my $self = shift;
    my %args = @_;
    
    my $name = $args{new_name};
    if (not defined $name) {
        croak "[Tree] Argument 'name' not defined\n";
    }

    #  first tell the basedata object
    #my $bd = $self -> get_param ('BASEDATA_REF');
    #$bd -> rename_output (object => $self, new_name => $name);

    # and now change ourselves    
    $self -> set_param (NAME => $name);
    
}

#  need to flesh this out - total length, summary stats of lengths etc
sub describe {
    my $self = shift;
    
    my @description = (
        ['TYPE: ',
         blessed $self,
         ],
    );

    my @keys = qw /
        NAME
    /;

    foreach my $key (@keys) {
        my $desc = $self -> get_param ($key);
        if ((ref $desc) =~ /ARRAY/) {
            $desc = join q{, }, @$desc;
        }
        push @description, ["$key: ", $desc];
    }

    push @description, [
        "Node count: ",
        scalar @{$self -> get_node_refs},
    ];
    push @description, [
        "Terminal node count: ",
        scalar @{$self -> get_terminal_node_refs},
    ];
    push @description, [
        "Root node count: ",
        scalar @{$self -> get_root_node_refs}
    ];

    push @description, [
        "Sum of branch lengths: ",
        sprintf "%.4f", $self -> get_total_tree_length
    ];

    my $description;
    foreach my $row (@description) {
        $description .= join "\t", @$row;
        $description .= "\n";
    }
    
    return wantarray ? @description : $description;
}

#  sometimes we have to clean up the topology from the top down for each root node
#  this will ultimately give us a single root node where that should be the case
sub set_parents_below {
    my $self = shift;

    my @root_nodes = $self -> get_root_node_refs;

    foreach my $root_node ($self -> get_root_node_refs) {
        next if ! $root_node -> is_root_node;  #  may have been fixed on a previous iteration, so skip it
        $root_node -> set_parents_below;
    }
    
    #my @root_nodes2 = $self -> get_root_node_refs;
    #print "";
    return;
}

sub delete_node {
    my $self = shift;
    my %args = @_;
    
    #  get the node ref
    my $node_ref = $self -> get_node_ref (node => $args{node});
    return if ! defined $node_ref;  #  node does not exist anyway
    
    #  get the names of all descendents 
    my $node_hash = $node_ref -> get_all_children;
    $node_hash->{$node_ref -> get_name} = $node_ref;  #  add node_ref to this list
    
    #  now we delete it from the treenode structure.  This cleans up any children in the tree.
    $node_ref -> get_parent -> delete_child (child => $node_ref);
    
    #  now we delete it and its descendents from the node hash
    $self -> delete_from_node_hash (nodes => $node_hash);
    
    #  now we had better clear any cached values
    #  we could just do the DESCENDENTS lists, but they are not the
    #  only ones that point to now non-existent nodes
    $self -> get_tree_ref -> delete_cached_values_below;
    
    #  return a list of those deleted nodes
    return wantarray ? keys %$node_hash : [keys %$node_hash];
}

sub delete_from_node_hash {
    my $self = shift;
    my %args = @_;
    
    delete $self->{TREE_BY_NAME}{$args{node}} if $args{node};  #  defined $arg{node} implies single deletion
    
    my $arg_nodes_ref = ref $args{nodes};
    my @list;
    if ($arg_nodes_ref =~ /HASH/) {
        @list = keys %{$args{nodes}};
    }
    elsif ($arg_nodes_ref =~ /ARRAY/) {
        @list = @{$args{nodes}};
    }
    else {
        @list = $args{nodes};
    }
    delete @{$self->{TREE_BY_NAME}}{@list};
    
    return;
}

#  add a new TreeNode to the hash, return it
sub add_node {
    my $self = shift;
    my %args = @_;
    my $node = $args{node_ref} || Biodiverse::TreeNode -> new (@_);
    $self -> add_to_node_hash (node_ref => $node);
    return $node;
}

sub add_to_node_hash {
    my $self = shift;
    my %args = @_;
    my $nodeRef = $args{node_ref};
    my $name = $nodeRef -> get_name;
    
    croak "[TREE] Node $name already exists\n" if $self -> exists_node (@_);
    
    $self->{TREE_BY_NAME}{$name} = $nodeRef;
    return $nodeRef if defined wantarray;
}

#  does this node exist already?
sub exists_node {
    my $self = shift;
    my %args = @_;
    my $name = $args{name};
    if (not defined $name and defined $args{node_ref}) {
        $name = $args{node_ref} -> get_name;
    }
    else {
        return;
    }
    return exists $self->{TREE_BY_NAME}{$name};
}

#  get a single root node - assumes we only care about one if we use this approach.
#  the sort ensures we get the same one each time.
sub get_tree_ref {
    my $self = shift;
    if (! defined $self->{TREE}) {
        my %root_nodes = $self -> get_root_nodes;
        my @keys = sort keys %root_nodes;
        return undef if not defined $keys[0];  #  no tree ref yet
        $self->{TREE} = $root_nodes{$keys[0]};
    }
    return $self->{TREE};
}

sub get_tree_depth {  #  traverse the tree and calculate the maximum depth
                      #  need ref to the root node
    my $self = shift;
    my $treeRef = $self -> get_tree_ref;
    return if ! defined $treeRef ;
    return $treeRef -> get_depth_below;
}

sub get_tree_length {  # need ref to the root node
    my $self = shift;
    my $tree_ref = $self -> get_tree_ref;
    return if ! defined $tree_ref;
    return $tree_ref -> get_length_below;
}

#  this is going to supersede get_tree_length because it is a better name
sub get_length_to_tip {
    my $self = shift;

    return $self->get_tree_length;
}

sub get_terminal_elements {  #  get the terminal elements below this node
                           #  if not a TreeNode reference, then return a
                           #  hash ref containing only this node
    my $self = shift;
    my %args = (cache => 1, @_);  #  cache by default
    my $node = $args{node} || croak "node not specified\n";
    my $nodeRef = $self->get_node_ref(node => $node);
    if (defined $nodeRef) {
        return $nodeRef -> get_terminal_elements (cache => $args{cache});
    }
    else {
        my %hash = ($node => $nodeRef);
        return wantarray ? %hash : \%hash;
    }
}

    
sub get_node_ref {
    my $self = shift;
    my %args = @_;
    croak "node not specified\n" if ! defined $args{node};
    if (exists $self->{TREE_BY_NAME}{$args{node}}) {
        return $self->{TREE_BY_NAME}{$args{node}};
    }
    else {
        croak "[Tree] Cannot find node $args{node}\n";
    }
}

#  used when importing from a BDX file, as they don't keep weakened refs weak.
#  not anymore - let the destroy method handle it
sub weaken_parent_refs {
    my $self = shift;
    my $nodeList = $self->get_node_hash;
    foreach my $nodeRef (values %$nodeList) {
        $nodeRef->weaken_parent_ref;
    }
}

sub get_node_count {
    my $self = shift;
    return my $tmp = keys %{$self->get_node_hash};
}

sub get_node_hash {
    my $self = shift;
    
    #  create an empty hash if needed
    $self->{TREE_BY_NAME} = {} if ! exists $self->{TREE_BY_NAME};
    
    return wantarray ? %{$self->{TREE_BY_NAME}} : $self->{TREE_BY_NAME};
}

sub get_node_refs {
    my $self = shift;
    my @refs = values %{$self -> get_node_hash};

    return wantarray ? @refs : \@refs;
}


#  get a hash of node refs indexed by their total length
sub get_node_hash_by_total_length {
    my $self = shift;
    
    my %by_value;
    while ((my $node_name, my $node_ref) = each (%{$self->get_node_hash})) {
        #  uses total_length param if exists
        my $value = $node_ref -> get_length_below;  
        $by_value{$value}{$node_name} = $node_ref;
    }
    
    return wantarray ? %by_value : \%by_value;
}

#  get a hash of node refs indexed by their depth below (same order meaning as total length)
sub get_node_hash_by_depth_below {
    my $self = shift;
    
    my %by_value;
    while ((my $node_name, my $node_ref) = each (%{$self->get_node_hash})) {
        my $depth = $node_ref -> get_depth_below;
        $by_value{$depth}{$node_name} = $node_ref;
    }
    return wantarray ? %by_value : \%by_value;
}


#  get a hash of node refs indexed by their depth
sub get_node_hash_by_depth {
    my $self = shift;
    
    my %by_value;
    while ((my $node_name, my $node_ref) = each (%{$self->get_node_hash})) {
        my $depth = $node_ref -> get_depth;
        $by_value{$depth}{$node_name} = $node_ref;
    }

    return wantarray ? %by_value : \%by_value;
}

#  get a set of stats for one of the hash lists in the tree.  
sub get_list_stats {
    my $self = shift;
    my %args = @_;
    my $list = $args{list}   || croak "List not specified\n";
    my $index = $args{index} || croak "Index not specified\n";

    my @data;
    foreach my $node (values %{$self -> get_node_hash}) {
        my $list_ref = $node -> get_list_ref (list => $list);
        next if ! defined $list_ref;
        next if ! exists  $list_ref->{$index};
        next if ! defined $list_ref->{$index};  #  skip undef values
        
        push @data, $list_ref->{$index};
    }
    
    my %stats_hash = (
        MAX  => undef,
        MIN  => undef,
        MEAN => undef,
        SD   => undef,
    );

    if (scalar @data) {  #  don't both if they are all undef
        my $stats = $stats_class->new;
        $stats -> add_data (\@data);
        
        %stats_hash = (
            MAX  => $stats -> max,
            MIN  => $stats -> min,
            MEAN => $stats -> mean,
            SD   => $stats -> standard_deviation,
        );
    }
    
    return wantarray ? %stats_hash : \%stats_hash;
}

#  return 1 if the tree contains a node with the specified name 
sub node_is_in_tree {
    my $self = shift;
    my %args = @_;

    my $node_name = $args{node};

    #  node cannot exist if it has no name...
    croak "node name undefined\n"
      if !defined $node_name;  
    
    my $node_hash = $self -> get_node_hash;
    return exists $node_hash->{$node_name};
}


sub get_terminal_nodes {
    my $self = shift;
    my %nodeList;
    
    while ((my $node, my $nodeRef) = each (%{$self->get_node_hash})) {
        next if ! $nodeRef -> is_terminal_node;
        $nodeList{$node} = $nodeRef;
    }
    
    return wantarray ? %nodeList : \%nodeList;
}

sub get_terminal_node_refs {
    my $self = shift;
    my @nodeList;
    
    while ((my $node, my $nodeRef) = each (%{$self->get_node_hash})) {
        next if ! $nodeRef -> is_terminal_node;
        push @nodeList, $nodeRef;
    }
    
    return wantarray ? @nodeList : \@nodeList;
}

sub get_root_nodes {  #  if there are several root nodes
    my $self = shift;
    my %nodeList;
    my $node_hash = $self->get_node_hash;
    
    while ((my $node, my $nodeRef) = each (%$node_hash)) {
        next if (! defined $nodeRef);
        $nodeList{$node} = $nodeRef if $nodeRef -> is_root_node;
        #my $check = $nodeRef -> is_root_node;
        #print "";
    }
    
    return wantarray ? %nodeList : \%nodeList;
}

sub get_root_node_refs {
    my $self = shift;
    
    my @refs = values %{$self -> get_root_nodes};
    
    return wantarray ? @refs : \@refs;
}

#  get all nodes that aren't internal
sub get_named_nodes {
    my $self = shift;
    my %node_list;
    my $node_hash = $self -> get_node_hash;
    while (my ($node, $node_ref) = each (%$node_hash)) {
        next if $node_ref -> is_internal_node;
        $node_list{$node} = $node_ref;
    }
    return wantarray ? %node_list : \%node_list;
}

#  get all the nodes that aren't terminal nodes
sub get_branch_nodes {
    my $self = shift;
    my %node_list;
    my $node_hash = $self -> get_node_hash;
    while (my ($node, $node_ref) = each (%$node_hash)) {
        next if $node_ref -> is_terminal_node;
        $node_list{$node} = $node_ref;
    }
    return wantarray ? %node_list : \%node_list;
}

sub get_branch_node_refs {
    my $self = shift;
    my @nodeList;
    while ((my $node, my $nodeRef) = each (%{$self->get_node_hash})) {
        next if $nodeRef -> is_terminal_node;
        push @nodeList, $nodeRef;
    }
    return wantarray ? @nodeList : \@nodeList;
}

#  get an internal node name that is not currently used
sub get_free_internal_name {
    my $self = shift;
    my %args = @_;
    my $skip = $args{exclude} || {};
    
    #  iterate over the existing nodes and get the highest internal name that isn't used
    #  also check the whole translate table (keys and values) to ensure no
    #    overlaps with valid user defined names
    my %node_hash = $self -> get_node_hash;
    my $highest = -1;
    foreach my $name (keys %node_hash, %$skip) {
        if ($name =~ /^(\d+)___$/) {
            my $num = $1;
            next if not defined $num;
            $highest = $num if $num > $highest;
        }
    }
    $highest ++;
    return $highest . '___';
}


###########

sub export {
    my $self = shift;
    my %args = @_;
    
    croak "[TREE] Export:  Argument 'file' not specified or null\n"
        if not defined $args{file}
            || length ($args{file}) == 0;

    #  get our own metadata...
    my %metadata = $self -> get_args (sub => 'export');
    
    my $sub_to_use = $metadata{format_labels}{$args{format}}
      || croak "Argument 'format' not specified\n";
    
    #  remap the format name if needed - part of the matrices kludge
    if ($metadata{component_map}{$args{format}}) {
        $args{format} = $metadata{component_map}{$args{format}};
    }

    eval {
        $self -> $sub_to_use (%args)
    };
    croak $EVAL_ERROR if $EVAL_ERROR;
    
    return;
}

sub get_metadata_export {
    my $self = shift;

    #  get the available lists
    #my @lists = $self -> get_lists_for_export;

    #  need a list of export subs
    my %subs = $self -> get_subs_with_prefix (prefix => 'export_');

    #  (not anymore)
    my @formats;
    my %format_labels;  #  track sub names by format label
    
    #  loop through subs and get their metadata
    my %params_per_sub;
    my %component_map;
    
    LOOP_EXPORT_SUB:
    foreach my $sub (sort keys %subs) {
        my %sub_args = $self -> get_args (sub => $sub);

        my $format = $sub_args{format};

        croak "Metadata item 'format' missing\n"
          if not defined $format;

        $format_labels{$format} = $sub;

        next LOOP_EXPORT_SUB
          if $sub_args{format} eq $EMPTY_STRING;

        my $params_array = $sub_args{parameters};
        
        #  Need to raise the matrices args
        #  This is extremely kludgy as it assumes there is only one
        #  output format for matrices
        if ((ref $params_array) =~ /HASH/) {
            my @values = values %$params_array;
            my @keys   = keys   %$params_array;
            
            $component_map{$format} = shift @keys;
            $params_array = shift @values;
        }

        $params_per_sub{$format} = $params_array;

        push @formats, $format;
    }
    
    @formats = sort @formats;
    $self -> move_to_front_of_list (
        list => \@formats,
        item => 'Nexus'
    );

    my %args = (
        parameters     => \%params_per_sub,
        format_choices => [
            {
                name        => 'format',
                label_text  => 'Format to use',
                type        => 'choice',
                choices     => \@formats,
                default     => 0
            },
        ],
        format_labels  => \%format_labels,
        component_map  => \%component_map,
    ); 

    return wantarray ? %args : \%args;
}



sub get_lists_for_export {
    my $self = shift;
    
    my @sub_list;  #  get a list of available sub_lists (these are actually hashes)
    #foreach my $list (sort $self -> get_hash_lists) {
    foreach my $list (sort $self -> get_list_names_below) {  #  get all lists
        if ($list eq 'SPATIAL_RESULTS') {
            unshift @sub_list, $list;
        }
        else {
            push @sub_list, $list;
        }
    }
    unshift @sub_list, '(no list)';
    
    return wantarray ? @sub_list : \@sub_list;
}


sub get_metadata_export_nexus {
    my $self = shift;
    
    my %args = (
        format => 'Nexus',
        parameters => [
            {
                name        => 'use_internal_names',
                label_text  => 'Label internal nodes',
                tooltip     => 'Should the internal node labels be included?',
                type        => 'boolean',
                default     => 1,
            },
        ],
    );
    
    return wantarray ? %args : \%args;
}

sub export_nexus {
    my $self = shift;
    my %args = @_;

    my $file = $args{file};
    print "[TREE] WRITING TO TREE TO NEXUS FILE $file\n";
    open (my $fh, '>', $file)
        || croak "Could not open file '$file' for writing\n";

    print {$fh}
        $self -> to_nexus (
            tree_name => $self -> get_param ('NAME'),
            %args,
        );

    $fh -> close;

    return;
}


sub get_metadata_export_newick {
    my $self = shift;
    
    my %args = (
        format => 'Newick',
        parameters => [
            {
                name        => 'use_internal_names',
                label_text  => 'Label internal nodes',
                tooltip     => 'Should the internal node labels be included?',
                type        => 'boolean',
                default     => 1,
            },
        ],
    );
    
    return wantarray ? %args : \%args;
}

sub export_newick {
    my $self = shift;
    my %args = @_;

    my $file = $args{file};
    
    print "[TREE] WRITING TO TREE TO NEWICK FILE $file\n";
    
    open (my $fh, '>', $file) || croak "Could not open file '$file' for writing\n";
    print {$fh} $self -> to_newick (%args);
    $fh -> close;

    return;
}

sub get_metadata_export_tabular_tree {
    my $self = shift;

    my %args = (
        format => 'Tabular tree',
        parameters => [
            $self -> get_lists_export_metadata(),
            $self -> get_table_export_metadata(),
        ],
    );
    
    return wantarray ? %args : \%args;
}

#  generic - should be factored out
sub export_tabular_tree {
    my $self = shift;
    my %args = @_;
    
    my $name = $args{name};
    if (! defined $name) {
        $name = $self -> get_param ('NAME');
    }
    
    my $table = $self -> to_table (
        symmetric   => 1,
        name        => $name,
        %args,
    );

    $self -> write_table_csv (%args, data => $table);
    
    return;
}


sub get_metadata_export_table_grouped {
    my $self = shift;
    
    my %args = (
        format => 'Table grouped',
        parameters => [
            $self -> get_lists_export_metadata(),
            {
                name        => 'num_clusters',
                label_text  => 'Number of groups',
                type        => 'integer',
                default     => 5
            },
            {
                name        => 'use_target_value',
                label_text  => 'Define groups by length or depth',
                tooltip     => 'Overrides the "Number of groups" setting',
                type        => 'boolean',
                default     => 0,
            },
            {
                name        => 'target_value',
                label_text  => 'Value for length/depth',
                type        => 'float',
                default     => 0,
            },
            {
                name        => 'group_by_depth',
                label_text  => "Group clusters by depth\n(default is by length)",
                type        => 'boolean',
                default     => 0,
            },
            {
                name        => 'symmetric',
                label_text  => 'Force output table to be symmetric',
                type        => 'boolean',
                default     => 1,
            },
            {
                name        => 'one_value_per_line',
                label_text  => 'One value per line',
                tooltip     => 'Sparse matrix format',
                type        => 'boolean',
                default     => 0,
            },
            {
                name        => 'include_node_data',
                label_text  => "Include node data\n(child counts etc)",
                type        => 'boolean',
                default     => 1,
            },
            {
                name        => 'sort_array_lists',
                label_text  => 'Sort array lists',
                type        => 'boolean',
                default     => 1,
            },
            $self -> get_table_export_metadata(),
        ],
    );
    
    return wantarray ? %args : \%args;
}

sub export_table_grouped {
    my $self = shift;
    my %args = @_;
    
    my $file = $args{file};
    
    print "[TREE] WRITING TO TREE TO TABLE STRUCTURE USING TERMINAL ELEMENTS, FILE $file\n";

    my $data = $self -> to_table_group_nodes (@_);
    
    $self -> write_table (
        %args,
        file => $file,
        data => $data
    );

    return;
}

sub get_metadata_export_range_table {
    my $self = shift;
    my %args = @_;
    
    my $bd = $args{basedata_ref} || $self -> get_param ('BASEDATA_REF');
    
    #  hide from GUi if no $bd
    my $format = defined $bd ? 'Range table' : $EMPTY_STRING;
    $format = $EMPTY_STRING; # no, just hide from GUI for now

    my %metadata = (
        format => $format,
        parameters => [
            $self -> get_table_export_metadata()
        ],
    );
    
    return wantarray ? %metadata : \%metadata;
}

sub export_range_table {
    my $self = shift;
    my %args = @_;
    
    my $file = $args{file};
    
    print "[TREE] WRITING TREE RANGE TABLE, FILE $file\n";
    
    my $data = eval {
        $self -> get_range_table (
            name => $self -> get_param ('NAME'),
            @_,
        )
    };
    croak $EVAL_ERROR if $EVAL_ERROR;

    $self -> write_table (
        %args,
        file => $file,
        data => $data,
    );

    return;
}

sub get_lists_export_metadata {
    my $self = shift;
    
    my @lists = $self -> get_lists_for_export;
    
    my $metadata = [
        {
            name        => 'sub_list',
            label_text  => 'List to export',
            type        => 'choice',
            choices     => \@lists,
            default     => 0
        }
    ];
    
    return wantarray ? @$metadata : $metadata;    
}

sub get_table_export_metadata {
    my $self = shift;
    
    my @sep_chars
        = defined $ENV{BIODIVERSE_FIELD_SEPARATORS}
            ? @$ENV{BIODIVERSE_FIELD_SEPARATORS}
            : (',', 'tab', ';', 'space', ':');

    my @quote_chars = qw /" ' + $/;

    
    my $table_metadata_defaults = [
        {
            name       => 'file',
            type       => 'file'
        },
        {
            name       => 'sep_char',
            label_text => 'Field separator',
            tooltip    => 'Suggested options are comma for .csv files, tab for .txt files',
            type       => 'choice',
            choices    => \@sep_chars,
            default    => 0
        },
        {
            name       => 'quote_char',
            label_text => 'Quote character',
            #tooltip    => 'For delimited text exports only',
            type       => 'choice',
            choices    => \@quote_chars,
            default    => 0
        },
     ];

    return wantarray ? @$table_metadata_defaults : $table_metadata_defaults;
}


#  get the maximum tree node position from zero
sub get_max_total_length {
    my $self = shift;
    
    my @lengths = reverse sort numerically keys %{$self -> get_node_hash_by_total_length};
    return $lengths[0];
}

sub get_total_tree_length { #  calculate the total length of the tree
    my $self = shift;

    my $length;
    my $node_length;
    
    #check if length is already stored in tree object
    $length = $self -> get_param('TOTAL_LENGTH');
    return $length if (defined $length);
  
    foreach my $node_ref (values %{$self -> get_node_hash}) {
        $node_length = $node_ref -> get_length;
        $length += $node_length;
    }
    
    #  cache the result
    if (defined $length) {
        $self -> set_param (TOTAL_LENGTH => $length);
    }
    
    return $length;
}


#  convert a tree object to a matrix
#  values are the total length value of the lowest parent node that contains both nodes
#  generally excludes internal nodes
sub to_matrix {
    my $self = shift;
    my %args = @_;
    my $class = $args{class} || 'Biodiverse::Matrix';
    my $use_internal = $args{use_internal};
    #my $progress_bar = $args{progress};
    my $progress_bar = Biodiverse::Progress->new();
    
    my $name = $self -> get_param ('NAME');
    
    print "[TREE] Converting tree $name to matrix\n";
    
    my $matrix = $class -> new (NAME => ($args{name} || ($name . "_AS_MX")));
    
    my %nodes = $self -> get_node_hash;  #  make sure we work on a copy
    
    if (! $use_internal) {  #  strip out the internal nodes
        while (my ($name1, $node1) = each %nodes) {
            delete $nodes{$name1} if $node1 -> is_internal_node;
        }
    }
    
    my %done;
    my $progress;
    my $to_do = scalar keys %nodes;
    foreach my $node1 (values %nodes) {
        my $name1 = $node1 -> get_name;
        #print "$name1\t";
        $progress ++;
        #if ($progress_bar) {
            #$progress_bar -> update(
            #    "Converting tree $name to matrix\n($progress / $to_do)",
            #    $progress / $to_do,
            #);
        #}

        NODE2:
        foreach my $node2 (values %nodes) {
            my $name2 = $node2 -> get_name;
            $progress_bar -> update(
                "Converting tree $name to matrix\n($progress / $to_do)",
                $progress / $to_do,
            );
            next NODE2 if $done{$name1}{$name2} || $done{$name2}{$name1};
            #print "$name2\t";
            my $shared_ancestor = $node1 -> get_shared_ancestor (node => $node2);
            my $total_length = $shared_ancestor -> get_total_length;
            $matrix -> add_element (
                element1 => $name1,
                element2 => $name2,
                value    => $total_length,
            );
            $done{$name1}{$name2}++;
        }
        #print "\n";
    }
    
    return $matrix;
}


#  get table of the distances, range sizes and range overlaps between each pair of nodes
#  returns a table of values as an array
sub get_range_table {
    my $self = shift;
    my %args = @_;
    #my $progress_bar = $args{progress};
    my $progress_bar = Biodiverse::Progress->new();
    
    my $use_internal = $args{use_internal};  #  ignores them by default
    
    my $name = $self -> get_param ('NAME');
    
    #  gets the ranges from the basedata
    my $bd = $args{basedata_ref} || $self -> get_param ('BASEDATA_REF');
    
    croak "Tree has no attached BaseData object, cannot generate range table\n"
        if not defined $bd;

    my %nodes = $self -> get_node_hash;  #  make sure we work on a copy

    if (! $use_internal) {  #  strip out the internal nodes
        while (my ($name1, $node1) = each %nodes) {
            if ($node1 -> is_internal_node) {
                delete $nodes{$name1};
            }
        }
    }

    my @results = [
        qw /Node1
            Node2
            Length1
            Length2
            P_dist
            Range1
            Range2
            Rel_range
            Range_shared
            Rel_shared
        /
    ];
    
    #declare progress tracking variables
    my (%done, $progress, $progress_percent);
    my $to_do = scalar keys %nodes;
    my $printed_progress = 0;
    
    # progress feedback to text window
    print "[TREE] CREATING NODE RANGE TABLE FOR TREE: $name  ";
    
    foreach my $node1 (values %nodes) {
        my $name1 = $node1 -> get_name;
        my $length1 = $node1 -> get_total_length;
        
        my $range_elements1
            = $bd -> get_range_union (
                labels => scalar $node1 -> get_terminal_elements
        );
        my $range1 = $node1 -> is_terminal_node
            ? $bd -> get_range (element => $name1)
            : scalar @$range_elements1;  #  need to allow for labels positioned higher on the tree

        # progress feedback for text window and GUI        
        $progress ++;
        #if ($progress_bar) {
            $progress_bar -> update(
                "Converting tree $name to matrix\n"
                . "($progress / $to_do)",
                $progress / $to_do);
        #}
        #my $progress_percent = int (100 * $progress / $to_do);
        #if ($progress_percent % 5 == 0) {
        #    if ($printed_progress != $progress_percent) {
        #        print "$progress_percent% ";
        #        print "\n" if $progress_percent == 100;
        #        $printed_progress = $progress_percent;
        #    }
        #}
        
        LOOP_NODE2:
        foreach my $node2 (values %nodes) {
            my $name2 = $node2 -> get_name;
            
            next LOOP_NODE2 if $done{$name1}{$name2} || $done{$name2}{$name1};
            
            my $length2 = $node2 -> get_total_length;
            my $range_elements2 = $bd -> get_range_union (labels => scalar $node2 -> get_terminal_elements);
            my $range2 = $node1 -> is_terminal_node
                ? $bd -> get_range (element => $name2)
                : scalar @$range_elements2;

            
            my $shared_ancestor = $node1 -> get_shared_ancestor (node => $node2);
            my $length_ancestor = $shared_ancestor -> get_length;  #  need to exclude length of ancestor itself
            my $length1_to_ancestor = $node1 -> get_length_above (target_ref => $shared_ancestor) - $length_ancestor;
            my $length2_to_ancestor = $node2 -> get_length_above (target_ref => $shared_ancestor) - $length_ancestor;
            my $length_sum = $length1_to_ancestor + $length2_to_ancestor;
            
            my ($range_shared, $range_rel, $shared_rel);
            
            if ($range1 and $range2) { # only calculate range comparisons if both nodes have a range > 0
                if ($name1 eq $name2) { # if the names are the same, the shared range is the whole range
                    $range_shared = $range1;
                    $range_rel = 1;
                    $shared_rel = 1;
                }
                else {
                    #calculate shared range    
                    my (%tmp1, %tmp2); 
                    #@tmp1{@$range_elements1} = @$range_elements1;
                    @tmp2{@$range_elements2} = @$range_elements2;
                    delete @tmp2{@$range_elements1};
                    $range_shared = $range2 - scalar keys %tmp2;

                    #calculate relative range
                    my $greater_range = $range1 > $range2
                        ? $range1
                        : $range2;
                    my $lesser_range = $range1 > $range2
                        ? $range2
                        : $range1;             
                    $range_rel = $lesser_range / $greater_range;

                    #calculate relative shared range
                    $shared_rel = $range_shared / $lesser_range;
                };
            };

            push @results, [
                $name1,
                $name2,
                $length1_to_ancestor,
                $length2_to_ancestor,
                $length_sum,
                $range1,
                $range2,
                $range_rel,
                $range_shared,
                $shared_rel
            ];
        }
    }
    
    return wantarray ? @results : \@results;
}

sub find_list_indices_across_nodes {
    my $self = shift;
    my %args = @_;
    
    my @lists = $self -> get_hash_lists_below;
    
    my %index_hash;
    my %analyses_by_index = $self -> get_index_source_hash;

    #  loop over the lists and find those that are generated by a calculation
    #  This ensures we get all of them if subsets are used.
    foreach my $list_name (@lists) {
        if (exists $analyses_by_index{$list_name}) {
            $index_hash{$list_name} = $list_name;
        }
    }

    return wantarray ? %index_hash : \%index_hash;    
}

########################################################
#  Compare one tree object against another
#  Compares the similarity of the terminal elements using the Sorenson metric
#  Creates a new list in the tree object containing values based on the rand_compare
#  argument in the relevant indices
#  This is really designed for the randomisation procedure, but has more
#  general applicability
sub compare {
    my $self = shift;
    my %args = @_;
    
    #  make all numeric warnings fatal to catch locale/sprintf issues
    use warnings FATAL => qw { numeric };

    my $comparison = $args{comparison}
        || croak "Comparison not specified\n";

    my $result_list_pfx = $args{result_list_name};
    croak "Comparison list name not specified\n"
        if ! defined $result_list_pfx;

    my $result_data_list = $result_list_pfx . "_DATA";
    #my $result_sp_list   = $result_list_pfx . "_SPATIAL";
    my $result_identical_node_length_list = $result_list_pfx . "_ID_LDIFFS";
    #my %comparison_ops;
    
    #my $progress = $args{progress};
    #delete $args{progress};
    my $progress = Biodiverse::Progress->new();
    my $progress_text = "Comparing "
                        . $self -> get_param ("NAME")
                        . " with "
                        . $comparison -> get_param ("NAME")
                        . "\n";
    #if ($progress) {
        $progress -> update ($progress_text, 0);
    #}
    
    print "[TREE] Comparing "
        . $self -> get_param ('NAME')
        . ' with '
        . $comparison -> get_param ('NAME')
        . "\n";
    
    #  set up the comparison operators if it has spatial results
    my $has_spatial_results = defined $self -> get_list_ref (
        list => 'SPATIAL_RESULTS',
    );
    my %base_list_indices;
    
    if ($has_spatial_results) {

        %base_list_indices = $self -> find_list_indices_across_nodes;
        $base_list_indices{SPATIAL_RESULTS} = 'SPATIAL_RESULTS';

        foreach my $list_name (keys %base_list_indices) {
            $base_list_indices{$list_name}
                = $result_list_pfx . '>>' . $list_name;
        }

    }
    
    #  now we chug through each node, finding its most similar comparator node in the other tree
    #  we store the similarity value as a measure of cluster reliability and 
    #  we then use that node to assess how goodthe spatial results are
    my $min_poss_value = 0;
    my $max_poss_value = 1;
    my %compare_nodes = $comparison -> get_node_hash;  #  make sure it's a copy
    my %done;
    my %found_perfect_match;
    
    my $to_do = max ($self -> get_node_count, $comparison -> get_node_count);
    my $i = 0;
    my $last_update = [gettimeofday];
    
    foreach my $base_node ($self -> get_node_refs) {
        $i++;
        #if ($progress and tv_interval ($last_update)) {
            $progress -> update ($progress_text . "(node $i / $to_do)", $i / $to_do);
            #$last_update = [gettimeofday];
        #}
        
        my %base_elements = $base_node -> get_terminal_elements;
        my $base_node_name = $base_node -> get_name;
        my $min_val = $max_poss_value;
        my $most_similar_node;

        #  also need to get the spatial list from the most similar
        COMP:
        foreach my $compare_node_name (keys %compare_nodes) {
            next if $found_perfect_match{$compare_node_name};
            my $sorenson = defined $done{$compare_node_name}{$base_node_name}
                                    ? $done{$compare_node_name}{$base_node_name}
                                    : $done{$base_node_name}{$compare_node_name};
                                    
            if (! defined $sorenson) { #  if still not defined then it needs to be calculated
                my %comp_elements = $compare_nodes{$compare_node_name} -> get_terminal_elements;
                my %union_elements = (%comp_elements, %base_elements);
                my $abc = scalar keys %union_elements;
                my $a = (scalar keys %base_elements) + (scalar keys %comp_elements) - $abc;
                $sorenson = 1 - ((2 * $a) / ($a + $abc));
                $done{$compare_node_name}{$base_node_name} = $sorenson;
            }
            
            #warn "BC NOT DEFINED" if ! defined $bray_curtis;
            if ($sorenson <= $min_val) {
                $min_val = $sorenson;
                $most_similar_node = $compare_nodes{$compare_node_name};
                carp $compare_node_name if ! defined $most_similar_node;
                if ($sorenson == $min_poss_value) {
                    #  cannot be related to another node
                    $found_perfect_match{$compare_node_name} ++;
                    last COMP;
                }
            }
            carp "$compare_node_name $sorenson $min_val"
                if ! defined $most_similar_node;
        }


        $base_node -> add_to_lists ($result_data_list => [$min_val]);
        my $stats = $stats_class->new;

        $stats -> add_data ($base_node -> get_list_ref (list => $result_data_list));
        my $prev_stat = $base_node -> get_list_ref (list => $result_list_pfx);
        my %stats = (
            MEAN   => $stats -> mean,
            SD     => $stats -> standard_deviation,
            MEDIAN => $stats -> median,
            Q25    => scalar $stats -> percentile (25),
            Q05    => scalar $stats -> percentile (5),
            Q01    => scalar $stats -> percentile (1),
            COUNT_IDENTICAL
                   =>   ($prev_stat->{COUNT_IDENTICAL} || 0)
                      + ($min_val == $min_poss_value ?  1 : 0),
            COMPARISONS
                   => ($prev_stat->{COMPARISONS} || 0) + 1,
        );
        $stats{PCT_IDENTICAL} = 100 * $stats{COUNT_IDENTICAL} / $stats{COMPARISONS};

        my $length_diff = ($min_val == $min_poss_value)
                        ? [  $base_node -> get_total_length
                           - $most_similar_node -> get_total_length
                          ]
                        : [];  #  empty array by default

        $base_node -> add_to_lists (
            $result_identical_node_length_list => $length_diff
        );

        $base_node -> add_to_lists ($result_list_pfx => \%stats);

        if ($has_spatial_results) {
            BY_INDEX_LIST:
            while (my ($list_name, $result_list_name) = each %base_list_indices) {

                my $base_ref = $base_node -> get_list_ref (
                    list => $list_name,
                );

                my $comp_ref = $most_similar_node -> get_list_ref (
                    list => $list_name,
                );
                next BY_INDEX_LIST if ! defined $comp_ref;

                my $results = $base_node -> get_list_ref (
                    list => $result_list_name,
                )
                || {};

                $self -> compare_lists_by_item (
                    base_list_ref     => $base_ref,
                    comp_list_ref     => $comp_ref,
                    results_list_ref  => $results,
                );

                #  add list to the base_node if it's not already there
                if (! defined $base_node -> get_list_ref (list => $result_list_name)) {
                    $base_node -> add_to_lists ($result_list_name => $results);
                }
            }
        }
    }

    $self -> set_last_update_time;

    return 1;
}

#  trim a tree to remove nodes from a set of names, or those not in a set of names
sub trim {
    my $self = shift;
    my %args = (
        delete_internals => 1,   #  delete internals by default
        @_,                      #  if they have no named children to keep
    );

    my $delete_internals = $args{delete_internals};

    #  get keep and trim lists and convert to hashes as needs dictate
    my $keep = $args{keep} || {};  #  those to keep
    $keep = $self -> array_to_hash_keys (list => $keep);
    my $trim = $args{trim}; #  those to delete

    #  if the keep list is defined, and the trim list is not defined,
    #    then we work with all named nodes that don't have children we want to keep
    if (! defined $args{trim} && defined $args{keep}) {
        $trim = {};
        my %node_hash = $self -> get_node_hash;
        foreach my $name (keys %node_hash) {
            my $node = $node_hash{$name};
            next if exists $keep->{$name};
            next if $node -> is_internal_node;
            next if $node -> is_root_node;  #  never delete the root node
            my %children = $node -> get_all_children;  #  make sure we use a copy
            my $child_count = scalar keys %children;
            delete @children{keys %$keep};
            #  if any were deleted then we have some children to keep.  don't add this node
            next if $child_count != scalar keys %children;  
            $trim->{$name} = $node_hash{$name};
        }
    }
    else {
        $trim = {};
    }
    my %trim_hash = $self -> array_to_hash_keys (list => $trim);  #  makes a copy
    
    
    #  we only want to consider those not being explicitly kept (included)
    my %candidate_node_hash = $self -> get_node_hash;
    delete @candidate_node_hash{keys %$keep};
    
    #my %all_nodes = $self -> get_node_hash;
    #delete @all_nodes{keys %candidate_node_hash};
    #print "keeping \n", join ("\n", keys %$keep), "\n";
    #print "trimming \n", join ("\n", keys %trim_hash), "\n";
    #print "ignoring \n", join ("\n", keys %all_nodes), "\n";
    
    my %deleted;
    foreach my $name (keys %candidate_node_hash) {
        next if $deleted{$name};  #  we might have deleted a named parent, so this node no longer exists in the tree
        my $node = $candidate_node_hash{$name};
        #  delete if it is in the list to exclude
        if (exists $trim_hash{$name}) {
            print "[Tree] Deleting node $name\n";
            my @deleted_nodes = $self -> delete_node (node => $name);
            foreach my $del_name (@deleted_nodes) {
                $deleted{$del_name} ++;
            }
        }
        #else {
        #    print "[TREE] NOT deleting node $name\n";
        #}
    }

    
    if ($delete_internals and scalar keys %deleted) {
        #  delete any internal nodes with no named children
        my %node_hash = $self -> get_node_hash;
        foreach my $name (keys %node_hash) {
            my $node = $node_hash{$name};
            next if ! $node -> is_internal_node;
            next if $node -> is_root_node;
            
            my $children = $node -> get_all_children;
            my %named_children;
            foreach my $child (keys %$children) {
                my $child_node = $children->{$child};
                $named_children{$child} = 1 if ! $child_node -> is_internal_node;
            }
            if (scalar keys %named_children == 0) {
                #  might have already been deleted , so wrap in an eval
                eval { $self -> delete_node (node => $name) };
                #print "[TREE] Deleting internal node $name\n";
            }
            #else {
            #    print "[TREE] NOT Deleting internal node $name\n"
            #}
        }
    }
    
    $self -> delete_param ('TOTAL_LENGTH');  #  need to clear this up
    
    return $self;
}


sub min {return $_[0] > $_[1] ? $_[1] : $_[0]};
sub max {return $_[0] < $_[1] ? $_[1] : $_[0]};

sub numerically {$a <=> $b};

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self) || $self;
                #or croak "$self is not an object\n";

    my $method = $AUTOLOAD;
    $method =~ s/.*://;   # strip fully-qualified portion

#  seem to be getting destroy issues - let the system take care of it.
#    return if $method eq 'DESTROY';  

    my $root_node = $self -> get_tree_ref;
    
    croak 'No root node' if ! $root_node;

    if (defined $root_node and $root_node -> can ($method)) {
        #print "[TREE] Using AUTOLOADER method $method\n";
        return $root_node -> $method (@_);
    }
    else {
        croak "[$type (TREE)] No root node and/or cannot access method $method, "
            . "tried AUTOLOADER and failed\n";
    }

    return;
}



sub collapse_tree {
#  collapse tree to a polytomy a set distance above the tips
#  assumes ultrametric tree
    
    my $self = shift;   # expects a Tree object
    my %args = @_;
    # the only args are:
    #   cutoff_absolute - the depth from the tips of the tree at which to cut in units of branch length
    #   or cutoff_relative - the depth from the tips of the tree at which to cut as a proportion
    #   of the total tree depth.
    #   if both parameters are given, cutoff_relative overrides cutoff_absolute
    
    my $cutoff = $args{cutoff_absolute};
    
    my $total_tree_length = $self -> get_tree_length;    
    
    if ($args{cutoff_relative} >= 0) {
        my $cutoff_relative = $args{cutoff_relative};
        if (($cutoff_relative >= 0) and ($cutoff_relative <= 1)) {
            $cutoff = $cutoff_relative * $total_tree_length;
        }
    }

    my ($zero_count, $shorter_count);
    
    my %node_hash = $self -> get_node_hash;
    

    
    print "[TREE] Total length: ".$total_tree_length."\n";
    print "[TREE] Node count: ".(scalar keys %node_hash)."\n";
        
    my $node;
    
    my %new_node_lengths;
    
    #  first pass - calculate the new lengths
    foreach my $name (sort keys %node_hash) {
        $node = $node_hash{$name};
        #my $new_branch_length;
        
        my $node_length = $node -> get_length;
        my $length_to_tip = $node -> get_length_below;  #  includes length of $node
        my $upper_bound = $length_to_tip;
        my $lower_bound = $length_to_tip - $node_length;

        my $type;
        # whole branch is inside the limit - no change
        if ($upper_bound < $cutoff) {
            next;
        }
        # whole of branch is outside limit - set branch length to 0
        elsif ($lower_bound >= $cutoff) {
            $new_node_lengths{$name} = 0;
            $zero_count ++;
            $type = 1;
        }
        # part of branch is outside limit - shorten branch
        else {                       
            $new_node_lengths{$name} = $cutoff - $lower_bound;
            $shorter_count ++;
            $type = 2;
        };
        
        #print "$type Changed $name\n";
        #print "$length_to_tip to $new_node_lengths{$name}, length was $node_length\n";
        #print "L= $lower_bound\t U= $upper_bound\n";
        
    }

    #  second pass - apply the new lengths
    foreach my $name (keys %new_node_lengths) {
        $node = $node_hash{$name};
        
        my $new_length;
        
        if ($new_node_lengths{$name} == 0) {
            if ($node -> is_terminal_node) {
                $new_length = ($total_tree_length / 10000);
            }
            else {
                $new_length = 0;
            }
        }
        else {
            $new_length = $new_node_lengths{$name};
        };
        
        $node -> set_length (length => $new_length);
        
        
        print "$name: new length is $new_length\n";
    }
    
    
    $self -> delete_cached_values;
    
    #  reset all the total length values
    $self -> reset_total_length_below;
    $self -> get_total_tree_length;
    
    my @now_empty = $self -> flatten_tree;
    #  now we clean up all the empty nodes in the other indexes
    print "[TREE] Deleting " . scalar @now_empty . " empty nodes\n";
    #foreach my $now_empty (@now_empty) {
    $self -> delete_from_node_hash (nodes => \@now_empty) if scalar @now_empty;
    
    
    print "[TREE] Total length: " . $self -> get_tree_length . "\n";
    print "[TREE] Node count: " . $self -> get_node_count . "\n";
    
    return $self;
    
}

#  root an unrooted tree using a zero length node.
sub root_unrooted_tree {
    my $self = shift;
    
    my @root_nodes = $self->get_root_node_refs;
    
    return if scalar @root_nodes <= 1;
    
    my $name = $self->get_free_internal_name;
    my $new_root_node = $self->add_node (length => 0, name => $name);

    $new_root_node->add_children(children => \@root_nodes);
    
    @root_nodes = $self->get_root_node_refs;
    croak "failure\n" if scalar @root_nodes > 1;
    
    return;
}

#  Let the system take care of most of the memory stuff.  
sub DESTROY {
    my $self = shift;
    #my $name = $self -> get_param ('NAME');
    #print "DELETING $name\n";
    $self -> set_param (BASEDATA_REF => undef);  #  clear the ref to the parent basedata object
    $self->{TREE} = undef;  # empty the ref to the tree
    $self->{TREE_BY_NAME} = undef;  #  empty the list of nodes
    #print "DELETED $name\n";
    return;
};  

1;


__END__

=head1 NAME

Biodiverse::????

=head1 SYNOPSIS

  use Biodiverse::????;
  $object = Biodiverse::Statistics->new();

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