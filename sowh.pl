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

our $VERSION = 0.04;

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;
use Cwd;
use Statistics::R;

our $RAX = 'raxmlHPC';
our $SEQGEN = 'seq-gen';
our $DEFAULT_REPS = 100;
our $DEVNULL = 1; # change to 0 if you want to see tons of RAxML output

# don't adjust below here
our $DIR = '.';
our $FREQ_BIN_NUMBER = 10;
our $TRE_PREFIX = 'RAxML_bestTree';
our $NEW_PARTITION_FILE = 'new.part.txt';
our $PART_RATE_MATRIX_PREFIX = 'RAxML_proteinGTRmodel.par_Partition_';

MAIN: {
    my $rh_opts = process_options();

    run_initial_trees($rh_opts->{'aln'},$rh_opts->{'part'},
        $rh_opts->{'mod'},$rh_opts->{'constraint_tree'});

    my $ver = get_version($DIR . 'RAxML_info.t1');
    
    my ($ra_aln_len,$codon_flag,$ra_params,$ra_rates) = 
        get_params($rh_opts->{'aln'},$rh_opts->{'part'},
        $rh_opts->{'mod'},$rh_opts->{'constraint_tree'},);

    my $ra_alns = generate_alignments($ra_aln_len,$ra_params,
        $ra_rates,$rh_opts->{'mod'},$rh_opts->{'reps'});

    run_raxml_on_gen_alns($ra_alns,$rh_opts->{'part'},
        $rh_opts->{'mod'},$rh_opts->{'constraint_tree'},
        $ra_aln_len,$codon_flag);

    my ($best_ml,$best_t1,$rh_stats,$ra_diff,$fd_file) =
            evaluate_distribution($rh_opts->{'reps'},$rh_opts->{'name'});

    print_report($best_ml,$best_t1,$rh_stats,$ra_diff,$rh_opts,$fd_file,$ver);
}

sub process_options {
    my $rh_opts = {};
    $rh_opts->{'reps'} = $DEFAULT_REPS;
    $rh_opts->{'orig_options'} = [@ARGV];
    $rh_opts->{'rax'} = $RAX;
    $rh_opts->{'seqgen'} = $SEQGEN;

    my $opt_results = Getopt::Long::GetOptions(
                              "version" => \$rh_opts->{'version'},
                         "constraint=s" => \$rh_opts->{'constraint_tree'},
                                "aln=s" => \$rh_opts->{'aln'},
                                "dir=s" => \$rh_opts->{'dir'},
                               "reps=i" => \$rh_opts->{'reps'},
                             "seqgen=s" => \$rh_opts->{'seqgen'},
                                "rax=s" => \$rh_opts->{'rax'},
                          "partition=s" => \$rh_opts->{'part'},
                              "model=s" => \$rh_opts->{'mod'},
                               "name=s" => \$rh_opts->{'name'},
                                 "help" => \$rh_opts->{'help'});

    $RAX = $rh_opts->{'rax'} if ($rh_opts->{'rax'});
    $SEQGEN = $rh_opts->{'seqgen'} if ($rh_opts->{'seqgen'});
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
    set_out_dir($rh_opts->{'dir'});
    return $rh_opts;
}

