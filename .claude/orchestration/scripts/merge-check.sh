#!/bin/bash
# merge-check.sh — open_memex merged-tree gate.
#
#   merge-check.sh <pr> [--base <ref>] [--complexity auto|routine|tricky] [--skip-suites] [--ac-map-only]
#                       [--pr-body-file <f>] [--pr-ref <commit>]
#
# Stages PR <pr> onto <base> (default origin/main) in the gate worktree $MAIN/worktrees/_gate
# (merge --no-commit: nothing is committed, signed or pushed) and verifies the MERGED tree.
# Checks run in cost order and FAIL FAST between stages (a failed stage skips the later ones):
#   MERGE        no conflicts
#   AC MAP       PR body "## Acceptance criteria → tests" table covers the WI's ACs (WI PRs only:
#                a 'Closes #N' / 'Part of #N' line, or a feat/ branch). Test cells are repo-relative:
#                app/test/x_test.dart :: name | crates/<c>/tests/x.rs :: name |
#                crates/<c>/src/x.rs :: tests::name  (file must exist, name must appear in it)
#   --- static stage (all run, then fail fast) ---
#   SCHEMA       crates/memex-core/src/schema.rs: APP_SCHEMA_VERSION is base's +0 or +1; a +1 bump
#                must not collide with a V<n> constant already on base; one V<n> per version;
#                no DROP TABLE on added lines
#   FMT          cargo fmt --check, RATCHET: no changed .rs file gets more rustfmt diff hunks than
#                it has on base, new files must be clean (main is NOT fmt-clean today; once it is,
#                this is equivalent to a strict cargo fmt --check)
#   ANALYZE      flutter analyze in app/ (strict: errors, warnings AND infos fail; main is clean)
#   CLIPPY       cargo clippy --workspace --all-targets -- -D warnings (main is clippy-clean;
#                set CLIPPY_DENY=0 to report counts without failing)
#   --- suites ---
#   CARGO SUITE    cargo test --workspace (full)
#   FLUTTER SUITE  flutter test in app/ (full)
#   (Rust checks run when crates/, Cargo.toml/lock or rust config changed; Flutter checks when app/
#    changed. There is NO CI in this repo: this gate is the only place the suites run.)
#   --- proof stage ---
#   MUTATION     tricky WIs only: mutation-spot.sh on added lines of crates/*/src (.rs, above
#                #[cfg(test)]) and app/lib (.dart); survivors listed under "## Mutation exemptions"
#                ("- <file>:<line> — <reason>") are not counted; <= 25% may survive
#   RED ON MAIN  the PR's changed tests fail on base's code (compile failure counts as red):
#                app/test/**_test.dart, crates/*/tests/*.rs targets, and changed #[cfg(test)]
#                modules in crates/*/src/*.rs (base's code above #[cfg(test)] + the PR's test
#                module). A fix for an EXISTING failing test names it under "## Red on main".
# The gate worktree is always reset afterwards (trap). One gate runs at a time (lock).
#
#   --base          base ref to merge onto (default origin/main, fetched first)
#   --complexity    auto (default): WI from the PR body ("Closes #N" / "Part of #N"), then its
#                   complexity:tricky / complexity:routine label, then a "Complexity: tricky"
#                   body line; with no signal it defaults to tricky
#   --skip-suites   skip the suites (fast iteration only; merge-pr.sh refuses it)
#   --ac-map-only   implementer PR-body lint: run AC MAP, then exit (0 = AC MAP OK/SKIP); merge-pr.sh refuses it
#   --pr-body-file  use this file as the PR body (testing)
#   --pr-ref        use this commit as the PR head instead of fetching pull/<pr>/head (testing)
#
# Env: ORCH_SCRATCH (log dir root, default mktemp -d), ORCH_REPO (owner/name),
#      FMT_MODE (ratchet | strict | off), CLIPPY_DENY (1), SUITE_TIMEOUT (secs per suite, 1800), RED_TIMEOUT (secs per run, 900),
#      MUTATION_OFF (1 skips the MUTATION stage), MUTATION_MAX (16, cap 20), MUTATION_TIMEOUT (900), MUTATION_THRESHOLD (25).
# Output: one CAPS line per check, "TIME <section>: <n>s" per section, then
#         "GATE INFO pr=.. head=.. base=.. wi=.. link=.. complexity=.." and a final
#         "GATE PASS|FAIL" line.
# Exit: 0 PASS, 1 FAIL. (Never 2: no CI exists to wait for.)
set -uo pipefail

PR=""; BASE_REF=origin/main; COMPLEXITY=auto; SKIP_SUITES=0; AC_MAP_ONLY=0; BODY_FILE=""; PR_REF=""
die_usage() { echo "GATE FAIL: usage: $*"; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF=${2:-}; [ -n "$BASE_REF" ] || die_usage "--base needs a ref"; shift 2 ;;
    --complexity) COMPLEXITY=${2:-}; shift 2 ;;
    --skip-suites) SKIP_SUITES=1; shift ;;
    --ac-map-only) AC_MAP_ONLY=1; shift ;;
    --pr-body-file) BODY_FILE=${2:-}; [ -f "$BODY_FILE" ] || die_usage "--pr-body-file $BODY_FILE not found"; shift 2 ;;
    --pr-ref) PR_REF=${2:-}; [ -n "$PR_REF" ] || die_usage "--pr-ref needs a commit"; shift 2 ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die_usage "unknown flag $1" ;;
    *) [ -z "$PR" ] || die_usage "unexpected argument $1"; PR=$1; shift ;;
  esac
