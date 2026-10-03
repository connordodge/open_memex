#!/bin/bash
# mutation-spot.sh — single-operator mutation spot-check on the ADDED lines of one package
# (open_memex adapter: Rust crates under crates/, the Flutter app under app/).
#
#   mutation-spot.sh --worktree <dir> --base <ref> --pkg <pkg> [--tests "<files>"]
#                    [--max 12] [--timeout 900] [--threshold 25] [--count-only]
#
#   --worktree   git worktree holding the code under test (the gate worktree mid-merge, or a WI
#                worktree). Mutated files are always restored; the script verifies it.
#   --base       added lines = `git diff -U0 $(git merge-base <base> HEAD) -- <file>` (working
#                tree vs the fork point, so it works mid-merge and on a WI branch)
#   --pkg        crates/<crate>  -> mutates crates/<crate>/src/**.rs, only the code ABOVE the
#                                   file's first `#[cfg(test)]` line; runs `cargo test -p <crate>`
#                                   (the [package] name from its Cargo.toml) per mutant
#                app             -> mutates app/lib/**.dart (generated *.g.dart / *.freezed.dart /
#                                   *.mocks.dart and GENERATED CODE headers skipped); runs
#                                   `flutter test <tests>` per mutant (the full app suite if
#                                   --tests is empty)
#   --tests      Dart test files to run per mutant (repo- or package-relative). Ignored for Rust:
#                the whole crate's suite runs.
#   --max        mutants to evaluate (default 12, hard cap 20 to bound gate time)
#   --timeout    ceiling per test run in seconds (default 900); each mutant gets
#                min(timeout, max(180, 3 x baseline + 60))
#   --threshold  FAIL if survivors > max(1, floor(evaluated x threshold / 100)) (default 25)
#   --count-only print "MUTATION SITES: <n>" and exit 0 (merge-check uses it to split budget)
#
# Operators (one occurrence per mutant; string/char literals, raw strings and comments are
# masked over the whole file, so multi-line SQL raw strings are never mutated):
#   == <-> !=, ' < ' -> ' <= ', ' > ' -> ' >= ', ' <= ' -> ' < ', ' >= ' -> ' > ',
#   && <-> || (Rust: only between operands, ' && ' / ' || ', never closures), true <-> false,
#   '+ 1' <-> '- 1'.
# Skipped lines: Dart import/export/part/library/annotation/`operator` declarations; Rust
# use/mod/extern/attribute (#[...]) lines and everything from `#[cfg(test)]` down. Sites are
# picked deterministically, spread round-robin across files and evenly within each file.
# No return-value / early-return mutants (the Epic Focus source has none either).
#
# Per mutant: KILLED (tests fail), SURVIVED (tests pass). Two outcomes are NOT counted and the
# next candidate site is tried instead: INVALID (any compile error — the baseline compiled, so
# the mutant broke compilation) and TIMEOUT (run hit the time limit with no test failure seen).
# Dart null comparisons and bare parameter defaults (`this.flag = false,`) are tried last.
# At most 4 x max sites are attempted.
#
# Output: MUTANT KILLED|SURVIVED|INVALID|TIMEOUT <file>:<line>  <before> -> <after>
#         MUTATION OK|FAIL: k killed, s survived   (or MUTATION SKIP: <why>)
# Exit: 0 OK/SKIP, 1 FAIL or error.
set -uo pipefail

WT=""; BASE=""; PKG=""; TESTS=""; MAX=12; TIMEOUT=900; THRESHOLD=25; COUNT_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) WT=${2:-}; shift 2 ;;
    --base) BASE=${2:-}; shift 2 ;;
    --pkg) PKG=${2:-}; PKG=${PKG%/}; shift 2 ;;
    --tests) TESTS=${2:-}; shift 2 ;;
    --max) MAX=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --threshold) THRESHOLD=${2:-}; shift 2 ;;
    --count-only) COUNT_ONLY=1; shift ;;
    -h|--help) sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "MUTATION FAIL: usage: unknown argument $1"; exit 1 ;;
  esac
