#!/bin/bash
# run-guarded.sh <secs> <cmd...>: run cmd in its own process group with a time ceiling AND a memory ceiling.
# Exit 124 on timeout, 125 when any single process in the group passes GUARD_MEM_MB, else cmd's status.
# Default ceiling: a quarter of physical RAM, at least 2048 MB (9 GB on a 36 GB Mac). At 0.2 s polls a runaway
# allocating 8 GB/s overshoots by about 1.6 GB, which stays safe. Per process, not per group: Flutter runs
# several flutter_tester processes in parallel and their sum is legitimate.
# Why (run 20261106-229-230): a mutant that looped forever pushing to a Vec reached 28.5 GB of RSS on a 36 GB Mac
# inside its 180 s time limit; the compressor hit its limit and the kernel panicked (watchdog timeout, no checkins
# in 94 s). A time limit alone can't stop that. macOS doesn't enforce RLIMIT_AS, so this polls RSS.
exec perl -e '
  use POSIX ":sys_wait_h";
  my $t = shift; my $ram_mb = int((`sysctl -n hw.memsize 2>/dev/null` || 0) / 1048576);
  my $def = int($ram_mb / 4); $def = 2048 if $def < 2048;
  my $limit_kb = ($ENV{GUARD_MEM_MB} || $def) * 1024;
  my $pid = fork; die "fork: $!" unless defined $pid;
  if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127 }
  my $term = sub { kill "TERM", -$pid; for (1 .. 10) { last unless kill 0, -$pid; sleep 1 } kill "KILL", -$pid };
  $SIG{INT} = $SIG{TERM} = sub { $term->(); exit 130 };
  my $deadline = time + $t;
  while (1) {
    my $r = waitpid($pid, WNOHANG);
    if ($r == $pid) { my $s = $?; exit($s & 127 ? 128 + ($s & 127) : $s >> 8) }
    if (time >= $deadline) { $term->(); waitpid($pid, 0); exit 124 }
    for (`ps -A -o pgid=,pid=,rss=,comm=`) {
      my ($pg, $p, $rss, $comm) = /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/ or next;
      next unless $pg == $pid && $rss > $limit_kb;
      printf STDERR "GUARD MEMORY: %s (pid %d) at %d MB passed the %d MB ceiling; killing process group %d\n", $comm, $p, $rss / 1024, $limit_kb / 1024, $pid;
      kill "KILL", -$pid; waitpid($pid, 0); exit 125;
    }
    select(undef, undef, undef, 0.2);
  }' "$@"
