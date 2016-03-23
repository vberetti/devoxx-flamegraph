#!/usr/bin/perl -w
#
# stackcolllapse-perf.pl	collapse perf samples into single lines.
#
# Parses a list of multiline stacks generated by "perf script", and
# outputs a semicolon separated stack followed by a space and a count.
# If memory addresses (+0xd) are present, they are stripped, and resulting
# identical stacks are colased with their counts summed.
#
# USAGE: ./stackcollapse-perf.pl [options] infile > outfile
#
# Run "./stackcollapse-perf.pl -h" to list options.
#
# Example input:
#
#  swapper     0 [000] 158665.570607: cpu-clock:
#         ffffffff8103ce3b native_safe_halt ([kernel.kallsyms])
#         ffffffff8101c6a3 default_idle ([kernel.kallsyms])
#         ffffffff81013236 cpu_idle ([kernel.kallsyms])
#         ffffffff815bf03e rest_init ([kernel.kallsyms])
#         ffffffff81aebbfe start_kernel ([kernel.kallsyms].init.text)
#  [...]
#
# Example output:
#
#  swapper;start_kernel;rest_init;cpu_idle;default_idle;native_safe_halt 1
#
# Input may be created and processed using:
#
#  perf record -a -g -F 997 sleep 60
#  perf script | ./stackcollapse-perf.pl > out.stacks-folded
#
# The output of "perf script" should include stack traces. If these are missing
# for you, try manually selecting the perf script output; eg:
#
#  perf script -f comm,pid,tid,cpu,time,event,ip,sym,dso,trace | ...
#
# This is also required for the --pid or --tid options, so that the output has
# both the PID and TID.
#
# Copyright 2012 Joyent, Inc.  All rights reserved.
# Copyright 2012 Brendan Gregg.  All rights reserved.
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at docs/cddl1.txt or
# http://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at docs/cddl1.txt.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
# 02-Mar-2012	Brendan Gregg	Created this.
# 02-Jul-2014	   "	  "	Added process name to stacks.

use strict;
use Getopt::Long;

my %collapsed;

sub remember_stack {
	my ($stack, $time) = @_;
  $collapsed{$stack} += $time;
}
my $annotate_kernel = 0; # put an annotation on kernel function
my $include_pname = 1;	# include process names in stacks
my $include_pid = 0;	# include process ID with process name
my $include_tid = 0;	# include process & thread ID with process name
my $tidy_java = 1;	# condense Java signatures
my $tidy_generic = 1;	# clean up function names a little
my $target_pname;	# target process name from perf invocation

my $show_inline = 0;
my $show_context = 0;
GetOptions('inline' => \$show_inline,
           'context' => \$show_context,
           'pid' => \$include_pid,
           'kernel' => \$annotate_kernel,
           'tid' => \$include_tid)
or die <<USAGE_END;
USAGE: $0 [options] infile > outfile\n
	--pid		# include PID with process names [1]
	--tid		# include TID and PID with process names [1]
	--inline	# un-inline using addr2line
	--kernel	# annotate kernel functions with a _[k]
	--context	# include source context from addr2line\n
[1] perf script must emit both PID and TIDs for these to work; eg:
	perf script -f comm,pid,tid,cpu,time,event,ip,sym,dso,trace
USAGE_END

# for the --inline option
sub inline {
	my ($pc, $mod) = @_;

	# capture addr2line output
	my $a2l_output = `addr2line -a $pc -e $mod -i -f -s -C`;

	# remove first line
	$a2l_output =~ s/^(.*\n){1}//;

	my @fullfunc;
	my $one_item = "";
	for (split /^/, $a2l_output) {
		chomp $_;

		# remove discriminator info if exists
		$_ =~ s/ \(discriminator \S+\)//;

		if ($one_item eq "") {
			$one_item = $_;
		} else {
			if ($show_context == 1) {
				unshift @fullfunc, $one_item . ":$_";
			} else {
				unshift @fullfunc, $one_item;
			}
			$one_item = "";
		}
	}

	return join(";", @fullfunc);
}

my @stack;
my $pname;
my $ptime;

#
# Main loop
#
while (defined($_ = <>)) {

	# find the name of the process launched by perf, by stepping backwards
	# over the args to find the first non-option (no dash):
	if (/^# cmdline/) {
		my @args = split ' ', $_;
		foreach my $arg (reverse @args) {
			if ($arg !~ /^-/) {
				$target_pname = $arg;
				$target_pname =~ s:.*/::;  # strip pathname
				last;
			}
		}
	}

	# skip remaining comments
	next if m/^#/;
	chomp;

	# end of stack. save cached data.
	if (m/^$/) {
		if ($include_pname) {
			if (defined $pname) {
				unshift @stack, $pname;
			} else {
				unshift @stack, "";
			}
		}
		remember_stack(join(";", @stack), $ptime) if @stack;
		undef @stack;
		undef $pname;
		undef $ptime;
		next;
	}

	# event record start
	if (/^(\S+\s*?\S*?)\s+(\d+)\s+(\d+)/) {
		# default "perf script" output has TID but not PID
		# eg, "java tid time"
		# other combinations possible
		if ($include_tid) {
			$pname = "$1-?/$2";
		} elsif ($include_pid) {
			$pname = "$1-?";
		} else {
			$pname = $1;
		}
		$ptime = $3;

		$pname =~ tr/ /_/;
	} elsif (/^(\S+\s*?\S*?)\s+(\d+)\/(\d+)/) {
		# eg, "java 24636/25607 [000] 4794564.109216: cycles:"
		# eg, "java 12688/12764 6544038.708352: cpu-clock:"
		# eg, "V8 WorkerThread 24636/25607 [000] 94564.109216: cycles:"
		# other combinations possible
		if ($include_tid) {
			$pname = "$1-$2/$3";
		} elsif ($include_pid) {
			$pname = "$1-$2";
		} else {
			$pname = $1;
		}
		$pname =~ tr/ /_/;

	# stack line
	} elsif (/^\s*(\w+)\s*(.+)/) {
		my ($pc, $func) = ($1, $2);
		next if $func =~ /^\(/;		# skip process names

		if ($tidy_generic) {
			$func =~ s/;/:/g;
			$func =~ tr/<>//d;
			if ($func !~ m/\.\(.*\)\./) {
				# This doesn't look like a Go method name (such as
				# "net/http.(*Client).Do"), so everything after the first open
				# paren is just noise.
				$func =~ s/\(.*//;
			}
			# now tidy this horrible thing:
			# 13a80b608e0a RegExp:[&<>\"\'] (/tmp/perf-7539.map)
			$func =~ tr/"\'//d;
			# fall through to $tidy_java
		}

		if ($tidy_java and $pname eq "java") {
			# along with $tidy_generic, converts the following:
			#	Lorg/mozilla/javascript/ContextFactory;.call(Lorg/mozilla/javascript/ContextAction;)Ljava/lang/Object;
			#	Lorg/mozilla/javascript/ContextFactory;.call(Lorg/mozilla/javascript/C
			#	Lorg/mozilla/javascript/MemberBox;.<init>(Ljava/lang/reflect/Method;)V
			# into:
			#	org/mozilla/javascript/ContextFactory:.call
			#	org/mozilla/javascript/ContextFactory:.call
			#	org/mozilla/javascript/MemberBox:.init
			$func =~ s/^L// if $func =~ m:/:;
		}

		unshift @stack, $func;
	} else {
		warn "Unrecognized line: $_";
	}
}

foreach my $k (sort { $a cmp $b } keys %collapsed) {
  my $tms =  $collapsed{$k} / 1000000;
	print "$k $tms\n";
}