done
[ -n "$WT" ] && [ -n "$BASE" ] && [ -n "$PKG" ] || { echo "MUTATION FAIL: usage: --worktree, --base and --pkg are required"; exit 1; }
for n in "$MAX" "$TIMEOUT" "$THRESHOLD"; do case "$n" in ''|*[!0-9]*) echo "MUTATION FAIL: usage: --max/--timeout/--threshold must be integers"; exit 1 ;; esac; done
[ "$MAX" -gt 20 ] && { echo "MUTATION NOTE: --max $MAX capped at 20"; MAX=20; }
cd "$WT" 2>/dev/null || { echo "MUTATION FAIL: no such worktree $WT"; exit 1; }
WT=$(git rev-parse --show-toplevel) || { echo "MUTATION FAIL: $WT is not a git worktree"; exit 1; }
cd "$WT" || exit 1
if [ -f "$PKG/Cargo.toml" ]; then
  LANG_=rs; SRC="$PKG/src"
  CRATE=$(awk '/^\[package\]/{p=1;next} /^\[/{p=0} p && /^name[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,""); print; exit}' "$PKG/Cargo.toml")
  [ -n "$CRATE" ] || { echo "MUTATION FAIL: cannot read the [package] name of $PKG/Cargo.toml"; exit 1; }
elif [ -f "$PKG/pubspec.yaml" ]; then
  LANG_=dart; SRC="$PKG/lib"
else
  echo "MUTATION FAIL: $PKG is neither a crate (Cargo.toml) nor a Dart package (pubspec.yaml) in $WT"; exit 1
fi
BASE_SHA=$(git rev-parse --verify -q "$BASE^{commit}") || { echo "MUTATION FAIL: unknown base $BASE"; exit 1; }
FORK=$(git merge-base "$BASE_SHA" HEAD) || { echo "MUTATION FAIL: no merge-base of $BASE and HEAD"; exit 1; }

SCRATCH=${ORCH_SCRATCH:-$(mktemp -d)}
WORK=$(mktemp -d "$SCRATCH/mutation.XXXXXX")