done
case "$PR" in ''|*[!0-9]*) die_usage "merge-check.sh <pr-number> [flags]" ;; esac
case "$COMPLEXITY" in auto|routine|tricky) ;; *) die_usage "--complexity auto|routine|tricky" ;; esac
case "$BODY_FILE" in ''|/*) ;; *) BODY_FILE="$PWD/$BODY_FILE" ;; esac

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
resolve_main() {
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$d/.." && pwd)
}
MAIN=$(resolve_main "$PWD" || resolve_main "$SCRIPT_DIR") || { echo "GATE FAIL: not inside a git repo"; exit 1; }
G=$MAIN/worktrees/_gate
SCRATCH=${ORCH_SCRATCH:-$(mktemp -d)}
LOGS="$SCRATCH/gate-$PR-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS"
RED_TIMEOUT=${RED_TIMEOUT:-900}
SUITE_TIMEOUT=${SUITE_TIMEOUT:-1800}
CLIPPY_DENY=${CLIPPY_DENY:-1}
FMT_MODE=${FMT_MODE:-ratchet}
SCHEMA_RS=crates/memex-core/src/schema.rs
export CARGO_TERM_COLOR=never
T_ALL=$SECONDS
echo "GATE START pr=#$PR logs=$LOGS"

# ---- helpers ------------------------------------------------------------------------------
FAILED=""
fail() { FAILED="$FAILED $1"; }
T0=0
section() { T0=$SECONDS; CUR_SECTION=$1; }
section_end() { echo "TIME $CUR_SECTION: $((SECONDS - T0))s"; }
with_timeout() { # with_timeout <secs> <cmd...>; exit 124 on timeout, 125 past the memory ceiling (run-guarded.sh)
  "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-guarded.sh" "$@"
}
# Pure test files: Dart tests under app/test or app/integration_test, Rust integration tests.
is_test_path() { echo "$1" | grep -qE '^app/(test|integration_test)/|_test\.dart$|^crates/[^/]+/tests/'; }
is_rs_src() { echo "$1" | grep -qE '^crates/[^/]+/src/.*\.rs$'; }
is_dart_code() { echo "$1" | grep -qE '^app/lib/.*\.dart$'; }
is_rust_affecting() { echo "$1" | grep -qE '^(crates/|Cargo\.(toml|lock)$|rust-toolchain(\.toml)?$|\.cargo/|(\.)?(clippy|rustfmt)\.toml$)'; }
# rs_part <rev|WORK> <path> <code|test>: the part of a .rs file above / from its first #[cfg(test)]
# line (unit-test modules live at the bottom of the file by convention). Empty if absent.
rs_part() {
  local content
  if [ "$1" = WORK ]; then content=$(cat "$2" 2>/dev/null) || return 0
  else content=$(git show "$1:$2" 2>/dev/null) || return 0; fi
  printf '%s\n' "$content" | perl -ne 'BEGIN { $w = shift } $t = 1 if /^\s*#\[cfg\(test\)\]/; print if ($w eq "test") == !!$t' "$3"
}
crate_name() { # crate_name crates/<dir> -> [package] name
  awk '/^\[package\]/{p=1;next} /^\[/{p=0} p && /^name[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,""); print; exit}' "$1/Cargo.toml"
}
reset_gate() {
  [ -d "$G" ] || return 0
  ( cd "$G" || exit 0
    # An interrupted gate can leave index.lock behind; clear it only when no git process runs in $G.
    lk=$(git rev-parse --git-path index.lock 2>/dev/null)
    if [ -n "$lk" ] && [ -e "$lk" ] && ! pgrep -f "git .*$G" >/dev/null 2>&1; then
      echo "GATE NOTE: removed a stale $lk"; rm -f "$lk"
    fi
    git merge --abort >/dev/null 2>&1
    # A crash mid-gate can leave a mutant applied here (run 20261106-229-230: tags.rs:199, a mutant that panics the
    # Mac). Say so before the reset clears it; nothing but this script may build or test in $G.
    dirty=$(git status --porcelain=v1 --untracked-files=no 2>/dev/null | head -5 | tr '\n' ' ')
    [ -n "$dirty" ] && echo "GATE WARN: $G had uncommitted tracked changes (crashed gate or leftover mutant); reset: $dirty"
    git reset -q --hard >/dev/null 2>&1
    git clean -qfd >/dev/null 2>&1   # keeps ignored target/ and app/.dart_tool/ warm between gates
    # Each mutant rebuild adds files to target/debug/deps. At 1.2M files every rustc call spent ~65 s listing it and
    # suites timed out (run 20261106-229-230). Past DEPS_PRUNE_AT entries, move target/ aside and delete it niced.
    n=$( [ -d target/debug/deps ] && find target/debug/deps -maxdepth 1 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    echo "GATE NOTE: target/debug/deps has $n entries"
    if [ "${n:-0}" -gt "${DEPS_PRUNE_AT:-300000}" ]; then
      old="$(dirname "$G")/.gate-target-prune.$$"; mv target "$old" && { nohup nice -n 19 rm -rf "$old" >/dev/null 2>&1 & }
      echo "GATE NOTE: pruned target/ ($n deps entries over ${DEPS_PRUNE_AT:-300000}); this gate builds cold"
    fi
    [ -n "${BASE_SHA:-}" ] && git checkout -q --detach "$BASE_SHA" >/dev/null 2>&1
    true )
}

# ---- lock (one gate at a time: shared worktree) ----------------------------------------------
LOCK=$MAIN/worktrees/.gate-lock
HAVE_LOCK=0
PRIVATE_G=0
mkdir -p "$MAIN/worktrees"
waited=0
# --ac-map-only is a seconds-long PR-body lint: it uses its own throwaway worktree and never
# queues behind (or blocks) a full gate on the shared one.
if [ "$AC_MAP_ONLY" = 1 ]; then
  G=$(mktemp -d "${TMPDIR:-/tmp}/acmap.XXXXXX")/gate; PRIVATE_G=1
fi
until [ "$PRIVATE_G" = 1 ] || mkdir "$LOCK" 2>/dev/null; do
  p=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$LOCK"; continue; fi
  if [ -z "$p" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rm -rf "$LOCK"; continue; fi
  [ $((waited % 120)) -eq 0 ] && echo "GATE WAIT: another gate holds $LOCK (pid ${p:-?}); waiting ${waited}s"
  sleep 10; waited=$((waited + 10))
done
[ "$PRIVATE_G" = 1 ] || { echo $$ > "$LOCK/pid"; HAVE_LOCK=1; }
cleanup() {
  if [ "$PRIVATE_G" = 1 ]; then
    git -C "$MAIN" worktree remove --force "$G" >/dev/null 2>&1; rm -rf "$(dirname "$G")"
  else
    reset_gate
  fi
  [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCK"
}
trap cleanup EXIT
trap 'echo "GATE FAIL: interrupted"; exit 1' INT TERM

verdict_fail() { # fast-fail exit after a failed stage: verdict_fail <stage> <what was skipped>
  echo "$1 FAST-FAIL: skipped $2; fix and re-gate"
  echo "TIME TOTAL: $((SECONDS - T_ALL))s"
  echo "GATE INFO pr=$PR head=${PR_HEAD:-none} base=${BASE_SHA:-none} wi=${WI:-none} link=${LINK:-none} complexity=$COMPLEXITY suites=$([ $SKIP_SUITES = 1 ] && echo skipped || echo run) logs=$LOGS"
  echo "GATE FAIL: PR #$PR onto $BASE_REF@${BASE_SHORT:-?} — failed:$FAILED"
  exit 1
}

# ---- MERGE ---------------------------------------------------------------------------------
section MERGE
git -C "$MAIN" fetch -q origin || echo "MERGE WARN: git fetch origin failed; using local refs"
if [ -n "$PR_REF" ]; then
  PR_HEAD=$(git -C "$MAIN" rev-parse --verify -q "$PR_REF^{commit}") || { echo "MERGE FAIL: --pr-ref $PR_REF is not a commit"; exit 1; }
else
  git -C "$MAIN" fetch -q origin "+pull/$PR/head:refs/remotes/review/$PR" || { echo "MERGE FAIL: cannot fetch pull/$PR/head"; exit 1; }
  PR_HEAD=$(git -C "$MAIN" rev-parse "refs/remotes/review/$PR")
fi
BASE_SHA=$(git -C "$MAIN" rev-parse --verify -q "$BASE_REF^{commit}") || { echo "MERGE FAIL: unknown base $BASE_REF"; exit 1; }
if [ ! -d "$G" ]; then
  git -C "$MAIN" worktree add -q --detach "$G" "$BASE_SHA" || { echo "MERGE FAIL: cannot create gate worktree $G"; exit 1; }
  echo "MERGE NOTE: created $G (first gate: cold cargo build)"
fi
git -C "$G" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "MERGE FAIL: $G exists but is not a git worktree"; exit 1; }
cd "$G" || exit 1
reset_gate
git checkout -q --detach "$BASE_SHA" || { echo "MERGE FAIL: cannot check out $BASE_SHA in $G"; exit 1; }
BASE_SHORT=$(git rev-parse --short "$BASE_SHA")
if git merge-base --is-ancestor "$PR_HEAD" "$BASE_SHA"; then
  echo "MERGE FAIL: PR #$PR head $(git rev-parse --short "$PR_HEAD") is already contained in base $BASE_REF@$BASE_SHORT (already merged? pass --base <merge-commit>^1)"
  exit 1
fi
# rustfmt baseline on the base tree (cheap, ~0.1s): the FMT ratchet compares against it
cargo fmt --all --check > "$LOGS/fmt-base.log" 2>&1
if ! git merge -q --no-commit --no-ff "$PR_HEAD" > "$LOGS/merge.log" 2>&1; then
  echo "MERGE FAIL: conflict merging PR #$PR onto $BASE_REF@$BASE_SHORT"
  git diff --name-only --diff-filter=U | sed 's/^/  conflict: /'
  exit 1
fi
CHANGED_NS=$(git diff --cached --name-status --no-renames "$BASE_SHA")
CHANGED=$(echo "$CHANGED_NS" | cut -f2)
echo "MERGE OK: PR #$PR head $(git rev-parse --short "$PR_HEAD") onto $BASE_REF@$BASE_SHORT ($(echo "$CHANGED" | grep -c .) files changed)"
section_end

RUST=0; APP=0
for f in $CHANGED; do is_rust_affecting "$f" && RUST=1; case "$f" in app/*) APP=1 ;; esac; done
echo "SCOPE: rust=$([ $RUST = 1 ] && echo yes || echo no) app=$([ $APP = 1 ] && echo yes || echo no)"

# ---- PR body, WI, complexity -----------------------------------------------------------------
REPO=${ORCH_REPO:-$(cd "$MAIN" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
if [ -n "$BODY_FILE" ]; then
  PR_BODY=$(cat "$BODY_FILE")
elif [ -n "$PR_REF" ]; then
  PR_BODY=""
else
  PR_BODY=$(gh pr view "$PR" -R "$REPO" --json body -q .body 2>/dev/null) \
    || { echo "GATE WARN: could not read PR #$PR body"; PR_BODY=""; }
fi
HEAD_REF=""
[ -n "$BODY_FILE" ] || HEAD_REF=$(gh pr view "$PR" -R "$REPO" --json headRefName -q .headRefName 2>/dev/null || true)
WI=""; LINK=""
m=$(printf '%s\n' "$PR_BODY" | perl -ne 'if (/^\s*(closes|part of)\s+#(\d+)/i) { print lc($1), " $2\n"; exit }')
if [ -n "$m" ]; then WI=${m##* }; case "$m" in closes*) LINK=closes ;; *) LINK=part-of ;; esac; fi
WI_JSON=""
if [ -n "$WI" ]; then
  WI_JSON=$(gh issue view "$WI" -R "$REPO" --json labels,body 2>/dev/null) || { echo "GATE WARN: could not read WI #$WI"; WI_JSON=""; }
fi
if [ "$COMPLEXITY" = auto ]; then
  if [ -z "$WI" ]; then
    COMPLEXITY=tricky; echo "COMPLEXITY: tricky (no 'Closes #N' / 'Part of #N' in the PR body; defaulting to tricky)"
  elif echo "$WI_JSON" | jq -e '.labels[]?.name | select(. == "complexity:tricky")' >/dev/null 2>&1; then
    COMPLEXITY=tricky; echo "COMPLEXITY: tricky (label on WI #$WI)"
  elif echo "$WI_JSON" | jq -e '.labels[]?.name | select(. == "complexity:routine")' >/dev/null 2>&1; then
    COMPLEXITY=routine; echo "COMPLEXITY: routine (label on WI #$WI)"
  elif echo "$WI_JSON" | jq -r '.body // ""' 2>/dev/null | grep -qiE '^Complexity:[[:space:]]*routine'; then
    COMPLEXITY=routine; echo "COMPLEXITY: routine (body line on WI #$WI)"
  elif echo "$WI_JSON" | jq -r '.body // ""' 2>/dev/null | grep -qiE '^Complexity:[[:space:]]*tricky'; then
    COMPLEXITY=tricky; echo "COMPLEXITY: tricky (body line on WI #$WI)"
  else
    COMPLEXITY=tricky; echo "COMPLEXITY: tricky (WI #$WI has no complexity label; defaulting to tricky)"
  fi
else
  echo "COMPLEXITY: $COMPLEXITY (--complexity)"
fi

# Code change = app/lib .dart, or the non-test part (above #[cfg(test)]) of a crates/*/src .rs file.
CODE_CHANGED=0
for f in $CHANGED; do
  if is_dart_code "$f"; then CODE_CHANGED=1; break; fi
  # run 20261110-356 (#367): release/leak/cutover scripts and workflows are code too (tested from app/test via Process.run)
  case "$f" in scripts/*|.github/workflows/*) CODE_CHANGED=1; break ;; esac
  if is_rs_src "$f" && [ "$(rs_part "$BASE_SHA" "$f" code)" != "$(rs_part WORK "$f" code)" ]; then CODE_CHANGED=1; break; fi
done

# ---- AC MAP ------------------------------------------------------------------------------------
section "AC MAP"
ac_map() {
  if [ $CODE_CHANGED = 0 ]; then echo "AC MAP SKIP: no code change (app/lib .dart, non-test crates/*/src .rs, scripts/, .github/workflows/)"; return 0; fi
  if [ -z "$WI" ]; then
    # Work Item PRs (feat/<ticket>-<wi>-…) must link their WI; other PRs (bug fixes, chores) have no ACs to map.
    case "$HEAD_REF" in feat/*) echo "AC MAP FAIL: branch $HEAD_REF looks like a Work Item PR but the body has no 'Closes #N' / 'Part of #N' line"; return 1 ;; esac
    echo "AC MAP SKIP: no linked Work Item (not a WI PR)"; return 0
  fi
  local rows
  rows=$(printf '%s\n' "$PR_BODY" | perl -e '
    my ($in, @t) = (0);
    while (<STDIN>) { s/\r?\n$//;
      if (/^#{2,4}\s*Acceptance criteria\s*(?:→|->)\s*tests\b/i) { $in = 1; next }
      if ($in && /^#{1,6}\s/) { last }
      push @t, $_ if $in && /^\s*\|/ }
    if (!$in) { print "ERR\tno section\n"; exit }
    if (!@t) { print "ERR\tempty section\n"; exit }
    my $split = sub { my $l = shift; $l =~ s/^\s*\|//; $l =~ s/\|\s*$//; map { s/^\s+|\s+$//gr } split /(?<!\\)\|/, $l, -1 };
    my @h = $split->(shift @t); my ($ac, $test) = (-1, -1);
    for my $i (0 .. $#h) { my $c = lc $h[$i]; $c =~ s/[`*_]//g;
      $ac = $i if $ac < 0 && $c =~ /^ac\b|acceptance/; $test = $i if $test < 0 && $c =~ /^tests?\b/ }
    if ($test < 0) { print "ERR\theader has no Test column (need: AC | Test)\n"; exit }
    $ac = 0 if $ac < 0;
    for my $r (@t) { next if $r =~ /^\s*\|?[\s:|-]+\|?\s*$/;
      my @c = $split->($r); my ($x, $y) = ($c[$ac] // "", $c[$test] // "");
      next if $x eq "" && $y eq "";
      $x =~ s/\t/ /g; $y =~ s/\t/ /g; print "ROW\t$x\t$y\n" }')
  case "$rows" in
    ERR*"no section"*) echo "AC MAP FAIL: the PR body has no '## Acceptance criteria → tests' section. The PR changes code, so it needs a table with columns 'AC | Test', one row per WI acceptance criterion; Test = 'app/test/x_test.dart :: name', 'crates/<c>/tests/x.rs :: name', 'crates/<c>/src/x.rs :: tests::name' or 'MANUAL: reason'."; return 1 ;;
    ERR*) echo "AC MAP FAIL: $(printf '%s' "$rows" | cut -f2)"; return 1 ;;
  esac
  local n=0 ntest=0 nman=0 ngate=0 bad=0 acs="" line a tcell path name fn reason
  # Process ACs (analyze/clippy/fmt clean, full suites green, mutation) are verified by this merge
  # check itself, so they need no test row.
  local PROCESS_AC_RE='analy[sz]e|clippy|rustfmt|cargo fmt|full[^|]*suite|suite-slot|mutation|mutant'
  local TEST_PATH_RE='_test\.dart|crates/[^/ ]+/(tests|src)/[^ ]*\.rs'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    a=$(printf '%s' "$line" | cut -f2); tcell=$(printf '%s' "$line" | cut -f3 | sed 's/`//g; s/^ *//; s/ *$//')
    n=$((n + 1))
    if printf '%s' "$tcell" | grep -qiE '^GATE[[:space:]]*:' || { printf '%s' "$a" | grep -qiE "$PROCESS_AC_RE" && ! printf '%s' "$tcell" | grep -qE "$TEST_PATH_RE"; }; then
      if printf '%s' "$a" | grep -qiE "$PROCESS_AC_RE"; then
        echo "AC GATE: $a — verified by this merge check (analyze, clippy, fmt, suites, mutation)"
        ngate=$((ngate + 1)); continue
      fi
      echo "AC MAP FAIL: row $n ($a): GATE is only for process ACs (analyze, clippy, fmt, full suites, mutation)"; bad=1; continue
    fi
    if printf '%s' "$tcell" | grep -qiE '^MANUAL[[:space:]]*:'; then
      reason=$(printf '%s' "$tcell" | sed -E 's/^[Mm][Aa][Nn][Uu][Aa][Ll][[:space:]]*:[[:space:]]*//')
      if [ -z "$reason" ]; then echo "AC MAP FAIL: row $n ($a) is MANUAL without a reason"; bad=1; continue; fi
      echo "AC MANUAL: $a — $reason"
      nman=$((nman + 1))
      continue
    fi
    if [ -z "$tcell" ]; then echo "AC MAP FAIL: row $n ($a) has an empty Test cell"; bad=1; continue; fi
    path=$(printf '%s' "$tcell" | sed 's/ *::.*$//; s/ *$//')
    name=""; case "$tcell" in *::*) name=$(printf '%s' "$tcell" | sed 's/^[^:]*:://; s/^ *//; s/ *$//') ;; esac
    case "$path" in
      app/*_test.dart|crates/*/tests/*.rs) ;;
      crates/*/src/*.rs) [ -n "$name" ] || { echo "AC MAP FAIL: row $n ($a): $path is a source file; name the unit test ('$path :: tests::<fn>')"; bad=1; continue; } ;;
      *) echo "AC MAP FAIL: row $n ($a): '$path' is not a repo-relative test path (app/test/…_test.dart, crates/<c>/tests/….rs, crates/<c>/src/….rs :: tests::<fn>; 'MANUAL: reason' for manual checks)"; bad=1; continue ;;
    esac
    if ! git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      echo "AC MAP FAIL: row $n ($a): $path does not exist in the merged tree (paths are repo-relative)"; bad=1; continue
    fi
    if [ -n "$name" ]; then
      case "$path" in
        *.rs)
          fn=${name##*::}; fn=$(printf '%s' "$fn" | sed 's/[()]//g; s/^ *//; s/ *$//')
          if ! grep -qE "fn[[:space:]]+${fn}[[:space:]]*[<(]" "$path"; then
            echo "AC MAP FAIL: row $n ($a): no 'fn $fn(' in $path"; bad=1; continue
          fi ;;
        *)
          if ! grep -qF -- "$name" "$path" && ! grep -qF -- "$(printf '%s' "$name" | sed "s/'/\\\\'/g")" "$path"; then
            echo "AC MAP FAIL: row $n ($a): test name '$name' does not appear literally in $path (use the test()/testWidgets() description itself, without group prefixes)"; bad=1; continue
          fi ;;
      esac
    fi
    ntest=$((ntest + 1))
  done <<EOF