sub set_out_dir {
    my $opt_dir = shift;
    my $pwd = getcwd();
    $opt_dir = "$pwd/$opt_dir" if (($opt_dir) && ($opt_dir !~ m/^\//));
    $opt_dir .= '/' if (($opt_dir) && ($opt_dir !~ m/\/$/));
    $DIR = $opt_dir if ($opt_dir);
    mkdir $DIR unless (-d $DIR);
}

sub safe_system {
    my $cmd = shift;
    warn "\$cmd = $cmd\n";
    my $error = system $cmd;
    warn "system call failed:\n$cmd\nerror code=$?" if ($error != 0);
}

sub run_initial_trees {
    my $aln = shift;
    my $part = shift;
    my $mod = shift;
    my $tre = shift;
    _run_best_tree('ml',$aln,$part,$mod);
    _run_best_tree('t1',$aln,$part,$mod,$tre);
}

sub _run_best_tree {
    my $name = shift;
    my $aln = shift;
    my $part = shift;
    my $mod  = shift;
    my $tre = shift;
    my $cmd = "$RAX -f d -p 1234 -w $DIR -m $mod -s $aln -n $name";
    $cmd .= " -q $part" if ($part);
    $cmd .= " -g $tre" if ($tre);
    $cmd .= " > /dev/null 2> /dev/null" if ($DEVNULL);
    safe_system($cmd);
}

sub get_version {
    my $file = shift;
    my $version = 0;
    my @fields = ();
    open IN, "$file" or die "cannot open $file:$!";
    while (my $line = <IN>) {
        if ($line =~ m/^This is RAxML version ((\d+\.\d+)\S+)/) {
            $version =  $2;
            my $whole_version =  $1;
            if ($version < 7.7) {
                unlink ($DIR . 'RAxML_info.t1');
                warn "sowh.pl ERROR:\n";
                warn "You are running version $whole_version of RAxML\n";
                die  "sowh.pl requires version 7.7 or higher\n";
            }
        }
    }
    return $version;
}

sub get_params {
    my $aln = shift;
    my $part = shift;
    my $mod = shift;
    my $tre = shift;
    my $ra_aln_len = ();
    my $codon_flag = 0;
    my $ra_params = ();
    my $ra_rates = ();
    if ($mod =~ m/^GTRGAMMA/i) {
        ($ra_aln_len,$codon_flag,$ra_params) =
           _model_gtrgamma($aln,$part,$tre);
    } elsif ($mod =~ m/^PROT/i) {
        ($ra_aln_len,$codon_flag,$ra_params,$ra_rates) =
           _model_prot($aln,$part,$tre);      
    } else {
        ($ra_aln_len,$codon_flag,$ra_params) =
           _model_non_gtr($aln,$part,$tre);        
    }
    return ($ra_aln_len,$codon_flag,$ra_params,$ra_rates);   
}

sub _model_gtrgamma {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    my ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
    my ($ra_params) = _get_params_from_const_rax($DIR . 'RAxML_info.t1');
    return ($ra_aln_len,$codon_flag,$ra_params);
}

sub _model_prot {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    my $ra_aln_len = ();
    my $codon_flag = 0;
    my $ra_params = ();
    my $ra_rates = ();
    my $new_part = $DIR . $NEW_PARTITION_FILE;
    if ($part) {
        my $ra_part_names = _make_unlinked_partition_file($part,$new_part);
        _run_best_tree('par',$aln,$new_part,'PROTGAMMAGTR_UNLINKED',$tre);
        $ra_rates = _parse_rates($ra_part_names);
        ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
        $ra_params = _get_params_from_const_rax($DIR . 'RAxML_info.par');
    } else {
        _run_best_tree('par',$aln,$part,'PROTGAMMAGTR_UNLINKED',$tre);
        $ra_rates = _parse_rates();
        ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
        $ra_params = _get_params_from_const_rax($DIR . 'RAxML_info.par');
    }
    return ($ra_aln_len,$codon_flag,$ra_params,$ra_rates);      
}

sub _model_non_gtr {
    my $aln = shift;
    my $part = shift;
    my $tre = shift;
    _run_best_tree('par',$aln,$part,'GTRGAMMA',$tre);
    my ($ra_aln_len,$codon_flag) = _get_partition_lengths($aln,$part);
    my $ra_params = _get_params_from_const_rax($DIR . 'RAxML_info.par');
    return ($ra_aln_len,$codon_flag,$ra_params);
}

sub _get_partition_lengths {
    my $aln = shift;
    my $part = shift;
    my $codon_flag = 0;
    my @lens = ();
    if ($part) {
        open IN, $part or die "cannot open $part:$!";
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
                die "unexpected line in $part";
            }
        }
    } else {
        open IN, $aln or die "cannot open $aln:$!";
        my $line = <IN>;
        if ($line =~ m/^\s*\d+\s+(\d+)\s*$/) {
            @lens = $1;
        } else {
            die "Alignment file should be in PHYLIP format\n";
        }
    }
    return (\@lens,$codon_flag);
}

sub _get_params_from_const_rax {
    my $file = shift;
    my @data = ();
    open IN, "$file" or die "cannot open $file:$!";
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
                die "unexpected line: $line";
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
    open IN, $part or die "cannot open $part:$!";
    my @fields = ();
    my @part_info = ();
    my @names = ();
    while (my $line = <IN>) {
        chomp $line;
        next if ($line =~ m/^\s*$/);
        @fields = split/\,/, $line;
        $fields[1] or die "unexpected line in part file:$line\nexpecting comma";
        push @part_info, $fields[1];
        my @name_range = split /=/, $fields[1];
        $name_range[1] or die "unexpected line in part file:$line\nexpecting =";
        $name_range[0] =~ s/\s//g;
        push @names, $name_range[0];
   }
   return (\@part_info,\@names);
}