# ---- candidate files ----------------------------------------------------------------------
is_generated() {
  case "$1" in
    *.g.dart|*.freezed.dart|*.mocks.dart|*.gr.dart|*.config.dart) return 0 ;;
  esac
  head -5 "$1" 2>/dev/null | grep -qiE 'GENERATED CODE|AUTOMATICALLY GENERATED|DO NOT (EDIT|MODIFY)|@generated' && return 0
  return 1
}
if [ $LANG_ = rs ]; then EXT='\.rs$'; else EXT='\.dart$'; fi
FILES=$(git diff --name-only --diff-filter=AM "$FORK" -- "$SRC" | grep -E "$EXT" || true)
: > "$WORK/cands.tsv"
for f in $FILES; do
  [ -f "$f" ] || continue
  is_generated "$f" && continue
  lines=$(git diff -U0 "$FORK" -- "$f" | perl -ne 'if (/^@@ -\S+ \+(\d+)(?:,(\d+))? @@/) { my ($s,$c)=($1, defined $2 ? $2 : 1); print join(",", $s .. $s+$c-1), "," if $c > 0 }')
  [ -n "$lines" ] || continue
  perl -e '
    my ($file, $want, $lang) = @ARGV; my %want = map { $_ => 1 } grep { length } split /,/, $want;
    open my $fh, "<", $file or die; local $/; my $src = <$fh>; close $fh;
    # Whole-file mask: every char inside a comment or string/char literal becomes "_" (newlines kept).
    my ($o, $i, $n) = ("", 0, length $src);
    my $put = sub { my $s = shift; $s =~ s/[^\n]/_/g; $o .= $s };
    while ($i < $n) {
      my $rest = substr($src, $i, 400);
      if ($rest =~ m{^//[^\n]*}) { $put->($&); $i += length $&; next }
      if ($rest =~ m{^/\*}) { my ($d, $j) = (0, $i);
        while ($j < $n) { my $t = substr($src, $j, 2);
          if ($t eq "/*") { $d++; $j += 2; next } if ($t eq "*/") { $d--; $j += 2; last if !$d; next } $j++ }
        $put->(substr($src, $i, $j - $i)); $i = $j; next }
      my $prev = $i ? substr($src, $i - 1, 1) : " ";
      if ($lang eq "rs") {
        if ($prev !~ /[\w]/ && $rest =~ /^b?r(#*)"/) { my $h = $1; my $open = length $&;
          my $end = index($src, "\"$h", $i + $open); $end = $n - length("\"$h") if $end < 0;
          my $len = $end + length("\"$h") - $i; $o .= substr($src, $i, $open); $put->(substr($src, $i + $open, $len - $open - length("\"$h"))); $o .= "\"$h"; $i += $len; next }
        if ($rest =~ /^b?"/ && ($prev !~ /\w/ || $& eq "b\"")) { my $open = length $&; my $j = $i + $open;
          while ($j < $n) { my $c = substr($src, $j, 1); if ($c eq "\\") { $j += 2; next } last if $c eq "\""; $j++ }
          $o .= substr($src, $i, $open); $put->(substr($src, $i + $open, $j - $i - $open)); $o .= "\""; $i = $j + 1; next }
        if ($rest =~ /^b?\x27(?:\\(?:x[0-9a-fA-F]{2}|u\{[0-9a-fA-F]+\}|.)|[^\\\x27\n])\x27/) { $o .= "\x27"; $put->(substr($&, 1, length($&) - 2)); $o .= "\x27"; $i += length $&; next }
      } else {
        if ($rest =~ /^(r?)(\x27\x27\x27|"""|\x27|")/) { my ($raw, $q) = ($1, $2); my $open = length $&; my $j = $i + $open;
          while ($j < $n) { if (!$raw && substr($src, $j, 1) eq "\\") { $j += 2; next } last if substr($src, $j, length $q) eq $q; last if length($q) == 1 && substr($src, $j, 1) eq "\n"; $j++ }
          $o .= substr($src, $i, $open); $put->(substr($src, $i + $open, $j - $i - $open)); $i = $j;
          if (substr($src, $i, length $q) eq $q) { $o .= $q; $i += length $q } next }
      }
      $o .= substr($src, $i, 1); $i++ }
    my @L = split /\n/, $src, -1; my @M = split /\n/, $o, -1;
    my @ops = (
      [ qr/(?<![=!<>])==(?!=)/, "!=" ], [ qr/!=/, "==" ],
      [ qr/ < (?!=)/, " <= " ], [ qr/ > (?!=)/, " >= " ], [ qr/ <= /, " < " ], [ qr/ >= /, " > " ],
      ($lang eq "rs"
        ? ([ qr/(?<=[\w)\]?]) && /, " || " ], [ qr/(?<=[\w)\]?]) \|\| /, " && " ])
        : ([ qr/&&/, "||" ], [ qr/\|\|/, "&&" ])),
      [ qr/(?<![\w.\$])true(?![\w:])/, "false" ], [ qr/(?<![\w.\$])false(?![\w:])/, "true" ],
      [ qr/(?<=[\w)\]] )\+ 1(?![\w.])/, "- 1" ], [ qr/(?<=[\w)\]] )- 1(?![\w.])/, "+ 1" ],
    );
    for my $k (0 .. $#L) { my $ln = $k + 1; my ($l, $m) = ($L[$k], $M[$k] // "");
      last if $lang eq "rs" && $l =~ /^\s*#\[cfg\(test\)\]/;
      next unless $want{$ln};
      if ($lang eq "rs") { next if $l =~ /^\s*(?:pub(?:\([^)]*\))?\s+)?(?:use|mod|extern)\b/ || $l =~ /^\s*#!?\[/ }
      else { next if $l =~ m{^\s*(import\b|export\b|part\b|library\b|\@)}; next if $l =~ /\boperator\s*\S/ }
      for my $op (@ops) { my ($re, $to) = @$op;
        while ($m =~ /$re/g) { my ($c, $len) = ($-[0], $+[0] - $-[0]);
          my $tier = 1;
          if ($lang eq "dart") { my $ctx = substr($m, $c, $len + 6) . "|" . substr($m, ($c > 6 ? $c - 6 : 0), ($c > 6 ? 6 : $c));
            $tier = 2 if $ctx =~ /null/ || $l =~ /^\s*(?:required\s+)?(?:this\.)?\w+\s*=\s*(?:true|false)\s*,?\s*(?:[)}\]]\s*)?$/ }
          print join("\t", $file, $ln, $c, substr($l, $c, $len), $to, $tier), "\n" } } }
  ' "$f" "$lines" "$LANG_" >> "$WORK/cands.tsv"
done
NSITES=$(wc -l < "$WORK/cands.tsv" | tr -d ' ')
if [ "$COUNT_ONLY" = 1 ]; then echo "MUTATION SITES: $NSITES"; exit 0; fi
if [ "$NSITES" = 0 ]; then echo "MUTATION SKIP: no mutable sites on added lines of $SRC"; exit 0; fi

# Deterministic order: round-robin allocation of MAX picks across files, evenly spaced within
# each file; then every remaining site (round-robin) as backups for INVALID/TIMEOUT mutants.
perl -e '
  my $max = shift; my (%by, @files, @tier2);
  while (<STDIN>) { chomp; my @r = split /\t/;
    if ($r[5] == 2) { push @tier2, [@r]; next }
    push @files, $r[0] unless $by{$r[0]}; push @{$by{$r[0]}}, [@r] }
  @files = sort @files;
  for my $f (@files) { @{$by{$f}} = sort { $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @{$by{$f}} }
  my %alloc; my $total = 0; my $more = 1;
  while ($total < $max && $more) { $more = 0;
    for my $f (@files) { last if $total >= $max;
      if (($alloc{$f} // 0) < @{$by{$f}}) { $alloc{$f}++; $total++; $more = 1 } } }
  my (%picked, @order);
  my $maxn = 0; for (values %alloc) { $maxn = $_ if $_ > $maxn }
  for my $j (0 .. $maxn - 1) { for my $f (@files) { my $n = $alloc{$f} // 0; next if $j >= $n;
      my $k = @{$by{$f}}; my $i = int(($j + 0.5) * $k / $n); push @order, $by{$f}[$i]; $picked{"$f\t$i"} = 1 } }
  my $left = 1; my %pos;
  while ($left) { $left = 0; for my $f (@files) { my $i = $pos{$f} // 0;
      while ($i < @{$by{$f}} && $picked{"$f\t$i"}) { $i++ }
      if ($i < @{$by{$f}}) { push @order, $by{$f}[$i]; $picked{"$f\t$i"} = 1; $left = 1 } $pos{$f} = $i + 1 } }
  push @order, sort { $a->[0] cmp $b->[0] || $a->[1] <=> $b->[1] || $a->[2] <=> $b->[2] } @tier2;
  print join("\t", @{$_}[0 .. 4]), "\n" for @order;
' "$MAX" < "$WORK/cands.tsv" > "$WORK/order.tsv"

# ---- tests --------------------------------------------------------------------------------
REL_TESTS=""
if [ $LANG_ = dart ]; then
  for t in $TESTS; do
    r=${t#"$PKG"/}
    [ -f "$PKG/$r" ] || { echo "MUTATION FAIL: test file not found: $PKG/$r"; exit 1; }
    REL_TESTS="$REL_TESTS $r"
  done
fi

with_timeout() { # with_timeout <secs> <cmd...>; exit 124 on timeout; kills the whole process group
  perl -e '
    my $t = shift; my $pid = fork; die "fork: $!" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127 }
    my $kill = sub { kill "TERM", -$pid; for (1 .. 10) { last unless kill 0, -$pid; sleep 1 } kill "KILL", -$pid };
    $SIG{INT} = $SIG{TERM} = sub { $kill->(); exit 130 };
    $SIG{ALRM} = sub { $kill->(); waitpid($pid, 0); exit 124 };
    alarm $t; waitpid($pid, 0); alarm 0; my $s = $?;
    exit($s & 127 ? 128 + ($s & 127) : $s >> 8);' "$@"
}
run_tests() { # run_tests <secs> <log>
  if [ $LANG_ = rs ]; then
    CARGO_TERM_COLOR=never with_timeout "$1" cargo test -p "$CRATE" > "$2" 2>&1 < /dev/null
  else
    # shellcheck disable=SC2086
    (cd "$PKG" && with_timeout "$1" flutter test $REL_TESTS) > "$2" 2>&1 < /dev/null
  fi
}
saw_failure() {
  if [ $LANG_ = rs ]; then grep -qE 'test result: FAILED|panicked at|^failures:' "$1"
  else grep -qE '\[E\]|Some tests failed|Failed to load|: Error: | -[1-9][0-9]*:' "$1"; fi
}
compile_error() { # prints "<file>:<line>" of the first compile error, exit 0 if there is one
  if [ $LANG_ = rs ]; then
    # cargo prints "error: could not compile" on every compile failure ("error: test failed" is not one)
    grep -qE '^error\[E[0-9]+\]: |^error: could not compile' "$1" || return 1
    grep -A4 -E '^error(\[E[0-9]+\])?: ' "$1" | grep -oE -- '--> [^ ]+:[0-9]+' | head -1 | sed 's/^--> //'
    return 0
  else
    grep -qE '\.dart:[0-9]+:[0-9]+: Error: ' "$1" || return 1
    grep -oE "[A-Za-z0-9_]+\.dart:[0-9]+:[0-9]+: Error" "$1" | head -1 | sed 's/: Error//'
    return 0
  fi
}

# ---- restore safety -------------------------------------------------------------------------
CUR=""; CUR_BAK=""
# Restore WITHOUT -p and touch: cargo fingerprints by mtime, so putting back the original (older)
# mtime would leave the mutant build cached and every later run would test the mutant.
restore_current() { [ -n "$CUR" ] && cp "$CUR_BAK" "$CUR" && touch "$CUR"; CUR=""; }
trap 'restore_current' EXIT
trap 'restore_current; exit 130' INT TERM
# flutter test runs an implicit pub get, and Flutter 3.47+ pub get rewrites app/analysis_options.yaml
# (adds analyzer.exclude) when the repo has not committed that upgrade: do it up front so the
# before/after tree comparison below is not tripped by it.
[ $LANG_ = dart ] && { (cd "$PKG" && flutter pub get > "$WORK/pubget.log" 2>&1) || echo "MUTATION WARN: flutter pub get failed in $PKG"; }
TREE_BEFORE=$(git status --porcelain=v1 --untracked-files=no | shasum; git diff "$FORK" | shasum)

# ---- baseline -------------------------------------------------------------------------------
if [ $LANG_ = rs ]; then RUNDESC="cargo test -p $CRATE"; else RUNDESC="flutter test${REL_TESTS:- (full app suite)}"; fi
echo "MUTATION START $PKG: $NSITES candidate sites, max $MAX, runs: $RUNDESC"
t0=$SECONDS
run_tests "$TIMEOUT" "$WORK/baseline.log"; rc=$?
BASE_SECS=$((SECONDS - t0))
if [ $rc != 0 ]; then
  echo "MUTATION FAIL: baseline tests fail on the unmutated tree (exit $rc, ${BASE_SECS}s); see $WORK/baseline.log"
  tail -5 "$WORK/baseline.log" | sed 's/^/  /'
  exit 1
fi
PER=$((3 * BASE_SECS + 60)); [ $PER -lt 180 ] && PER=180; [ $PER -gt "$TIMEOUT" ] && PER=$TIMEOUT
echo "MUTATION BASELINE $PKG: green in ${BASE_SECS}s; per-mutant timeout ${PER}s"

# ---- mutants --------------------------------------------------------------------------------
killed=0; survived=0; evaluated=0; attempts=0; max_attempts=$((MAX * 4)); idx=0
while IFS="$(printf '\t')" read -r file line col before after; do
  [ $evaluated -ge "$MAX" ] && break
  [ $attempts -ge $max_attempts ] && break
  attempts=$((attempts + 1)); idx=$((idx + 1))
  bak="$WORK/orig.$idx"
  cp -p "$file" "$bak"
  pre_sum=$(shasum < "$file"); pre_diff=$(git diff "$FORK" -- "$file" | shasum)
  CUR=$file; CUR_BAK=$bak
  if ! perl -e '
      my ($f, $ln, $col, $from, $to) = @ARGV; open my $in, "<", $f or die; my @l = <$in>; close $in;
      my $s = $l[$ln - 1]; exit 3 unless defined $s && substr($s, $col, length $from) eq $from;
      substr($s, $col, length $from) = $to; $l[$ln - 1] = $s;
      open my $out, ">", $f or die; print $out @l; close $out;' "$file" "$line" "$col" "$before" "$after"; then
    restore_current; echo "MUTATION WARN: could not apply $file:$line ($before), skipped"; continue
  fi
  label="$file:$line  $(echo "$before" | sed 's/^ *//; s/ *$//') -> $(echo "$after" | sed 's/^ *//; s/ *$//')"
  log="$WORK/mutant.$idx.log"
  t1=$SECONDS
  run_tests "$PER" "$log"; rc=$?
  secs=$((SECONDS - t1))
  restore_current
  if [ "$(shasum < "$file")" != "$pre_sum" ] || [ "$(git diff "$FORK" -- "$file" | shasum)" != "$pre_diff" ]; then
    cp "$bak" "$file"; touch "$file"
    echo "MUTATION FAIL: could not restore $file after mutating line $line; restored from $bak — check the worktree"
    exit 1
  fi
  if [ $rc = 0 ]; then
    survived=$((survived + 1)); evaluated=$((evaluated + 1))
    echo "MUTANT SURVIVED $label   [$(sed -n "${line}p" "$file" | sed 's/^ *//' | cut -c1-120)] (${secs}s)"
  elif where=$(compile_error "$log"); then
    # the baseline compiled, so ANY compile error comes from the mutant; it proves nothing about the tests
    echo "MUTANT INVALID $label (compile error at ${where:-?}; not counted, trying another site)"
  elif [ $rc = 124 ] && ! saw_failure "$log"; then
    echo "MUTANT TIMEOUT $label (no failure before ${PER}s; not counted, trying another site)"
  else
    killed=$((killed + 1)); evaluated=$((evaluated + 1))
    echo "MUTANT KILLED $label (${secs}s)"
  fi
done < "$WORK/order.tsv"

TREE_AFTER=$(git status --porcelain=v1 --untracked-files=no | shasum; git diff "$FORK" | shasum)
if [ "$TREE_BEFORE" != "$TREE_AFTER" ]; then echo "MUTATION FAIL: worktree differs from before the run — inspect $WT"; exit 1; fi

allowed=$((evaluated * THRESHOLD / 100)); [ $allowed -lt 1 ] && [ $evaluated -ge 2 ] && allowed=1
if [ $evaluated = 0 ]; then
  echo "MUTATION SKIP: no valid mutants among $attempts attempts in $PKG"; exit 0
fi
if [ $survived -gt $allowed ]; then
  echo "MUTATION FAIL: $killed killed, $survived survived (allowed <= $allowed of $evaluated) in $PKG"; exit 1
fi
echo "MUTATION OK: $killed killed, $survived survived (allowed <= $allowed of $evaluated) in $PKG"
exit 0