$(printf '%s\n' "$rows" | grep '^ROW')
EOF
  [ $n = 0 ] && { echo "AC MAP FAIL: the Acceptance criteria → tests table has no rows"; return 1; }
  [ $((nman + ngate)) = $n ] && { echo "AC MAP FAIL: every row is MANUAL or GATE, but the PR changes code; map at least one AC to a test"; bad=1; }
  if [ -n "$WI" ] && [ -n "$WI_JSON" ]; then
    acs=$(echo "$WI_JSON" | jq -r '.body // ""' | perl -ne '
      if (/^##\s*Acceptance criteria\s*$/i) { $in = 1; next }
      if ($in && /^#{1,2}\s/) { $in = 0 }
      $n++ if $in && /^\s*[-*]\s+\[[ xX]\]/; END { print $n // 0 }')
  fi
  if [ "$LINK" = closes ]; then
    if [ -z "$WI_JSON" ]; then echo "AC MAP FAIL: cannot read WI #$WI to count its acceptance criteria"; return 1; fi
    if [ "${acs:-0}" = 0 ]; then echo "AC MAP WARN: WI #$WI has no '- [ ]' checkboxes under '## Acceptance criteria'"
    elif [ $n -lt "$acs" ]; then echo "AC MAP FAIL: $n rows < $acs acceptance criteria on WI #$WI (Closes needs one row per AC)"; bad=1; fi
  elif [ -z "$WI" ]; then
    echo "AC MAP WARN: no 'Closes #N' / 'Part of #N' in the PR body; row count not checked"
  fi
  [ $bad = 0 ] || return 1
  echo "AC MAP OK: $n/${acs:-?} ($ntest test rows, $nman manual, $ngate gate)"
}
if ! ac_map; then
  fail "AC-MAP"
  section_end
  # Fail fast: AC MAP needs only the PR body and the merged tree.
  verdict_fail "AC MAP" "schema, fmt, analyze, clippy, suites, mutation and red-on-main"
fi
section_end
if [ "$AC_MAP_ONLY" = 1 ]; then
  echo "AC MAP ONLY: PR-body lint passed; the other checks did not run. This is NOT a mergeable verdict"
  exit 0
fi

# ---- SCHEMA -------------------------------------------------------------------------------------
section SCHEMA
schema_check() {
  if ! echo "$CHANGED" | grep -qxF "$SCHEMA_RS"; then echo "SCHEMA SKIP: $SCHEMA_RS unchanged"; return 0; fi
  local bv mv bad=0 dup drops
  bv=$(git show "$BASE_SHA:$SCHEMA_RS" 2>/dev/null | sed -nE 's/^pub const APP_SCHEMA_VERSION: *i64 *= *([0-9]+);.*/\1/p')
  mv=$(sed -nE 's/^pub const APP_SCHEMA_VERSION: *i64 *= *([0-9]+);.*/\1/p' "$SCHEMA_RS")
  if [ -z "$bv" ] || [ -z "$mv" ]; then echo "SCHEMA FAIL: cannot read APP_SCHEMA_VERSION (base='$bv' merged='$mv')"; return 1; fi
  if [ "$mv" = "$bv" ]; then
    echo "SCHEMA OK: APP_SCHEMA_VERSION unchanged ($bv)"
  elif [ "$mv" = $((bv + 1)) ]; then
    if git show "$BASE_SHA:$SCHEMA_RS" | grep -qE "^[[:space:]]*(pub[[:space:]]+)?const V${mv}(_[A-Z0-9_]+)?:"; then
      echo "SCHEMA FAIL: APP_SCHEMA_VERSION $bv -> $mv, but base already defines a V${mv} constant (another PR took version $mv; rebase and bump to $((mv + 1)))"; bad=1
    else
      echo "SCHEMA OK: APP_SCHEMA_VERSION $bv -> $mv"
    fi
  else
    echo "SCHEMA FAIL: APP_SCHEMA_VERSION $bv -> $mv; a PR may only keep it or bump it by exactly 1"; bad=1
  fi
  dup=$(grep -oE "^[[:space:]]*(pub[[:space:]]+)?const V[0-9]+(_[A-Z0-9_]+)?:" "$SCHEMA_RS" | sed -E 's/.*const //; s/:$//' | sort | uniq -d)
  [ -n "$dup" ] && { echo "SCHEMA FAIL: duplicate schema constants in the merged tree: $(echo $dup)"; bad=1; }
  drops=$(git diff --cached -U0 "$BASE_SHA" -- "$SCHEMA_RS" | grep -E '^\+([^+]|$)' | grep -iE 'DROP[[:space:]]+TABLE' | head -3)
  [ -n "$drops" ] && { echo "SCHEMA FAIL: DROP TABLE on added lines of $SCHEMA_RS (user vaults hold data; use additive migrations):"; echo "$drops" | sed 's/^/  /'; bad=1; }
  return $bad
}
schema_check || fail SCHEMA
section_end

# ---- FMT (ratchet) ------------------------------------------------------------------------------
section FMT
fmt_check() {
  [ $RUST = 1 ] || { echo "FMT SKIP: no Rust changes"; return 0; }
  [ "$FMT_MODE" = off ] && { echo "FMT SKIP: FMT_MODE=off (not a merge verdict for formatting)"; return 0; }
  if grep -q "is not installed" "$LOGS/fmt-base.log"; then echo "FMT FAIL: rustfmt is not installed (rustup component add rustfmt)"; return 1; fi
  if cargo fmt --all --check > "$LOGS/fmt.log" 2>&1; then echo "FMT OK: cargo fmt --check clean"; return 0; fi
  if ! grep -q '^Diff in' "$LOGS/fmt.log"; then echo "FMT FAIL: cargo fmt errored (see $LOGS/fmt.log)"; head -5 "$LOGS/fmt.log" | sed 's/^/  /'; return 1; fi
  if [ "$FMT_MODE" = strict ]; then echo "FMT FAIL: cargo fmt --check reports $(grep -c '^Diff in' "$LOGS/fmt.log") hunks (FMT_MODE=strict)"; grep '^Diff in' "$LOGS/fmt.log" | sed "s#^Diff in $G/#  #" | head -10; return 1; fi
  local f b m bad=0
  for f in $(echo "$CHANGED" | grep -E '\.rs$'); do
    [ -f "$f" ] || continue
    m=$(grep -c "^Diff in $G/$f" "$LOGS/fmt.log")
    b=$(grep -c "^Diff in $G/$f" "$LOGS/fmt-base.log")
    if [ "$m" -gt "$b" ]; then echo "FMT FAIL: $f has $m rustfmt diff hunks (base: $b); run cargo fmt on it"; bad=1; fi
  done
  [ $bad = 0 ] && echo "FMT OK: no changed .rs file is less formatted than on base (ratchet; base has $(grep -c '^Diff in' "$LOGS/fmt-base.log") hunks)"
  return $bad
}
fmt_check || fail FMT
section_end

# ---- ANALYZE ------------------------------------------------------------------------------------
section ANALYZE
if [ $APP = 1 ]; then
  if (cd app && flutter pub get > "$LOGS/pubget.log" 2>&1); then
    # strict: main is "No issues found!", so infos and warnings fail too (flutter analyze's default)
    (cd app && flutter analyze > "$LOGS/analyze.log" 2>&1); rc=$?
    if [ $rc = 0 ]; then echo "ANALYZE OK: app"
    else echo "ANALYZE FAIL app: $(grep -E 'issues? found' "$LOGS/analyze.log" | tail -1)"; grep -E '^[[:space:]]*(error|warning|info) ' "$LOGS/analyze.log" | head -15 | sed 's/^/  /'; fail ANALYZE; fi
  else echo "PUB GET FAIL: app (see $LOGS/pubget.log)"; fail PUB-GET; fi
else
  echo "ANALYZE SKIP: no app/ changes"
fi
section_end

# ---- CLIPPY -------------------------------------------------------------------------------------
section CLIPPY
if [ $RUST = 1 ]; then
  if [ "$CLIPPY_DENY" = 1 ]; then
    cargo clippy --workspace --all-targets -- -D warnings > "$LOGS/clippy.log" 2>&1; rc=$?
    if [ $rc = 0 ]; then echo "CLIPPY OK: -D warnings clean"
    else echo "CLIPPY FAIL: $(grep -cE '^error' "$LOGS/clippy.log") errors with -D warnings"; grep -A4 -E '^error' "$LOGS/clippy.log" | grep -E '^error|-->' | head -16 | sed 's/^/  /'; fail CLIPPY; fi
  else
    cargo clippy --workspace --all-targets > "$LOGS/clippy.log" 2>&1; rc=$?
    nw=$(grep -cE '^warning' "$LOGS/clippy.log")
    if [ $rc = 0 ]; then echo "CLIPPY OK: $nw warnings (CLIPPY_DENY=0: reported, not failed)"
    else echo "CLIPPY FAIL: clippy errored (see $LOGS/clippy.log)"; grep -A4 -E '^error' "$LOGS/clippy.log" | grep -E '^error|-->' | head -10 | sed 's/^/  /'; fail CLIPPY; fi
  fi
else
  echo "CLIPPY SKIP: no Rust changes"
fi
section_end
[ -z "$FAILED" ] || verdict_fail "STATIC" "suites, mutation and red-on-main"

# ---- SUITES ------------------------------------------------------------------------------------
section SUITES
# The gate is serialized (lock) and on the merge critical path, so it BYPASSES suite-slot.sh;
# implementers queue there instead.
if [ $SKIP_SUITES = 1 ]; then
  echo "SUITES SKIPPED (--skip-suites): this is NOT a mergeable verdict"
else
  if [ $RUST = 1 ]; then
    with_timeout "$SUITE_TIMEOUT" cargo test --workspace --no-fail-fast > "$LOGS/suite-cargo.log" 2>&1 < /dev/null; rc=$?
    sum=$(perl -ne '$p += $1, $f += $2, $i += $3 if /^test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored/; END { printf "%d passed, %d failed, %d ignored", $p, $f, $i }' "$LOGS/suite-cargo.log")
    if [ $rc = 0 ]; then echo "CARGO SUITE: $sum"
    else
      [ $rc = 124 ] && echo "CARGO SUITE: timed out after ${SUITE_TIMEOUT}s"
      echo "CARGO SUITE FAIL: $sum (exit $rc; see $LOGS/suite-cargo.log)"
      grep -E '^error(\[E[0-9]+\])?: |^test .* FAILED$|panicked at' "$LOGS/suite-cargo.log" | head -10 | sed 's/^/  /'
      fail "SUITE(cargo)"
    fi
  else
    echo "CARGO SUITE SKIP: no Rust changes"
  fi
  if [ $APP = 1 ]; then
    # Flutter's suite takes ~1 min; a run past FLUTTER_SUITE_TIMEOUT (default 900s) is hung,
    # e.g. flutter_tools after ENOSPC (run 20261003-1: a 20-min stall).
    (cd app && with_timeout "${FLUTTER_SUITE_TIMEOUT:-900}" flutter test) > "$LOGS/suite-flutter.log" 2>&1 < /dev/null; frc=$?
    r=$(tail -1 "$LOGS/suite-flutter.log")
    [ $frc = 124 ] && r="timed out after ${FLUTTER_SUITE_TIMEOUT:-900}s"
    echo "FLUTTER SUITE: $r"; echo "$r" | grep -q "All tests passed" || { fail "SUITE(flutter)"; grep -E "\[E\]$" "$LOGS/suite-flutter.log" | head -8 | sed 's/^/  /'; }
  else
    echo "FLUTTER SUITE SKIP: no app/ changes"
  fi
fi
section_end
if [ -n "$FAILED" ] && grep -qs "No space left on device" "$LOGS"/suite-*.log; then
  echo "INFRA: ENOSPC in a suite log (disk full); free space and re-run the gate. Not a code failure."
fi
[ -z "$FAILED" ] || verdict_fail "SUITES" "mutation and red-on-main"

# ---- NATIVE (informational: there is no CI to build it) -----------------------------------------
NATIVE=$(echo "$CHANGED" | grep -E '^app/(macos|ios|android|linux|windows)/|\.(swift|m|mm|h|c|cc|cpp|plist|entitlements|pbxproj|xcconfig)$' | head -8)
if [ -n "$NATIVE" ]; then echo "NATIVE NOTE: native paths touched (no CI builds them; build the macOS app by hand before release):"; echo "$NATIVE" | sed 's/^/  /'
else echo "NATIVE OK: no native paths"; fi

# ---- MUTATION (tricky only) --------------------------------------------------------------------
section MUTATION
changed_tests_in() { # changed (A/M) tests that can kill mutants of <pkg>, repo-relative
  case "$1" in
    app) echo "$CHANGED_NS" | awk -F'\t' '$1=="A"||$1=="M"{print $2}' | grep -E '^app/test/.*_test\.dart$' || true ;;
    crates/*)
      echo "$CHANGED_NS" | awk -F'\t' '$1=="A"||$1=="M"{print $2}' | grep -E "^$1/tests/.*\.rs$" || true
      local f
      for f in $(echo "$CHANGED" | grep -E "^$1/src/.*\.rs$"); do
        [ -f "$f" ] && [ "$(rs_part "$BASE_SHA" "$f" test)" != "$(rs_part WORK "$f" test)" ] && echo "$f"
      done
      true ;;
  esac
}
mkey() { echo "$1" | tr -c 'A-Za-z0-9\n' '_'; }
mutation() {
  if [ "${MUTATION_OFF:-0}" = 1 ]; then echo "MUTATION SKIP: paused (MUTATION_OFF=1, Connor 2026-10-20)"; return 0; fi
  if [ "$COMPLEXITY" != tricky ]; then echo "MUTATION SKIP: complexity $COMPLEXITY (tricky only)"; return 0; fi
  local MS=$SCRIPT_DIR/mutation-spot.sh max=${MUTATION_MAX:-16} pkgs="" p cnt sites="" total=0 k=0 s=0 out budget surv="" cands="" tests b=0 left progress
  [ "$max" -gt 20 ] && max=20
  [ -x "$MS" ] || { echo "MUTATION FAIL: $MS missing"; return 1; }
  echo "$CHANGED" | grep -qE '^app/lib/.*\.dart$' && cands="app"
  for p in $(echo "$CHANGED" | grep -oE '^crates/[^/]+/src/' | sed 's#/src/$##' | sort -u); do cands="$cands $p"; done
  for p in $cands; do
    cnt=$(ORCH_SCRATCH=$LOGS "$MS" --worktree "$G" --base "$BASE_SHA" --pkg "$p" --count-only | sed -n 's/^MUTATION SITES: //p')
    if [ -z "$(changed_tests_in "$p")" ]; then
      [ "${cnt:-0}" -gt 0 ] && echo "MUTATION WARN: $p has $cnt mutation sites on added lines but the PR changes no tests for $p; not mutated"
      continue
    fi
    [ "${cnt:-0}" -gt 0 ] || continue
    pkgs="$pkgs $p"; sites="$sites $p=$cnt"
  done
  if [ -z "$pkgs" ]; then echo "MUTATION SKIP: no mutable added lines in packages whose tests the PR changes"; return 0; fi
  # split the budget round-robin over packages, capped by each package's site count
  for p in $pkgs; do eval "B_$(mkey "$p")=0"; done
  left=$max; progress=1
  while [ $left -gt 0 ] && [ $progress = 1 ]; do
    progress=0
    for p in $pkgs; do
      [ $left -gt 0 ] || break
      cnt=$(echo "$sites" | tr ' ' '\n' | sed -n "s#^$p=##p"); eval "b=\$B_$(mkey "$p")"
      if [ "$b" -lt "$cnt" ]; then eval "B_$(mkey "$p")=$((b + 1))"; left=$((left - 1)); progress=1; fi
    done
  done
  for p in $pkgs; do
    eval "budget=\$B_$(mkey "$p")"
    [ "$budget" -gt 0 ] || continue
    tests=""
    [ "$p" = app ] && tests=$(changed_tests_in app | tr '\n' ' ')
    out=$(ORCH_SCRATCH=$LOGS "$MS" --worktree "$G" --base "$BASE_SHA" --pkg "$p" --tests "$tests" \
            --max "$budget" --timeout "${MUTATION_TIMEOUT:-900}" --threshold "${MUTATION_THRESHOLD:-25}" 2>&1)
    echo "$out" | grep -E '^MUTANT '
    echo "$out" | grep -E '^MUTATION ' | sed "s#^MUTATION #  mutation-spot $p: #"
    if echo "$out" | grep -qE '^MUTATION FAIL: (baseline|could not restore|worktree differs|usage|test file|cannot read|no such|unknown base)'; then
      echo "$out" | grep -A6 -E '^MUTATION FAIL: baseline' | grep -E '^  ' | cut -c1-220   # the baseline's own failure lines
      echo "MUTATION FAIL: mutation-spot error in $p (see above)"; return 1
    fi
    k=$((k + $(echo "$out" | grep -cE '^MUTANT (KILLED|MEMORY)'))); s=$((s + $(echo "$out" | grep -c '^MUTANT SURVIVED')))
    surv="$surv $(echo "$out" | awk '/^MUTANT SURVIVED/ {print $3}' | tr '\n' ' ')"
  done
  # Equivalent mutants: the PR body may list "- <file>:<line> — <reason>" under "## Mutation exemptions".
  # An exempted survivor is not counted either way. It is printed so reviewers can judge the claim.
  local exempt lab reason e=0
  exempt=$(printf '%s\n' "$PR_BODY" | perl -ne 'if (/^#{2,4}\s*Mutation exemptions/i) { $in = 1; next } if ($in && /^#{1,4}\s/) { $in = 0 } if ($in && m{([\w./-]+\.(?:dart|rs)):(\d+)\s*(?:[-\x{2014}:]+|\xe2\x80\x94)?\s*(.*)}) { print "$1:$2\t$3\n" }')
  for lab in $surv; do
    reason=$(printf '%s\n' "$exempt" | awk -F'\t' -v l="$lab" '$1 == l { print $2; exit }')
    if printf '%s\n' "$exempt" | awk -F'\t' -v l="$lab" '$1 == l { f = 1 } END { exit !f }'; then
      if [ -n "$reason" ]; then echo "MUTATION EXEMPT: $lab — $reason (equivalent-mutant claim; reviewers judge it)"; e=$((e + 1))
      else echo "MUTATION WARN: exemption for $lab has no reason; not applied"; fi
    fi
  done
  s=$((s - e))
  total=$((k + s))
  if [ $total = 0 ]; then echo "MUTATION SKIP: no valid mutants were produced"; return 0; fi
  allowed=$((total * ${MUTATION_THRESHOLD:-25} / 100)); [ $allowed -lt 1 ] && [ $total -ge 2 ] && allowed=1
  if [ $s -gt $allowed ]; then echo "MUTATION FAIL: $k killed, $s survived (allowed <= $allowed of $total)"; return 1; fi
  echo "MUTATION OK: $k killed, $s survived (allowed <= $allowed of $total)"
}
mutation || fail MUTATION
section_end

# ---- RED ON MAIN (destructive: runs last) --------------------------------------------------------
section "RED ON MAIN"
red_on_main() {
  if [ $CODE_CHANGED = 0 ]; then echo "RED ON MAIN SKIP: no code change (tests-only or non-code PR)"; return 0; fi
  local keep="" hybrid="" runnable="" st path n_red=0 n_green=0 n_unknown=0 total=0
  while IFS="$(printf '\t')" read -r st path; do
    [ -n "$path" ] || continue
    if is_test_path "$path"; then
      keep="$keep $path"
      case "$st" in A|M)
        case "$path" in
          app/integration_test/*) echo "RED ON MAIN NOTE: $path is an integration_test (needs a device); kept but not run" ;;
          app/*_test.dart) runnable="$runnable $path" ;;
          crates/*/tests/*/*) echo "RED ON MAIN NOTE: $path is integration-test support (not a test target); kept, not run" ;;
          crates/*/tests/*.rs) runnable="$runnable $path" ;;
        esac ;;
      esac
    elif is_rs_src "$path" && [ "$st" != D ] && [ "$(rs_part "$BASE_SHA" "$path" test)" != "$(rs_part WORK "$path" test)" ]; then
      if [ "$st" = A ] || ! git cat-file -e "$BASE_SHA:$path" 2>/dev/null; then
        echo "RED ON MAIN NOTE: $path is a NEW source file with a test module; base does not compile it, so it cannot be run there"
      else
        hybrid="$hybrid $path"
        case "$path" in
          */src/main.rs|*/src/bin/*) echo "RED ON MAIN NOTE: $path is a binary target; its test module is kept but not run" ;;
          *) runnable="$runnable $path" ;;
        esac
      fi
    fi
  done <<EOF
$CHANGED_NS
EOF
  # A fix for an EXISTING failing test changes no test file: the PR body names those tests under
  # "## Red on main" (repo-relative test paths), and they must fail on base like any other.
  local named
  named=$(printf '%s\n' "$PR_BODY" | perl -ne 'if (/^#{2,4}\s*Red on main\b/i) { $in = 1; next } if ($in && /^#{1,4}\s/) { $in = 0 } if ($in) { print "$1\n" while m{(app/[\w./-]+_test\.dart|crates/[\w.-]+/tests/[\w.-]+\.rs)}g }' | sort -u)
  for path in $named; do
    if [ ! -f "$path" ]; then echo "RED ON MAIN WARN: '## Red on main' names $path, which does not exist"; continue; fi
    case " $runnable " in *" $path "*) ;; *) runnable="$runnable $path"; keep="$keep $path"; echo "RED ON MAIN NOTE: $path named under '## Red on main' (existing test)" ;; esac
  done
  if [ -z "$runnable" ]; then echo "RED ON MAIN FAIL: the PR changes code but adds/changes no test (app/test/*_test.dart, crates/*/tests/*.rs, or a #[cfg(test)] module in an existing crates/*/src file) and names no existing failing test under '## Red on main'"; return 1; fi
  # Save the hybrids' test modules (the merged #[cfg(test)] part) before restoring.
  local hdir="$LOGS/red-hybrid" i=0
  mkdir -p "$hdir"
  for path in $hybrid; do i=$((i + 1)); rs_part WORK "$path" test > "$hdir/$i.test"; done
  # drop leftovers of earlier sections (pub get rewrites) so the tree is exactly the merged index,
  # then restore every non-test change to BASE (delete PR-added files)
  git checkout -q -- . 2>/dev/null
  while IFS="$(printf '\t')" read -r st path; do
    [ -n "$path" ] || continue
    case " $keep " in *" $path "*) continue ;; esac
    case "$st" in
      A) git rm -q -f -- "$path" >/dev/null 2>&1 || rm -f -- "$path" ;;
      *) git checkout -q "$BASE_SHA" -- "$path" 2>/dev/null || { echo "RED ON MAIN FAIL: cannot restore $path to base"; return 1; } ;;
    esac
  done <<EOF
