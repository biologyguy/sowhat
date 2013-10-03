#!perl 

#    sowh.pl - SOWH test 
#        (likelihood-based test used to compare tree topologies which
#         are not specified a priori)
#
#    Copyright (C) 2013  Samuel H. Church, Joseph F. Ryan, Casey W. Dunn
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License along
#    with this program; if not, write to the Free Software Foundation, Inc.,
#    51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

our $VERSION = 0.10;

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
use Cwd;
#use local lib if installing Statistics::R without sudo cpan
#use local::lib;
use Statistics::R;

our $RAX = 'raxmlHPC';
our $SEQGEN = 'seq-gen';
our $PB = 'pb -f';
our $PPRED = 'ppred';
our $PB_SAMPLING_FREQ = 5;
our $PB_SAVING_FREQ   = 1;
our $PB_BURN   = 10;
our $DEFAULT_REPS = 100;
our $TEST_RUNS = 1;
our $QUIET = 1;
our $DIR = '';
our $FREQ_BIN_NUMBER = 10;
our $TRE_PREFIX = 'RAxML_bestTree';
our $NEW_PARTITION_FILE = 'new.part.txt';
our $PART_RATE_MATRIX_PREFIX = 'RAxML_proteinGTRmodel.par';
our $NAME = '';

MAIN: {
    my $rh_opts = process_options();
    
    my $ver = get_version();

    if ($rh_opts->{'sowhat'}) {
        $rh_opts->{'test_runs'} = $rh_opts->{'reps'};
        $rh_opts->{'reps'} = '1';
    }
    
    my @delta_dist = ();
    my @deltaprime_dist = ();
    my @variance = (); 
    
    for (my $ts = 0; $ts < $rh_opts->{'test_runs'}; $ts++) {
        run_initial_trees($rh_opts,$ts);
        my $ra_alns = [ ];
        my $ra_aln_len = 0;
        my $codon_flag = 0;
        if ($rh_opts->{'usepb'}) {
            $ra_alns = generate_alignments_w_pb($rh_opts,$ts);
        } else {
            my $ra_params = [ ];
            my $ra_rates  = [ ];
            ($ra_aln_len,$codon_flag,$ra_params,$ra_rates) = 
                get_params($rh_opts->{'aln'},$rh_opts->{'part'},
                $rh_opts->{'mod'},$rh_opts->{'constraint_tree'},$ts);

            $ra_alns = generate_alignments($ra_aln_len,$ra_params,$ra_rates,
            $rh_opts->{'mod'},$rh_opts->{'reps'},$ts);
        } 
        my ($best_ml,$best_t1,$rh_stats,$ra_diff,$fd_file) = ();
        for (my $i = 0; $i < @{$ra_alns}; $i++) {
            run_raxml_on_gen_alns($ra_alns,$rh_opts,$ra_aln_len,
            $codon_flag,$i,$ts);

            ($best_ml,$best_t1,$rh_stats,$ra_diff,$fd_file) =
            evaluate_distribution($rh_opts->{'reps'},$rh_opts->{'name'},
            \@delta_dist,\@deltaprime_dist,\@variance,$i,$ts);
            plot_variance(\@variance);
        }
        print_report($ts,$best_ml,$best_t1,$rh_stats,$ra_diff,\@delta_dist,                          $rh_opts,$fd_file,$ver);
     }
}

sub process_options {
    my $rh_opts = {};
    $rh_opts->{'reps'} = $DEFAULT_REPS;
    $rh_opts->{'orig_options'} = [@ARGV];
    $rh_opts->{'rax'} = $RAX;
    $rh_opts->{'test_runs'} = $TEST_RUNS;
    $rh_opts->{'seqgen'} = $SEQGEN;

    my $opt_results = Getopt::Long::GetOptions(
                              "version" => \$rh_opts->{'version'},
                               "sowhat" => \$rh_opts->{'sowhat'},
                                "usepb" => \$rh_opts->{'usepb'},
                              "ppred=s" => \$rh_opts->{'ppred'},
                            "pb_burn=i" => \$rh_opts->{'pb_burn'},
                                 "pb=s" => \$rh_opts->{'pb'},
                         "constraint=s" => \$rh_opts->{'constraint_tree'},
                                "aln=s" => \$rh_opts->{'aln'},
                                "dir=s" => \$rh_opts->{'dir'},
                               "reps=i" => \$rh_opts->{'reps'},
                              "tests=i" => \$rh_opts->{'test_runs'},
                             "seqgen=s" => \$rh_opts->{'seqgen'},
                                "rax=s" => \$rh_opts->{'rax'},
                          "partition=s" => \$rh_opts->{'part'},
                                "debug" => \$rh_opts->{'debug'},
                              "model=s" => \$rh_opts->{'mod'},
                               "name=s" => \$rh_opts->{'name'},
                                 "help" => \$rh_opts->{'help'});

    $PPRED = $rh_opts->{'ppred'} if ($rh_opts->{'ppred'});
    $PB = $rh_opts->{'pb'} if ($rh_opts->{'pb'});
    $PB_BURN = $rh_opts->{'pb_burn'} if ($rh_opts->{'pb_burn'});
    $RAX = $rh_opts->{'rax'} if ($rh_opts->{'rax'});
    $SEQGEN = $rh_opts->{'seqgen'} if ($rh_opts->{'seqgen'});
    $QUIET = 0 if ($rh_opts->{'debug'});
    die "$VERSION\n" if ($rh_opts->{'version'});
    pod2usage({-exitval => 0, -verbose => 2}) if $rh_opts->{'help'};
    unless ($rh_opts->{'constraint_tree'} &&
            $rh_opts->{'aln'} &&
            $rh_opts->{'mod'} &&
            $rh_opts->{'name'}) {
        warn "missing --constraint\n" unless ($rh_opts->{'constraint_tree'});
        warn "missing --aln\n" unless ($rh_opts->{'aln'});
        warn "missing --name\n" unless ($rh_opts->{'name'});
        warn "missing --model\n" unless ($rh_opts->{'mod'});
        usage();
    }
    $NAME = $rh_opts->{'name'};
    set_out_dir($rh_opts->{'dir'});
    return $rh_opts;
}