sub _print_unlinked_part {
    my $part_info = shift;
    my $new_part = shift;
    open OUT, ">$new_part" or die "cannot open $new_part:$!";
    for (my $i = 0; $i < @{$part_info}; $i++) {
       print OUT "GTR_UNLINKED," . "$part_info->[$i]\n";
    }
}

sub _parse_rates {
    my $ra_part_names = shift;
    my @rates = ();
    if ($ra_part_names) {
        foreach my $pn (@{$ra_part_names}) {
            my @local_rates = ();
            my $matrix = $DIR . $PART_RATE_MATRIX_PREFIX . $pn;
            open IN, "$matrix" or die "cannot open $matrix:$!";
            while (my $line = <IN>) {
                my @fields = split/\s/, $line;
                push @local_rates, \@fields;
            }
            push @rates, \@local_rates;
        }
    } else {
        my $matrix = $DIR . $PART_RATE_MATRIX_PREFIX . 'No Name Provided';
        open IN, "$matrix" or die "cannot open $matrix:$!";
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
    _run_seqgen($ra_aln_len,$ra_params,$ra_rates,$mod,$reps);
    my $ra_ds = _build_datasets(scalar(@{$ra_params}));
    my $ra_alns = _make_alns($ra_ds);
}

sub _run_seqgen {
    my $ra_part_lens = shift;
    my $ra_params = shift;
    my $ra_rates = shift;
    my $model = shift;
    my $reps  = shift;
    my $count = 0;
    for (my $i = 0; $i < @{$ra_params}; $i++) {
        my $rh_part = $ra_params->[$i];
        my $cmd = "$SEQGEN -or ";
        $cmd .= "-l$ra_part_lens->[$i] ";
        $cmd .= "-a$rh_part->{'alpha'} ";
        if ($rh_part->{'type'} eq 'DNA') {
            $cmd .= "-m$model -n$reps ";
            $cmd .= _get_dna_params($rh_part);
        } elsif ($rh_part->{'type'} eq 'AA') {
            $cmd .= "-mGENERAL -n$reps ";
            $cmd .= _get_aa_params($rh_part,$ra_rates->[$i]);
        } else {
            die qq~do not know how to handle type: "$rh_part->{'type'}"\n~;
        }
        $cmd .= " < $DIR" . "$TRE_PREFIX.t1 > $DIR" . "seqgen.$count.out";
        $count++;
        safe_system($cmd);
    }
}

sub _get_dna_params {
    my $rh_part = shift;
    my $cmd = '';
    die "unexpected freq" unless ($rh_part->{'freqs'});
    die "unexpected rate" unless ($rh_part->{'rates'}->{'ac'} &&
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
    die "unexpected freq" unless ($rh_part->{'freqs'});
    die "unexpected rates" unless (scalar(@{$ra_r}) == 21);
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

sub _build_datasets {
    my $num = shift;
    my @allseqs = ();
    my $ra_ids = _get_ids_from_seqgen_out($DIR . "seqgen.0.out");

    for (my $i = 0; $i < $num; $i++) {
        my $ra_seqs = _get_seqs_from_seqgen_out($DIR . "seqgen.$i.out");
        push @allseqs, $ra_seqs;
    }
    my $ra_ds = _make_datasets_from_allseqs($ra_ids,\@allseqs);
    return $ra_ds;
}

sub _get_ids_from_seqgen_out {
    my $file = shift;
    my @ids = ();
    open IN, $file or die "cannot open $file:$!";
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
    open IN, $file or die "cannot open $file:$!";
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
    my @files = ();
    for (my $i = 0; $i < @{$ra_ds}; $i++) {
        my $file = $DIR . "aln.$i.phy";
        open OUT, ">$file" or die "cannot open >$file:$!";
        print OUT $ra_ds->[$i];
        push @files, $file;
    }
    return \@files;
}

sub run_raxml_on_gen_alns {
    my $ra_alns = shift;
    my $part = shift;
    my $mod = shift;
    my $tre = shift;
    my $ra_aln_len = shift;
    my $codon_flag = shift;
    if ($codon_flag) {
        my $new_part = $DIR . $NEW_PARTITION_FILE;
        my $ra_part_titles = _get_part_titles($part);
        my $ra_ranges = _print_ranges($ra_aln_len);
        _print_new_part_file($ra_part_titles,$ra_ranges,$new_part);
        _run_rax_on_genset($ra_alns,$mod,$new_part,'');
        _run_rax_on_genset($ra_alns,$mod,$new_part,$tre);
    } else {
        _run_rax_on_genset($ra_alns,$mod,$part,'');
        _run_rax_on_genset($ra_alns,$mod,$part,$tre);
    }
}

sub _get_part_titles {
    my $part = shift;
    my @titles = ();
    open IN, $part or die "cannot open $part:$!";
    while (my $line = <IN>) {
        chomp $line;
        next if ($line =~ m/^\s*$/);
        if ($line =~ m/^(\s*\S+,\s*\S+\s*=\s*)\d+-\d+\S*\s*$/) {
            my $title = $1;
            push @titles, $title;
        } else {
            die "unexpected line in $part";
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
    open OUT, ">$file" or die "cannot open $file:$!";
    for (my $i = 0; $i < @{$ra_ranges}; $i++) {
        print OUT "$ra_part_titles->[$i]";
        print OUT "$ra_ranges->[$i]\n";
    }
}

sub _run_rax_on_genset {
    my $ra_alns = shift;
    my $mod     = shift;
    my $part    = shift;
    my $tre     = shift;
    for (my $i = 0; $i < @{$ra_alns}; $i++) {
        my $cmd  = "$RAX -p 1234 -w $DIR -m $mod -s $ra_alns->[$i] ";
        if ($tre) {
           $cmd .= "-n $i.t1 -g $tre";
        } else {
           $cmd .= "-n $i.ml";
        }
        if ($part) {
           $cmd .= " -q $part ";
        }
        $cmd .= " > /dev/null 2> /dev/null" if ($DEVNULL);
        print ".";
        safe_system($cmd);
    }
    print "\n";
}

sub evaluate_distribution {
    my $reps = shift;
    my $name = shift;
    my $opts = shift;
    my $ra_dist = _get_distribution($reps,0);
    my $ra_const_dist = _get_distribution($reps,1);
    my $ra_diff_dist = _get_diff_dist($ra_dist,$ra_const_dist);
    my $best_ml_score = _get_best_score($DIR . 'RAxML_info.ml');
    my $best_t1_score = _get_best_score($DIR . 'RAxML_info.t1');
    my $rh_stats = _get_stats($ra_diff_dist,
        $best_ml_score,$best_t1_score);
    my $fd_file = _print_freq_dist($ra_diff_dist,$name);
    return ($best_ml_score,$best_t1_score, $rh_stats,
            $ra_diff_dist,$fd_file);
}

sub _get_distribution {
    my $reps = shift;
    my $w_const = shift;
    my @dist = ();
    for (my $i = 0; $i < $reps; $i++) {
        my $file = '';
        if ($w_const) {
            $file = $DIR . "RAxML_info.$i.t1";
        } else {
            $file = $DIR . "RAxML_info.$i.ml";
        }
        open IN, $file or die "cannot open $file:$!";
        while (my $line = <IN>) {
            if ($line =~ m/^Inference\[0\] final[^:]+: ([-0-9.]+)/) {
                my $likelihood = $1;
                die "unexpected multiple matches in $file" if ($dist[$i]);
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
    open IN, $file or die "cannot open $file:$!";
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
a
s
n
xbar
z
p
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
    return \%stats;
}

sub _print_freq_dist {
    my $ra_d = shift;
    my $name = shift;
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
    my $d_file = $DIR . "sowh.$name.dist";
    open OUT, ">$d_file" or die "cannot open >$d_file:$!";
    foreach my $bin (sort {$a <=> $b} keys %bins) {
        print OUT "$bin\t$bins{$bin}\n";
    }
    close OUT;
    return $d_file;
}

sub print_report {
    my $best_ml = shift;
    my $const_ml = shift;
    my $rh_s = shift;
    my $ra_d = shift;
    my $rh_opts = shift;
    my $fd_file = shift;
    my $version = shift;
    print "\n\n";
    print "=============================================================\n";
    print "                   sowh.pl OUTPUT\n";
    print "=============================================================\n\n";
    print "\n\nProgram was called as follows:\n$0 \\\n";
    foreach my $arg (@{$rh_opts->{'orig_options'}}) {
        print "  $arg \\\n";
    }
    print "\n  \$SEQGEN variable set to $SEQGEN\n";
    print "  \$RAX variable set to $RAX\n";
    print "  RAxML was version $version\n\n";
    print "Distribution of differences between ML vals of simulated sets:\n";
    foreach my $val (@{$ra_d}) {
       print "$val\n";
    }
    print "REPS: $rh_opts->{'reps'}\n";
    print "\nSize of this distribution: $rh_s->{'sample_size'}\n";
    if ($rh_s->{'sample_size'} != $rh_opts->{'reps'}) {
        print "NOTE: size of the distribution ($rh_s->{'sample_size'}) ";
        print "differs from reps ($rh_opts->{'reps'})\n";
        print "  this can happen if seq-gen produces 2 of the same sequences ";
        print "in a dataset,\n";
        print "  which will cause RAxML to fail on that dataset\n";
    }
    print "Mean of this distribution: $rh_s->{'mean'}\n";
    print "Standard deviation of distribution: $rh_s->{'stdev'}\n\n";
    print "Frequency distribution printed to:\n  $fd_file\n\n";
    print "ML value of best tree: $best_ml\n";
    print "ML value of best tree w/constraint: $const_ml\n";
    print "Difference between $best_ml and $const_ml: $rh_s->{'diff'}\n";
    print "  (this is the value being tested)\n\n";
    print "z-Score: $rh_s->{'z'}\n";
    print "p-value: $rh_s->{'p'}\n";
    print "  The p-value is the probability that the test value is plausible\n";
}

sub usage {
    die "usage: $0
    --constraint=NEWICK_CONSTRAINT_TREE
    --aln=PHYLIP_ALIGNMENT
    --name=NAME_FOR_REPORT
    --model=MODEL
    [--rax=RAXML_BINARY_OR_PATH_PLUS_OPTIONS]
    [--seqgen=SEQGEN_BINARY_OR_PATH_PLUS_OPTIONS]
    [--reps=NUMBER_OF_REPLICATES]
    [--dir=DIR]
    [--partition=PARTITION_FILE]
    [--help]
    [--version]\n";
}

__END__

=head1 NAME

B<sowh.pl> - The SOWH-Test: A Paramentric Test of Topologies

=head1 AUTHOR

Samuel H. Church <samuel_church@brown.edu>, Joseph F. Ryan <josephryan@yahoo.com>, Casey W. Dunn <casey_dunn@brown.edu>

=head1 SYNOPSIS 

sowh.pl --constraint=NEWICK_CONSTRAINT_TREE --aln=PHYLIP_ALIGNMENT --name=NAME_FOR_REPORT --model=MODEL [--reps=NUMBER_OF_REPLICATES] [--dir=DIR] [--partition=PARTITION_FILE] [--help] [--version]

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

This is the model which will be used to estimate the likelihood scores of the original dataset the scores of each of the generated datasets with and without the topology constrained according to the hypothesis.

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
This allows the user to specify the SeqGen binary or path to the binary to be used in the analysis. It could be useful to pass additional parameters to seq-gen.

=item B<--reps>

<default: 100>
This is the number of datasets which will be generated according to the estimated parameters. This number represents the sample size of the distribution. Each dataset will be evaluated twice for a likelihood score, once with and once without the topology constrained.

=item B<--dir>

<default: current directory>
This is the directory where ouput files will be sent.

=item B<--partition>

This can be a partition file which applies to the dataset. It must be in a format recognizable by RAxML version 7.7.0.

=item B<--help>

Print this manual

=item B<--version>

Print the version. Overrides all other options.

=back

=head1 DESCRIPTION

This script will calculate the plausability of a likelihood score measured against the likelihood value of the best tree as obtained through a maximum likelihood evaluation. This is known as a parametric test of topologies or a SOWH test (Goldman et al, 2000).
This test runs two trees on the original alignment file, one using the given constraint topology and one without. The difference in the likelihood scores of these trees is the value which will be tested against the distribution obtained from the script. The maximum likelihodd analyses are run using RAxML, a phylogenetic tool written by Alexandros Stamatakis, and freely available under GNU GPL lisence. See:
https://github.com/stamatak/RAxML-Light-1.0.5
This script then generates new alignments based on the hypothesized topology and the maximum number of free parameters available. If the original model does not maximize free parameters, a new tree is run using the constrained topology. These datasets incorporate the constrained topology, including partitions if available, as well as the frequencies, transtition rates, and alpha values from the constrained optimization. The datasets are generated using seq-gen, written by Andrew Rambaut and Nick C. Grassly. It is freely available under BSD license, see: 
http://tree.bio.ed.ac.uk/software/seqgen/
This script then calculated the likelihood scores of each of these alignments both with and without the topology constrained according to the hypothesis. The differences between these scores become the distributions against which the test value will be evaluated.
The p-value of the test statistic is calculated using R, using the pnorm function.
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