$CHANGED_NS
EOF
  # hybrid = base's code part + the PR's test module
  i=0
  for path in $hybrid; do
    i=$((i + 1))
    { rs_part "$BASE_SHA" "$path" code; cat "$hdir/$i.test"; } > "$path.redtmp" && mv "$path.redtmp" "$path"
  done
  # verify: the tree now differs from BASE only in the kept test files and the hybrids
  local stray
  stray=$(git diff --name-only "$BASE_SHA" | grep -vxF -f <(printf '%s\n' $keep $hybrid) || true)
  if [ -n "$stray" ]; then echo "RED ON MAIN FAIL: restore incomplete; still differs from base:"; echo "$stray" | head -5 | sed 's/^/  /'; return 1; fi
  echo "RED ON MAIN: base@$BASE_SHORT + PR tests ($(echo $keep $hybrid | wc -w | tr -d ' ') kept, $(echo $runnable | wc -w | tr -d ' ') runnable)"

  # --- Dart: one flutter test run over every runnable app test file (json reporter) ---
  local dfiles="" f t1 rc row pass failn load compiled
  for path in $runnable; do case "$path" in app/*) dfiles="$dfiles ${path#app/}" ;; esac; done
  if [ -n "$dfiles" ]; then
    t1=$SECONDS
    (cd app && flutter pub get > "$LOGS/red-pubget.log" 2>&1) || echo "RED ON MAIN WARN: pub get failed in app on base (tests will likely fail to load)"
    # shellcheck disable=SC2086
    (cd app && with_timeout "$RED_TIMEOUT" flutter test -r json $dfiles) > "$LOGS/red-app.json" 2> "$LOGS/red-app.err" < /dev/null; rc=$?
    [ $rc = 124 ] && echo "RED ON MAIN WARN: app run hit the ${RED_TIMEOUT}s timeout"
    # per-suite summary: path, passed, failed, load-failed, skipped, compile-error
    perl -MJSON::PP -e '
      my (%suite, %test, %r, %failed, %compile);
      while (<STDIN>) { next unless /^\{/; my $e = eval { JSON::PP->new->utf8(0)->decode($_) } or next; my $t = $e->{type} // "";
        if ($t eq "suite") { $suite{$e->{suite}{id}} = $e->{suite}{path} // "" }
        elsif ($t eq "testStart") { $test{$e->{test}{id}} = [$e->{test}{suiteID}, $e->{test}{name} // ""] }
        elsif ($t eq "testDone") { my ($sid, $nm) = @{$test{$e->{testID}} // [-1, ""]}; my $p = $suite{$sid} // next;
          $r{$p} //= [0, 0, 0, 0];
          if (($e->{result} // "") eq "success") { if ($e->{skipped}) { $r{$p}[3]++ } elsif (!$e->{hidden}) { $r{$p}[0]++ } }
          elsif (!$failed{$e->{testID}}++) { $r{$p}[1]++; $r{$p}[2]++ if $nm =~ /^loading / } }
        elsif ($t eq "error") { my ($sid, $nm) = @{$test{$e->{testID}} // [-1, ""]}; my $p = $suite{$sid} // next; $r{$p} //= [0,0,0,0];
          $compile{$p} = 1 if ($e->{error} // "") =~ /\.dart:\d+:\d+: Error|Compilation failed/;
          if (!$failed{$e->{testID}}++) { $r{$p}[1]++; $r{$p}[2]++ if $nm =~ /^loading / } } }
      for my $p (sort keys %r) { print join("\t", $p, @{$r{$p}}, $compile{$p} ? 1 : 0), "\n" }' < "$LOGS/red-app.json" > "$LOGS/red-app.tsv"
    for f in $dfiles; do
      total=$((total + 1))
      row=$(awk -F'\t' -v rel="$f" -v pk="/app/$f" '$1==rel || substr($1, length($1)-length(pk)+1)==pk' "$LOGS/red-app.tsv" | head -1)
      if [ -z "$row" ]; then
        n_unknown=$((n_unknown + 1)); echo "RED ON MAIN UNKNOWN: app/$f produced no result (exit $rc; see $LOGS/red-app.err) — not counted as red"; continue
      fi
      pass=$(echo "$row" | cut -f2); failn=$(echo "$row" | cut -f3); load=$(echo "$row" | cut -f4); compiled=$(echo "$row" | cut -f6)
      if [ "$load" -gt 0 ] && [ "$failn" = "$load" ] && [ "$compiled" != 1 ]; then
        # a load failure without a compile error is infrastructure (crashed compiler, VM), not proof
        n_unknown=$((n_unknown + 1)); echo "RED ON MAIN UNKNOWN: app/$f failed to load without a compile error (see $LOGS/red-app.json) — not counted as red"
      elif [ "$failn" -gt 0 ]; then
        n_red=$((n_red + 1))
        if [ "$load" -gt 0 ]; then echo "RED ON MAIN RED: app/$f (fails to load on base)"; else echo "RED ON MAIN RED: app/$f ($failn failing, $pass passing on base)"; fi
      else
        n_green=$((n_green + 1)); echo "RED ON MAIN GREEN-ON-MAIN: app/$f ($pass passing on base; WARN: this file does not prove the change)"
      fi
    done
    echo "TIME RED ON MAIN app: $((SECONDS - t1))s"
  fi

  # --- Rust: one cargo test run per runnable target (integration test file or unit-test module) ---
  local cdir crate log label mp p_ f_
  for path in $runnable; do
    case "$path" in crates/*) ;; *) continue ;; esac
    cdir=$(echo "$path" | cut -d/ -f1-2); crate=$(crate_name "$cdir")
    total=$((total + 1)); t1=$SECONDS
    log="$LOGS/red-$(echo "$path" | tr '/' '_').log"
    case "$path" in
      crates/*/tests/*.rs)
        f=$(basename "$path" .rs); label="--test $f"
        with_timeout "$RED_TIMEOUT" cargo test -p "$crate" --test "$f" --no-fail-fast > "$log" 2>&1 < /dev/null; rc=$? ;;
      *)
        # module path of the unit-test module: src/a/b.rs -> a::b::tests, src/a/mod.rs -> a::, src/lib.rs -> (all)
        mp=${path#"$cdir"/src/}; mp=${mp%.rs}; mp=${mp%/mod}; [ "$mp" = lib ] && mp=""; mp=$(echo "$mp" | sed 's#/#::#g')
        label="--lib ${mp:+-- $mp::}"
        if [ -n "$mp" ]; then
          with_timeout "$RED_TIMEOUT" cargo test -p "$crate" --lib --no-fail-fast -- "$mp::" > "$log" 2>&1 < /dev/null; rc=$?
        else
          with_timeout "$RED_TIMEOUT" cargo test -p "$crate" --lib --no-fail-fast > "$log" 2>&1 < /dev/null; rc=$?
        fi ;;
    esac
    read -r p_ f_ <<< "$(perl -ne '$p += $1, $f += $2 if /^test result: \w+\. (\d+) passed; (\d+) failed/; END { print $p+0, " ", $f+0 }' "$log")"
    if [ $rc = 124 ]; then
      n_unknown=$((n_unknown + 1)); echo "RED ON MAIN UNKNOWN: $path hit the ${RED_TIMEOUT}s timeout — not counted as red"
    elif grep -qE '^error\[E[0-9]+\]: |^error: could not compile' "$log"; then
      # a compile failure counts as red when the error is in this target (another hybrid's test
      # module can break the shared --lib test build)
      case "$path" in
        crates/*/tests/*) n_red=$((n_red + 1)); echo "RED ON MAIN RED: $path (fails to compile on base)" ;;
        *) if grep -A4 -E '^error(\[E[0-9]+\])?: ' "$log" | grep -qE -- "--> ($path|${path#"$cdir"/}):"; then
             n_red=$((n_red + 1)); echo "RED ON MAIN RED: $path (test module fails to compile on base)"
           else
             n_unknown=$((n_unknown + 1)); echo "RED ON MAIN UNKNOWN: $path: the $crate --lib test build fails elsewhere (see $log) — not counted as red"
           fi ;;
      esac
    elif [ "$f_" -gt 0 ]; then
      n_red=$((n_red + 1)); echo "RED ON MAIN RED: $path ($f_ failing, $p_ passing on base; cargo test -p $crate $label)"
    elif [ "$p_" -gt 0 ]; then
      n_green=$((n_green + 1)); echo "RED ON MAIN GREEN-ON-MAIN: $path ($p_ passing on base; WARN: this file does not prove the change)"
    else
      n_unknown=$((n_unknown + 1)); echo "RED ON MAIN UNKNOWN: $path ran no tests (exit $rc; cargo test -p $crate $label; see $log) — not counted as red"
    fi
    echo "TIME RED ON MAIN $path: $((SECONDS - t1))s"
  done
  if [ $n_red = 0 ]; then
    echo "RED ON MAIN FAIL: 0/$total changed tests fail on base ($n_green green, $n_unknown no result): the tests do not prove the change"
    return 1
  fi
  echo "RED ON MAIN OK: $n_red/$total changed tests are red on base ($n_green green-on-main, $n_unknown no result)"
}
red_on_main || fail "RED-ON-MAIN"
section_end

# ---- verdict --------------------------------------------------------------------------------------
echo "TIME TOTAL: $((SECONDS - T_ALL))s"
echo "GATE INFO pr=$PR head=$PR_HEAD base=$BASE_SHA wi=${WI:-none} link=${LINK:-none} complexity=$COMPLEXITY suites=$([ $SKIP_SUITES = 1 ] && echo skipped || echo run) logs=$LOGS"
if [ -n "$FAILED" ]; then echo "GATE FAIL: PR #$PR onto $BASE_REF@$BASE_SHORT — failed:$FAILED"; exit 1; fi
if [ $SKIP_SUITES = 1 ]; then SUFFIX=" (suites SKIPPED: not a merge verdict)"; else SUFFIX=""; fi
echo "GATE PASS: PR #$PR onto $BASE_REF@$BASE_SHORT$SUFFIX"
exit 0