sub set_out_dir {
    my $opt_dir = shift;
    my $pwd = getcwd();
    if ($opt_dir) {
        $opt_dir = "$pwd/$opt_dir" if ($opt_dir !~ m/^\//);
        $opt_dir .= '/' if ($opt_dir !~ m/\/$/);
        $DIR = $opt_dir if ($opt_dir);
    } else {
        warn "missing --dir\n";
        usage();
    }
    mkdir $DIR unless (-d $DIR);
}

sub safe_system {
    my $cmd = shift;
    warn "\$cmd = $cmd\n" unless ($QUIET);
    my $error = system $cmd;
    warn "system call failed:\n$cmd\nerror code=$?" if ($error != 0);
}

sub get_version {
    my $version_st = `$RAX -v`;
    my @lines= split /\n/, $version_st;
    my $version = '';
    foreach my $l (@lines) {
        next unless $l =~ m/^This is RAxML version (\d+\.\d+)/;
        $version = $1;
        last;
    }
    if ($version < 7.7) {
        warn "sowh.pl ERROR:\n";
        warn "You are running version $version of RAxML\n";
        die  "sowh.pl requires version 7.7 or higher\n";
    }
    return $version;
}

sub run_initial_trees {
    my $rh_opts = shift;
    my $ts = shift;
    my $aln = $rh_opts->{'aln'};
    my $part = $rh_opts->{'part'};
    my $mod = $rh_opts->{'mod'};
    my $tre = $rh_opts->{'constraint_tree'};

    print "Running initial trees, estimating parameters\n";
    _run_best_tree('ml',$aln,$part,$mod,$ts);
    _run_best_tree('t1',$aln,$part,$mod,$ts,$tre);
}

sub _run_best_tree {
    my $title = shift;
    my $aln   = shift;
    my $part  = shift;
    my $mod   = shift;
    my $ts    = shift;
    my $tre   = shift;

    my $cmd = "$RAX -f d -p 1234 -w $DIR -m $mod -s $aln -n $title.test.$ts";
    $cmd .= " -q $part" if ($part);
    $cmd .= " -g $tre" if ($tre);
    if ($QUIET) {
        $cmd .= " >> ${DIR}sowh_stdout_$NAME.txt ";
        $cmd .= "2>> ${DIR}sowh_stderr_$NAME.txt";
    }
    safe_system($cmd);
}

sub generate_alignments_w_pb {
    my @alns = ();
    my $rh_opts = shift;
    my $ts = shift;
    my $id = $DIR . $rh_opts->{'name'} . ".pb.test.$ts";
    my $pb_reps = $rh_opts->{'reps'} * $PB_SAMPLING_FREQ + $PB_BURN;
    my $pb_cmd = "$PB -d $rh_opts->{'aln'} -T $rh_opts->{'constraint_tree'} ";
    $pb_cmd .= "-x $PB_SAVING_FREQ $pb_reps $id";
    if ($QUIET) {
        $pb_cmd .= " >> ${DIR}sowh_stdout_$NAME.txt ";
        $pb_cmd .= "2>> ${DIR}sowh_stderr_$NAME.txt";
    }
    safe_system($pb_cmd);
    my $ppred_cmd = "$PPRED -x $PB_BURN $PB_SAMPLING_FREQ $id";
    if ($QUIET) {
        $ppred_cmd .= " >> ${DIR}sowh_stdout_$NAME.txt ";
        $ppred_cmd .= "2>> ${DIR}sowh_stderr_$NAME.txt";
    }
    safe_system($ppred_cmd);
    for (my $i = 0; $i < $rh_opts->{'reps'}; $i++) {
        push @alns, "${id}_sample_${i}.ali"; 
    }
    return \@alns;
}

sub get_params {
    my $aln = shift;
    my $part = shift;
    my $mod = shift;
    my $tre = shift;
    my $ts = shift;
    my $ra_aln_len = ();
    my $codon_flag = 0;
    my $ra_params = ();
    my $ra_rates = ();
    if ($mod =~ m/^GTRGAMMA/i) {
        ($ra_aln_len,$codon_flag,$ra_params) =
           _model_gtrgamma($aln,$part,$tre,$ts);
    } elsif ($mod =~ m/^PROT/i) {
        ($ra_aln_len,$codon_flag,$ra_params,$ra_rates) =
           _model_prot($aln,$part,$tre,$ts);      
    } elsif ($mod =~ m/^MULTIGAMMA/i) {
        ($ra_aln_len,$codon_flag,$ra_params,$ra_rates) =
           _model_character_data($aln,$part,$tre,$ts);
    } else {
        ($ra_aln_len,$codon_flag,$ra_params) =
           _model_non_gtr($aln,$part,$tre,$ts);        
    }
    return ($ra_aln_len,$codon_flag,$ra_params,$ra_rates);   
}

sub _model_gtrgamma {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    my $ts = shift;
    my ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
    my ($ra_params) = _get_params_from_const_rax($DIR ."RAxML_info.t1.test.$ts");
    return ($ra_aln_len,$codon_flag,$ra_params);
}

sub _model_prot {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    my $ts = shift;
    my $ra_aln_len = ();
    my $codon_flag = 0;
    my $ra_params = ();
    my $ra_rates = ();
    my $new_part = $DIR . $NEW_PARTITION_FILE;
    if ($part) {
        my $ra_part_names = _make_unlinked_partition_file($part,$new_part);
        _run_best_tree('par',$aln,$new_part,'PROTGAMMAGTR_UNLINKED',$ts,$tre);
        $ra_rates = _parse_rates($ts,$ra_part_names);
        ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
        $ra_params = _get_params_from_const_rax($DIR ."RAxML_info.par.test.$ts");
    } else {
        _run_best_tree('par',$aln,$part,'PROTGAMMAGTR_UNLINKED',$ts,$tre);
        $ra_rates = _parse_rates($ts);
        ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
        $ra_params = _get_params_from_const_rax($DIR ."RAxML_info.par.test.$ts");
    }
    return ($ra_aln_len,$codon_flag,$ra_params,$ra_rates);      
}

sub _model_character_data {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    my $ts = shift;
    my ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
    my ($ra_params) = _get_params_from_const_rax($DIR ."RAxML_info.t1.test.$ts");
    return ($ra_aln_len,$codon_flag,$ra_params);
}

sub _model_non_gtr {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    my $ts = shift;
    _run_best_tree('par',$aln,$part,'GTRGAMMA',$ts,$tre);
    my ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
    my $ra_params = _get_params_from_const_rax($DIR . "RAxML_info.par.test.$ts");
    return ($ra_aln_len,$codon_flag,$ra_params);
}

sub _get_partition_lengths {
    my $aln = shift;
    my $part = shift;
    my $codon_flag = 0;
    my @lens = ();
    if ($part) {
        open IN, $part or _my_die("cannot open $part:$!");
        while (my $line = <IN>) {
            chomp $line;
            next if ($line =~ m/^\s*$/);
            if ($line =~ m/^[^,]+,\s*\S+\s*=\s*(\d+)-(\d+)\s*$/) {
                my $len = ($2 - $1 + 1);
                push @lens, $len;
            } elsif ($line =~ m/^[^,]+,\s*\S+\s*=\s*(\d+)-(\d+)\S(\d+)\s*$/) {
                my $len = ($2 - $1)/$3 + 1;
                push @lens, $len;
                $codon_flag = 1;
            } else {
                _my_die("unexpected line in $part");
            }
        }
    } else {
        open IN, $aln or _my_die("cannot open $aln:$!");
        my $line = <IN>;
        if ($line =~ m/^\s*\d+\s+(\d+)\s*$/) {
            @lens = $1;
        } else {
            _my_die("Alignment file should be in PHYLIP format\n");
        }
    }
    return (\@lens,$codon_flag);
}

sub _get_params_from_const_rax {
    my $file = shift;
    my @data = ();
    open IN, "$file" or _my_die("cannot open $file:$!");
    my $part_num = 0;
    my @fields = ();
    my $lflag = 0;
    while (my $line = <IN>) {
        if ($line =~ m/^Partition: (\d+) with .*/) {
           $part_num = $1;
           next;
        } if ($line =~ m/^Base frequencies: (.*)/) {
            $data[$part_num]->{'freqs'}  = $1;
        } if ($line =~ m/^alpha\[/) {
            @fields = split/alpha/, $line;
            foreach my $f (@fields) {
                if ($f =~ m/^\[(\d+)\]: ([0-9.]+)( rates\[\d+\] ([^:]+): (.*))?/) {
                    $part_num = $1;
                    $data[$part_num]->{'alpha'} = $2;
                    my $rate1 = $4;
                    my $rate2 = $5;
                    next unless ($rate1);
                    my @code  = split /\s+/, $rate1 ;
                    my @rates = split /\s+/, $rate2;
                    for (my $i = 0; $i < @code; $i++) {
                        $data[$part_num]->{'rates'}->{$code[$i]} = $rates[$i];
                    }
                }
            }
        } elsif ($line =~ m/^Partition: (\d+)\s*$/) {
            $lflag = $1 + 1;
        } elsif ($lflag) {
            if ($line =~ m/^Alignment Patterns: /) {
                next;
            } elsif ($line =~ m/^Name: /) {
                next;
            } elsif ($line =~ m/DataType: (\S+)/) {
                $data[$lflag - 1]->{'type'} = $1;
                $lflag = 0;
            } else {
                _my_die("unexpected line: $line");
            }
        }
    }
    return \@data;
}    

sub _make_unlinked_partition_file {
    my $part = shift;
    my $new_part = shift;
    my ($ra_aa_part_ranges,$ra_part_names) = _get_aa_part_info($part);
    _print_unlinked_part($ra_aa_part_ranges,$new_part);
    return $ra_part_names;
}

sub _get_aa_part_info {
    my $part = shift;
    open IN, $part or _my_die("cannot open $part:$!");
    my @fields = ();
    my @part_info = ();
    my @names = ();
    while (my $line = <IN>) {
        chomp $line;
        next if ($line =~ m/^\s*$/);
        @fields = split/\,/, $line;
        $fields[1] or _my_die("unexpected line in part file:$line\nexpecting comma");
        push @part_info, $fields[1];
        my @name_range = split /=/, $fields[1];
        $name_range[1] or _my_die("unexpected line in part file:$line\nexpecting =");
        $name_range[0] =~ s/\s//g;
        push @names, $name_range[0];
   }
   return (\@part_info,\@names);
}

sub _print_unlinked_part {
    my $part_info = shift;
    my $new_part = shift;
    open OUT, ">$new_part" or _my_die("cannot open $new_part:$!");
    for (my $i = 0; $i < @{$part_info}; $i++) {
       print OUT "GTR_UNLINKED," . "$part_info->[$i]\n";
    }
}

sub _parse_rates {
    my $ts = shift;
    my $ra_part_names = shift;
    my @rates = ();
    if ($ra_part_names) {
        foreach my $pn (@{$ra_part_names}) {
            my @local_rates = ();
            my $matrix = $DIR . $PART_RATE_MATRIX_PREFIX . ".test.$ts" . "_Partition_" . $pn;
            open IN, "$matrix" or _my_die("cannot open $matrix:$!");
            while (my $line = <IN>) {
                my @fields = split/\s/, $line;
                push @local_rates, \@fields;
            }
            push @rates, \@local_rates;
        }
    } else {
        my $matrix = $DIR . $PART_RATE_MATRIX_PREFIX . ".test.$ts" . "_Partition_No Name Provided";
        open IN, "$matrix" or _my_die("cannot open $matrix:$!");
        while (my $line = <IN>) {
            my @fields = split/\s/, $line;
            push @{$rates[0]}, \@fields;
        }
    }
    return \@rates;
}

sub generate_alignments {
    my $ra_aln_len = shift;
    my $ra_params = shift;
    my $ra_rates = shift;
    my $mod = shift;
    my $reps = shift;
    my $ts = shift;
    _run_seqgen($ra_aln_len,$ra_params,$ra_rates,$mod,$reps,$ts);
    my $ra_ds = _build_datasets(scalar(@{$ra_params}),$ts);
    my $ra_alns = _make_alns($ra_ds,$ts);
}

sub _run_seqgen {
    my $ra_part_lens = shift;
    my $ra_params = shift;
    my $ra_rates  = shift;
    my $model     = shift;
    my $reps      = shift;
    my $ts         = shift;
    my $count     = 0;
    for (my $i = 0; $i < @{$ra_params}; $i++) {
        my $rh_part = $ra_params->[$i];
        my $cmd = "$SEQGEN -or ";
        $cmd .= "-l$ra_part_lens->[$i] ";
        $cmd .= "-a$rh_part->{'alpha'} ";
        $cmd .= "-n$reps ";
        if ($rh_part->{'type'} eq 'DNA') {
            $cmd .= "-m$model ";
            $cmd .= _get_dna_params($rh_part);
        } elsif ($rh_part->{'type'} eq 'AA') {
            $cmd .= "-mGENERAL ";
            $cmd .= _get_aa_params($rh_part,$ra_rates->[$i]);
        } elsif ($rh_part->{'type'} eq 'Multi-State') {
            $cmd .= "-mGTR ";
            $cmd .= _get_char_params($rh_part);
        } else {
            _my_die(qq~do not know how to handle type: "$rh_part->{'type'}"\n~);
        }
        $cmd .= " < $DIR" . "$TRE_PREFIX.t1.test.$ts > $DIR" . "seqgen.$count.out.test.$ts";
        $cmd .= " 2>> ${DIR}sowh_stderr_$NAME.txt" if ($QUIET);
        $count++;
        safe_system($cmd);
        if ($rh_part->{'type'} eq 'Multi-State') {
            my $file = "seqgen." . ($count - 1) . ".out";
            _convert_AT_to_01($DIR . $file, $ra_part_lens->[$i]);
        }
    }
}

sub _convert_AT_to_01 {
    my $file  = shift;
    my $num_cols = shift;
    my $updated = '';
    open IN, $file or _my_die("cannot open $file:$!");
    while (my $line = <IN>) {
        chomp $line;
        if ($line =~ m/^(\S+\s+)(\S+)$/) {
            my $id = $1;
            my $seq = $2;
            if (length($seq) == $num_cols) {
                $seq =~ tr/AT/01/;
                $updated .= "$id$seq\n";
            } else {
                $updated .= "$line\n";
            }
        } else {
            $updated .= "$line\n";
        }
    }
    close IN;
    open OUT, ">$file" or _my_die("cannot open >$file:$!");
    print OUT $updated;
    close OUT;
}

sub _get_dna_params {
    my $rh_part = shift;
    my $cmd = '';
    _my_die("unexpected freq") unless ($rh_part->{'freqs'});
    _my_die("unexpected rate") unless ($rh_part->{'rates'}->{'ac'} &&
          $rh_part->{'rates'}->{'ag'} && $rh_part->{'rates'}->{'ct'} &&
          $rh_part->{'rates'}->{'cg'} && $rh_part->{'rates'}->{'at'} &&
          $rh_part->{'rates'}->{'gt'} );
    $cmd .= "-f$rh_part->{'freqs'} ";
    $cmd .= "-r$rh_part->{'rates'}->{'ac'} $rh_part->{'rates'}->{'ag'} ";
    $cmd .= "$rh_part->{'rates'}->{'at'} $rh_part->{'rates'}->{'cg'} ";
    $cmd .= "$rh_part->{'rates'}->{'ct'} $rh_part->{'rates'}->{'gt'} ";
    return $cmd;
}

sub _get_aa_params {
    my $rh_part = shift;
    my $ra_r = shift;
    my $cmd = '';
    _my_die("unexpected freq") unless ($rh_part->{'freqs'});
    _my_die("unexpected rates") unless (scalar(@{$ra_r}) == 21);
    $cmd .= "-f$rh_part->{'freqs'} ";
    my $j = 0;
    $cmd .= "-r";
    for (my $i = 0; $i < 20; $i++) {
        $j++;
        for (my $k = $j; $k < 20; $k++) {
            $cmd .= "$ra_r->[$i]->[$k], ";
        }
    }
    return $cmd;
}

sub _get_char_params {
    my $rh_part = shift;
    my $cmd = '';
    _my_die("unexpected freq") unless ($rh_part->{'freqs'});
    $rh_part->{'freqs'} =~ s/^\s*//;
    $rh_part->{'freqs'} =~ s/\s*$//;
    my @freqs = split /\s+/, $rh_part->{'freqs'};
    unless (scalar(@freqs) == 2) {
        _my_die("expecting 2 frequencies. Multi-State only works w/binary matrix\n");
    }
    $cmd .= "-f$freqs[0],0.0,0.0,$freqs[1] ";
    return $cmd;
}

sub _build_datasets {
    my $num = shift;
    my $ts = shift;
    my @allseqs = ();
    my $ra_ids = _get_ids_from_seqgen_out($DIR . "seqgen.0.out.test.$ts");

    for (my $i = 0; $i < $num; $i++) {
        my $ra_seqs = _get_seqs_from_seqgen_out($DIR . "seqgen.$i.out.test.$ts");
        push @allseqs, $ra_seqs;
    }
    my $ra_ds = _make_datasets_from_allseqs($ra_ids,\@allseqs);
    return $ra_ds;
}

sub _get_ids_from_seqgen_out {
    my $file = shift;
    my @ids = ();
    open IN, $file or _my_die("cannot open $file:$!");
    my $topline = <IN>;
    while (my $line = <IN>) {
        next if ($line =~ m/^\s*$/);
        last if ($line eq $topline);
        my @fields = split /\s+/, $line;
        push @ids, $fields[0];
    }
    return \@ids;
}

sub _get_seqs_from_seqgen_out {
    my $file = shift;
    my @seqs = ();
    open IN, $file or _my_die("cannot open $file:$!");
    my $topline = <IN>;
    my $count = 0;
    while (my $line = <IN>) {
        next if ($line =~ m/^\s*$/);
        if ($line eq $topline) {
            $count++;
            next;
        }
        chomp $line;
        my @fields = split /\s+/, $line;
        push @{$seqs[$count]}, $fields[1];
    }
    return \@seqs;
}

sub _make_datasets_from_allseqs {
    my $ra_ids = shift;
    my $ra_all = shift;
    my @ds = ();
    foreach my $ra_seqs (@{$ra_all}) {
        for (my $i = 0; $i < @{$ra_seqs}; $i++) {
            for (my $j = 0; $j < @{$ra_ids}; $j++) {
                 $ds[$i]->[$j] .= "$ra_seqs->[$i]->[$j]";
            }
        }
    }
    my $len = _get_len_from_id_lens($ra_ids);
    my @formatted = ();
    my $seqlen = length($ds[0]->[0]);
    my $numseq = scalar(@{$ds[0]});
    my $header = " $numseq $seqlen\n";
    foreach my $ra_d (@ds) {
        my $aln = $header;
        for (my $i = 0; $i < @{$ra_ids}; $i++) {
            $aln .= sprintf("%${len}s", $ra_ids->[$i]);
            $aln .= "$ra_d->[$i]\n";
        }
        push @formatted, $aln;
    }
    return \@formatted;
}

sub _get_len_from_id_lens {
    my $ra_ids = shift;
    my $longest = 0;
    foreach my $id (@{$ra_ids}) {
        $longest = length($id) if (length($id) > $longest);
    }
    my $sprintf_val = (($longest + 1) * -1);
    return $sprintf_val;
}

sub _make_alns {
    my $ra_ds = shift;
    my $ts = shift;
    my @files = ();
    for (my $i = 0; $i < @{$ra_ds}; $i++) {
        my $file = $DIR . "aln.$i.phy.test.$ts";
        open OUT, ">$file" or _my_die("cannot open >$file:$!");
        print OUT $ra_ds->[$i];
        push @files, $file;
    }
    return \@files;
}

sub run_raxml_on_gen_alns {
    my $ra_alns = shift;
    my $rh_opts = shift;
    my $ra_aln_len = shift;
    my $codon_flag = shift;
    my $i = shift;
    my $ts = shift;
    my $part = $rh_opts->{'part'};
    my $mod = $rh_opts->{'mod'};
    my $tre = $rh_opts->{'constraint_tree'};
    if ($codon_flag) {
        my $new_part = $DIR . $NEW_PARTITION_FILE;
        my $ra_part_titles = _get_part_titles($part);
        my $ra_ranges = _print_ranges($ra_aln_len);
        _print_new_part_file($ra_part_titles,$ra_ranges,$new_part);
        _run_rax_on_genset($ra_alns,$mod,$new_part,$tre,$i,$ts);
    } else {
        _run_rax_on_genset($ra_alns,$mod,$part,$tre,$i,$ts);
    }
}

sub _get_part_titles {
    my $part = shift;
    my @titles = ();
    open IN, $part or _my_die("cannot open $part:$!");
    while (my $line = <IN>) {
        chomp $line;
        next if ($line =~ m/^\s*$/);
        if ($line =~ m/^(\s*\S+,\s*\S+\s*=\s*)\d+-\d+\S*\s*$/) {
            my $title = $1;
            push @titles, $title;
        } else {
            _my_die("unexpected line in $part");
        }
    }
    return \@titles;
}

sub _print_ranges {
    my $ra_lens = shift;
    my $i = 0;
    my $last = 0;
    my @ranges = ();
    foreach my $d (@{$ra_lens}) {
        my $lt = ($last + 1);
        my $rt = ($last + $d);
        push @ranges, "$lt-$rt";
        $last += $d;
    }
   return \@ranges;
}

sub _print_new_part_file {
    my $ra_part_titles = shift;
    my $ra_ranges = shift;
    my $file = shift;
    open OUT, ">$file" or _my_die("cannot open $file:$!");
    for (my $i = 0; $i < @{$ra_ranges}; $i++) {
        print OUT "$ra_part_titles->[$i]";
        print OUT "$ra_ranges->[$i]\n";
    }
}

sub _run_rax_on_genset {
    my $ra_alns = shift;
    my $mod     = shift;
    my $part    = shift;
    my $cmd     = '';
    my $tre     = shift;
    my $i       = shift;
    my $ts       = shift;
    $cmd  = "$RAX -p 1234 -w $DIR -m $mod -s $ra_alns->[$i] ";
    $cmd .= "-n $i.ml.test.$ts";
    if ($part) {
        $cmd .= " -q $part ";
    }
    if ($QUIET) {
        $cmd .= " >> ${DIR}sowh_stdout_$NAME.txt ";
        $cmd .= "2>> ${DIR}sowh_stderr_$NAME.txt";
    }
    print "test.$ts - $i";
    safe_system($cmd);
    $cmd  = "$RAX -p 1234 -w $DIR -m $mod -s $ra_alns->[$i] ";
    $cmd .= "-n $i.t1.test.$ts -g $tre";
    if ($part) {
        $cmd .= " -q $part ";
    }
    if ($QUIET) {
        $cmd .= " >> ${DIR}sowh_stdout_$NAME.txt ";
        $cmd .= "2>> ${DIR}sowh_stderr_$NAME.txt";
    }
    print ": ";
    safe_system($cmd);
}

sub evaluate_distribution {
    my $reps = shift;
    my $name = shift;
    my $ra_delta_dist = shift;
    my $ra_deltaprime_dist = shift;
    my $ra_variance = shift;
    my $i = shift;
    my $ts = shift;
    if ($reps < 2) {
        my $ra_dist = _get_distribution($reps,0,$i,$ts);
        my $ra_const_dist = _get_distribution($reps,1,$i,$ts);
        my $best_ml_score = _get_best_score($DIR . "RAxML_info.ml.test.$ts");
        my $best_t1_score = _get_best_score($DIR . "RAxML_info.t1.test.$ts");
        $ra_delta_dist->[$ts] = $best_ml_score - $best_t1_score;
        $ra_deltaprime_dist->[$ts] = $ra_dist->[$i] - $ra_const_dist->[$i];
        my $rh_stats = _get_sowhat_stats($ra_delta_dist,$ra_deltaprime_dist);
        $ra_variance->[$ts] = $rh_stats->{'var'};
        my $fd_file = _print_freq_dist($ra_deltaprime_dist,$name,$reps);
        print "current p-value = $rh_stats->{'p'}\n";
        return ($best_ml_score,$best_t1_score,$rh_stats,$ra_deltaprime_dist,$fd_file);
    } else {        
        my $ra_dist = _get_distribution($reps,0,$i,$ts);
        my $ra_const_dist = _get_distribution($reps,1,$i,$ts);
        my $ra_diff_dist = _get_diff_dist($ra_dist,$ra_const_dist);
        my $best_ml_score = _get_best_score($DIR . "RAxML_info.ml.test.$ts");
        my $best_t1_score = _get_best_score($DIR . "RAxML_info.t1.test.$ts");
        my $rh_stats = _get_stats($ra_diff_dist,$best_ml_score,$best_t1_score);
        $ra_variance->[$i] = $rh_stats->{'var'};
        my $fd_file = _print_freq_dist($ra_diff_dist,$name,$ts);
        print "current p-value = $rh_stats->{'p'}\n";
        return ($best_ml_score,$best_t1_score,$rh_stats,$ra_diff_dist,$fd_file);
   }
}

sub _get_distribution {
    my $reps = shift;
    my $w_const = shift;
    my $j = shift;
    my $ts = shift;
    my @dist = ();
    for (my $i = 0; $i <= $j; $i++) {
        my $file = '';
        if ($w_const) {
            $file = $DIR . "RAxML_info.$i.t1.test.$ts";
        } else {
            $file = $DIR . "RAxML_info.$i.ml.test.$ts";
        }
        open IN, $file or _my_die("cannot open $file:$!");
        while (my $line = <IN>) {
            if ($line =~ m/^Inference\[0\] final[^:]+: ([-0-9.]+)/) {
                my $likelihood = $1;
                _my_die("unexpected multiple matches in $file") if ($dist[$i]);
                $dist[$i] = $likelihood;
            }
            chomp $line;
        }
    }
    return \@dist;
}

sub _get_diff_dist {
    my $ra_d = shift;
    my $ra_cd = shift;

    my @diffs = ();
    for (my $i = 0; $i < @{$ra_d}; $i++) {
        # next if seqgen creates same random sequence and then raxml fails
        next unless ($ra_d->[$i] && $ra_cd->[$i]); 
        push @diffs, ($ra_d->[$i] - $ra_cd->[$i]);
    }
    my @sorted_diffs = sort {$a <=> $b} @diffs;
    return \@sorted_diffs;
}

sub _get_best_score {
    my $file = shift;
    my $ml_score = '';
    open IN, $file or _my_die("cannot open $file:$!");
    while (my $line = <IN>) {
        chomp $line;
        if ($line =~ m/^Final GAMMA-based Score of best tree (\S+)/) {
            $ml_score = $1;
        }
        if ($line =~ m/^Final ML Optimization Likelihood: (\S+)/) {
            $ml_score = $1;
        }
    }
    return $ml_score;
}

sub _get_stats {
    my $ra_dist  = shift;
    my $best_ml  = shift;
    my $const_ml = shift;
    my $R = Statistics::R->new();
    $R->startR();

    my $num = scalar(@{$ra_dist});
    my $diff = $best_ml - $const_ml;
    my $dist_str = join ', ', @{$ra_dist};
my $cmds = <<EOF;
a <- mean(c($dist_str))
s <- sd(c($dist_str))
n <- $num
xbar <- $diff
z <- (xbar-a)/(s/sqrt(n))
p <-  pnorm(z, lower.tail = FALSE)
v <- var(c($dist_str))
a
s
n
xbar
z
p
v
EOF
    my $r_out = $R->run($cmds);
    $R->stopR();
    my $rh_stats = _parse_stats($r_out);
    return $rh_stats;
}

sub _get_sowhat_stats {
    my $ra_delta_dist = shift;
    my $ra_deltaprime_dist = shift;
    my $ts = scalar(@{$ra_deltaprime_dist});
    my $delta_string = @{$ra_delta_dist};
    my $deltaprime_string = @{$ra_deltaprime_dist};
    my $R = Statistics::R->new();
    if($ts > 1) {
        $delta_string = join ', ', @{$ra_delta_dist};
        $deltaprime_string = join ', ', @{$ra_deltaprime_dist};
    }
    $R->startR();

my $cmds = <<EOF;
a <- mean(c($deltaprime_string))
s <- sd(c($deltaprime_string))
n <- $ts
xbar <- mean(c($delta_string))
z <- (xbar-a)/(s/sqrt(n))
p <-  pnorm(z, lower.tail = FALSE)
v <- var(c($deltaprime_string))
a
s
n
xbar
z
p
v
EOF
    my $r_out = $R->run($cmds);
    $R->stopR();
    my $rh_stats = _parse_stats($r_out);
    return $rh_stats;
}

sub _parse_stats {
    my $str = shift;
    my %stats = ();
    $str =~ s/^\[\d+\] // or warn "unexpected output from R";
    my @data = split /\n\[\d+\] /, $str;
    $stats{'mean'} = $data[0];
    $stats{'stdev'} = $data[1];
    $stats{'sample_size'} = $data[2];
    $stats{'diff'} = $data[3];
    $stats{'z'} = $data[4];
    $stats{'p'} = $data[5];
    $stats{'var'} = $data[6];
    return \%stats;
}

sub _print_freq_dist {
    my $ra_d = shift;
    my $name = shift;
    my $ts = shift;
    my %bins = ();
    my @sorted = sort {$a <=> $b} @{$ra_d};
    my $low  = $sorted[0];
    my $high = $sorted[-1];
    my $div = ($high - $low) / $FREQ_BIN_NUMBER;
    my $current_bin = $low;
    my $i = 0;
    while ($i < @sorted) {
        if ($sorted[$i] > ($current_bin + $div)) {
           $current_bin += $div
        } else {
            $bins{$current_bin}++;
        }
        $i++;
    }
    my $d_file = $DIR . "sowh.$name.dist.$ts";
    open OUT, ">$d_file" or _my_die("cannot open >$d_file:$!");
    foreach my $bin (sort {$a <=> $b} keys %bins) {
        print OUT "$bin\t$bins{$bin}\n";
    }
    close OUT;
    return $d_file;
}

sub plot_variance {
    my $ra_variance = shift;
    my $R = Statistics::R->new();  
    if(scalar(@{$ra_variance}) > 1) {
        my $variance_str = join ', ', @{$ra_variance};
        $R->startR();
  
        my $cmds = <<EOF;
variance <- c($variance_str)
png(filename="$DIR/variance.png", height=295, width=300, bg="white")
plot(variance, type="o", col="blue")
dev.off()
EOF
        my $r_out = $R->run($cmds);
        $R->stopR();
    }
}

sub print_report {
    my $ts = shift;
    my $best_ml = shift;
    my $const_ml = shift;
    my $rh_s = shift;
    my $ra_d = shift;
    my $ra_delta_dist = shift;
    my $rh_opts = shift;
    my $fd_file = shift;
    my $version = shift;
    my $file = $DIR . "sowh.info.test";
    $file .= ".$ts" unless($rh_opts->{'sowhat'});
    print "=============================================================\n";
    open OUT, ">$file" or _my_die("cannot open >$file:$!");
    print OUT "\n\n";
    print OUT "=============================================================\n";
    print OUT "                   sowh.pl OUTPUT\n";
    print OUT "=============================================================\n\n";
    print OUT "\n\nProgram was called as follows:\n$0 \\\n";
    foreach my $arg (@{$rh_opts->{'orig_options'}}) {
        print OUT "  $arg \\\n";
    }
    print OUT "\n  \$SEQGEN variable set to $SEQGEN\n";
    print OUT "  \$RAX variable set to $RAX\n";
    print OUT "  RAxML was version $version\n\n";
    print OUT "Null Distribution:\n";
    foreach my $val (@{$ra_d}) {
       print OUT "$val\n";
    }
    print OUT "\nDistribution of Test Statistics\n\n" if($ra_delta_dist);
    foreach my $val (@{$ra_delta_dist}) {
       print OUT "$val\n";
    }
    print OUT "REPS: $rh_opts->{'reps'}\n";
    print OUT "\nSize of null distribution: $rh_s->{'sample_size'}\n";
    print OUT "Mean of null distribution: $rh_s->{'mean'}\n";
    print OUT "Standard deviation of distribution: $rh_s->{'stdev'}\n\n";
    print OUT "Frequency distribution printed to:\n $fd_file\n\n";
    print OUT "ML value of best tree: $best_ml\n";
    print OUT "ML value of best tree w/constraint: $const_ml\n";
    print OUT "Difference between $best_ml and $const_ml: $rh_s->{'diff'}\n";
    print OUT "  (this is the value being tested)\n\n";
    print OUT "z-Score: $rh_s->{'z'}\n";
    print OUT "p-value: $rh_s->{'p'}\n";
    print OUT "  The p-value is the probability that the test value is plausible\n";
    close OUT;
}

sub _my_die {
    my $msg  = shift;
    my $file = "${DIR}sowh_stderr_$NAME.txt";
    open IN, $file or warn "cannot open $file:$!";
    while (my $line = <IN>) {
        warn $line;
    }
    warn "sowh.pl died unexpectedly\n";
    die $msg;
}

sub usage {
    die "usage: $0
    --constraint=NEWICK_CONSTRAINT_TREE
    --aln=PHYLIP_ALIGNMENT
    --name=NAME_FOR_REPORT
    --model=MODEL
    --dir=DIR
    [--rax=RAXML_BINARY_OR_PATH_PLUS_OPTIONS]
    [--seqgen=SEQGEN_BINARY_OR_PATH_PLUS_OPTIONS]
    [--usepb]
    [--pb=PB_BINARY_OR_PATH_PLUS_OPTIONS]
    [--pb_burn=BURNIN_TO_USE_FOR_PB_TREE_SIMULATIONS]
    [--reps=NUMBER_OF_REPLICATES]
    [--tests=NUMBER_OF_TESTS]
    [--partition=PARTITION_FILE]
    [--sowhat]
    [--debug]
    [--help]
    [--version]\n";
}

__END__

=head1 NAME

B<sowh.pl> - The SOWH-Test: A Paramentric Test of Topologies

=head1 AUTHOR

Samuel H. Church <samuel_church@brown.edu>, Joseph F. Ryan <josephryan@yahoo.com>, Casey W. Dunn <casey_dunn@brown.edu>

=head1 SYNOPSIS 

sowh.pl --constraint=NEWICK_CONSTRAINT_TREE --aln=PHYLIP_ALIGNMENT --name=NAME_FOR_REPORT --model=MODEL --dir=DIR [--rax=RAXML_BINARY_OR_PATH_PLUS_OPTIONS] [--seqgen=SEQGEN_BINARY_OR_PATH_PLUS_OPTIONS] [--usepb] [--pb=PB_BINARY_OR_PATH_PLUS_OPTIONS] [--pb_burn=BURNIN_TO_USE_FOR_PB_TREE_SIMULATIONS] [--reps=NUMBER_OF_REPLICATES] [--tests=NUMBER_OF_TESTS] [--partition=PARTITION_FILE] [--sowhat] [--debug] [--help] [--version]\n";

=head1 constraint

=over 2

This programs is designed to test a hypothesized topology, here provided as a constraint tree, against the best topology obtained in a maximum likelihood analysis of the data.

=back

=head1 aln

=over 2

This file is the alignment file which will be used to estimate likelihood scores and free parameters. This alignment file must be in phylip format.

=back

=head1 name

=over 2

This is the name of the output files.

=back

=head1 model

=over 2

This is the model which will be used to estimate the likelihood scores of the original dataset the scores of each of the generated datasets with and without the topology constrained according to the hypothesis. GammaGTR is used to generate parameters for null dataset regardless of the model specified (unless --usepb is specified, in which case phylobayes is used to generate parameters).

=back

=head1 dir

This is the directory where ouput files will be sent.

=back

=head1 OPTIONS

=over 2

=item B<--rax>

<default: raxmlHPC>
This allows the user to specify the RAxML binary to be used in the analysis. It is useful if a user would like to specify the full path to a RAxML binary, but its purpose is mostly to allow users to run a multi-threaded or MPI version of the program, and or pass additional parameters to RAxML. Some examples would be:

    --rax='raxmlHPC-PTHREADS-SSE3 -T 8'

    --rax='mpirun -n 8 raxmlHPC-MPI'

=item B<--seqgen>

<default: seq-gen>
This allows the user to specify the SeqGen binary or path to the binary to be used in the analysis. It could be useful to pass additional parameters to seq-gen

=item B<--usepb>

Use PhyloBayes (pb and ppred programs) to calculate null distribution parameters and generate data sets instead of using RAxML and Seq-Gen. Only works for amino acid and nucleotide datasets (not character data)

=item B<--pb>

<default: pb>
This allows the user to specify the pb binary or path to the binary to be used in the analysis. It could be useful to pass additional parameters to pb (only useful with --usepb)

=item B<--ppred>

<default: ppred>
This allows the user to specify the ppred binary or path to the binary to be used in the analysis. It could be useful to pass additional parameters to ppred (only useful with --usepb)

=item B<--pb_burn>

<default: 10>
This allows the user to specify the burn-in value used for the phylobayes analysis (only useful with --usepb)

=item B<--reps>

<default: 100>
This is the number of datasets which will be generated according to the estimated parameters. This number represents the sample size of the distribution. Each dataset will be evaluated twice for a likelihood score, once with and once without the topology constrained. If using the SOWHat alternative, this is the number of test statistics that will be calculated, the number of times the parameters will be optimized, as well as the number of new alignments that will be generated.

=item B<--tests>
<default: 1>
This is the number of tests which will be performed. If reps are set to 100 and test are set to 10, then there will be 10 separate SOWH tests performed each containing 100 data sets. If using the SOWHat alternative, this will not change the sample size - use the reps option instead.

=item B<--partition>

This can be a partition file which applies to the dataset. It must be in a format recognizable by RAxML version 7.7.0.

=item B<--sowhat>

This option will adjust the SOWH test to account for variability in the maximum likelihood search. In this option, the test statistic and parameters will be recalculated for each alignment generated. The mean test statistic will then be tested against the null distribution using a one tailed test, similar to the SOWH test.

=item B<--debug>

do not redirect standard out and standard error. RAxML in particular will produce lots of output with this option. Can be useful for debugging problems like, for example, bad tree format.

=item B<--help>

Print this manual

=item B<--version>

Print the version. Overrides all other options.

=back

=head1 DESCRIPTION

This program automates the steps required for the SOWH test (as described by Goldman et. al., 2000. It depends on the freely available seq-gen and RAxML software packages. It works on amino acid, nucleotide, and binary character state datasets. Partitions can be specified. It can also use PhyloBayes to simulate the null distribution.

The program calculates the difference between two likelihood scores: that of the best tree, and the best tree constrained by the hypothesized topology. The maximum likelihodd analyses are run using RAxML, a phylogenetic tool written by Alexandros Stamatakis, and freely available under GNU GPL lisence. See:
https://github.com/stamatak/RAxML-Light-1.0.5

This program then generates new alignments based on the hypothesized topology and the maximum number of free parameters from the constrained topology, including branch lengths as well as the frequencies, transtition rates, and alpha values (if available, partitions are taken into account). These datasets are generated using seq-gen, written by Andrew Rambaut and Nick C. Grassly. It is freely available under BSD license, see: 
http://tree.bio.ed.ac.uk/software/seqgen/

The program then calculates the likelihood scores of each of these alignments both with and without the topology constrained according to the hypothesis. The differences between these scores become the distributions against which the test value will be evaluated.

The p-value of the test statistic is calculated using R, using the pnorm function. Information about the test is printed to the file sowh.info.test in the directory specified by the user. The variance of the null distribution is printed to variance.png.

R is freely available under the GPL-2 license.

Nick Goldman, Jon P. Anderson, and Allen G. Rodrigo
Likelihood-Based Tests of Topologies in Phylogenetics
Syst Biol (2000) 49 (4): 652-670 doi:10.1080/106351500750049752

Here is an example command using the test datasets:

=over 2

perl sowh.pl ...

=back

=head1 BUGS

Please report them to any or all of the authors.

=head1 COPYRIGHT

Copyright (C) 2012,2013 Samuel H. Church, Joseph F. Ryan, Casey W. Dunn

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

=cut
