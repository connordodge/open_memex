#!/bin/bash
# merge-pr.sh — gate, then merge one PR (open_memex adapter).
#
#   merge-pr.sh <pr> <runDir> "<note>"
#
#   1. run merge-check.sh (log: <runDir>/gate-<pr>-<stamp>.log; the CAPS lines are echoed).
#      open_memex has NO CI, so the gate is the whole verdict: it exits 0 or 1, never 2. (An
#      exit 2 from an older/overridden gate is still honoured: wait for every PR check.)
#   2. wait until GitHub reports the PR MERGEABLE
#   3. wait for the checks named in REQUIRED_GH_CHECKS (default EMPTY: there are no GitHub
#      checks; comma/space list), up to CHECK_WAIT_MIN (20). Every one must PASS: a check that
#      is still pending, or never appeared, at the deadline -> exit 2 (a gh error counts as
#      pending, never as a pass). Set it if CI is ever added.
#   4. if origin/main moved since the gate ran, re-run the gate (max 3 rounds)
#   5. gh pr merge --merge --match-head-commit <the head the gate tested>
#   6. tick the WI's ACs (Closes #N only) via $ORCH_SKILL_DIR/scripts/tick-ac.sh
#   7. append "- <date> #<pr> (WI #N) merged sha=… <note>" under "## Merge log" in
#      <runDir>/COORDINATION.md
#
#   merge-pr.sh --self-test   drive step 3 with canned `gh pr checks` output (the self-test sets
#                             its own REQ, so it exercises the polling even though the default
#                             is empty); exit 0 = all pass
#
# Env: DRY_RUN=1          print the merge / tick commands instead of running them (still gates)
#      MERGE_CHECK_ARGS   extra merge-check.sh args (--skip-suites is refused unless DRY_RUN=1)
#      MERGE_CHECK_CMD    gate command override (testing)
#      REQUIRED_GH_CHECKS default "" (no CI)
#      CHECK_WAIT_MIN     default 20
#      CI_WAIT_MIN        default 60 (only used if a gate exits 2)
#      ORCH_SKILL_DIR     default ~/.claude/skills/orchestrate;  ORCH_REPO  owner/name
# Output: CAPS lines; last line "MERGED #<pr> sha=<sha>" on success.
# Exit: 0 merged, 1 gate/check FAIL, 3 merge failed, 2 a required check still pending or absent
#       after the wait (only possible when REQUIRED_GH_CHECKS is set).
set -uo pipefail

# ── check polling (defined first so --self-test can drive them without a PR) ──────────────
checks_json() { # prints the PR's checks as a JSON array of {name,bucket}; returns 1 if gh fails
  # A gh error (network, auth, rate limit, "no checks reported" before anything has posted)
  # must never read as "no checks": callers treat a failure as "still pending".
  local j _
  for _ in 1 2 3; do
    j=$(gh pr checks "$PR" -R "$REPO" --json name,bucket 2>/dev/null)
    case "$j" in \[*) echo "$j"; return 0 ;; esac
    sleep 5
  done
  return 1
}

wait_all_checks() { # native PRs: every check must pass. 0 pass, 1 fail, 2 timeout
  local deadline=$((SECONDS + ${CI_WAIT_MIN:-60} * 60)) j pend bad n
  while :; do
    # gh failing counts as nothing passed yet (n=0), never as a pass.
    j=$(checks_json) || { echo "CI WARN: gh pr checks failed; treating as pending"; j='[]'; }
    n=$(echo "$j" | jq 'length'); pend=$(echo "$j" | jq '[.[] | select(.bucket == "pending")] | length')
    bad=$(echo "$j" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | join(", ")')
    if [ -n "$bad" ]; then echo "CI FAIL: $bad"; return 1; fi
    if [ "$n" -gt 0 ] && [ "$pend" = 0 ]; then echo "CI OK: $n checks passed"; return 0; fi
    [ $SECONDS -ge $deadline ] && { echo "CI PENDING: $pend of $n checks still pending after ${CI_WAIT_MIN:-60} min"; return 2; }
    [ "$DRY" = 1 ] && { echo "CI DRY RUN: $n checks, $pend pending; not waiting"; return 0; }
    sleep 30
  done
}

wait_mergeable() { # 0 mergeable, 3 not
  local m=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    m=$(gh pr view "$PR" -R "$REPO" --json mergeable -q .mergeable 2>/dev/null)
    [ "$m" != UNKNOWN ] && [ -n "$m" ] && break
    [ "$DRY" = 1 ] && break
    sleep 10
  done
  if [ "$m" = MERGEABLE ]; then echo "MERGEABLE OK"; return 0; fi
  if [ "$DRY" = 1 ]; then echo "MERGEABLE WARN: $m (continuing: dry run)"; return 0; fi
  echo "MERGE FAIL: PR #$PR is not mergeable ($m)"; return 3
}

# 0 every required check passed, 1 one failed, 2 one is still pending or ABSENT after the wait.
# Absent is not satisfied: a required check that never posted (broken workflow, missed webhook,
# [skip ci]) must not read as a pass. `skipping` (a draft's skipped Action) is accepted with a WARN.
# With REQUIRED_GH_CHECKS empty (the open_memex default: no CI) this is a no-op.
wait_required_checks() {
  [ -n "$REQ" ] || { echo "CHECKS SKIP: REQUIRED_GH_CHECKS is empty"; return 0; }
  local deadline=$((SECONDS + ${CHECK_WAIT_MIN:-20} * 60)) j name b todo absent
  while :; do
    j=$(checks_json) || { echo "CHECK WARN: gh pr checks failed; treating every required check as pending"; j='[]'; }
    todo=""; absent=""
    for name in $REQ; do
      b=$(echo "$j" | jq -r --arg n "$name" '[.[] | select(.name == $n) | .bucket] | first // "absent"')
      case "$b" in
        pass) ;;
        skipping) echo "CHECK WARN: $name was skipped" ;;
        fail|cancel) echo "CHECK FAIL: $name ($b)"; return 1 ;;
        absent) absent="$absent $name" ;;
        *) todo="$todo $name" ;;
      esac
    done
    if [ -z "$todo" ] && [ -z "$absent" ]; then echo "CHECKS OK:$(printf ' %s' $REQ)"; return 0; fi
    if [ $SECONDS -ge $deadline ]; then
      [ -n "$todo" ] && echo "CHECK PENDING:$todo still not passed after ${CHECK_WAIT_MIN:-20} min"
      [ -n "$absent" ] && echo "CHECK PENDING:$absent never appeared on PR #$PR after ${CHECK_WAIT_MIN:-20} min"
      return 2
    fi
    [ "$DRY" = 1 ] && { echo "CHECK DRY RUN: pending:$todo$absent; not waiting"; return 0; }
    sleep 30
  done
}

self_test() { # merge-pr.sh --self-test: wait_required_checks against canned `gh pr checks` JSON
  local tmp fails=0 n=0
  tmp=$(mktemp -d) || return 1
  # Explicit REQ: the production default is empty (no CI), which would skip the polling under test.
  PR=0; REPO=selftest/none; DRY=0; REQ="coverage coverage/flutter"
  # Stubs. `gh` replays one canned response per call from $tmp/seq (one per line; the last
  # repeats; ERR = gh fails). `sleep` just advances bash's SECONDS, so a 20-min wait is instant.
  gh() {
    local i line
    i=$(cat "$tmp/i"); echo $((i + 1)) > "$tmp/i"
    line=$(sed -n "$((i + 1))p" "$tmp/seq"); [ -n "$line" ] || line=$(tail -n 1 "$tmp/seq")
    [ "$line" = ERR ] && { echo "HTTP 502: Bad Gateway" >&2; return 1; }
    echo "$line"
  }
  sleep() { SECONDS=$((SECONDS + ${1:-0})); }
  # case <label> <expected rc> <expected output (grep -E)> <canned response>...
  case_() {
    local label=$1 want_rc=$2 want_out=$3 out rc
    shift 3
    printf '%s\n' "$@" > "$tmp/seq"; echo 0 > "$tmp/i"; SECONDS=0
    out=$(wait_required_checks); rc=$?
    n=$((n + 1))
    if [ "$rc" = "$want_rc" ] && echo "$out" | grep -qE "$want_out"; then
      echo "SELF-TEST ok   $label -> rc=$rc, $(echo "$out" | tail -n 1) [gh calls: $(cat "$tmp/i")]"
    else
      fails=$((fails + 1))
      echo "SELF-TEST FAIL $label -> rc=$rc (want $want_rc), output:"
      echo "$out" | while IFS= read -r l; do echo "    $l"; done
    fi
  }
  local P='{"name":"coverage","bucket":"pass"}' F='{"name":"coverage/flutter","bucket":"pass"}'
  local FP='{"name":"coverage/flutter","bucket":"pending"}' FX='{"name":"coverage/flutter","bucket":"fail"}'
  local BKP='{"name":"other/ci-tests","bucket":"pending"}' BKX='{"name":"other/ci-tests","bucket":"fail"}'
  case_ "both pass -> OK" 0 '^CHECKS OK: coverage coverage/flutter$' "[$P,$F]"
  case_ "coverage/flutter failed -> FAIL" 1 '^CHECK FAIL: coverage/flutter \(fail\)$' "[$P,$FX,$BKX]"
  case_ "coverage cancelled -> FAIL" 1 '^CHECK FAIL: coverage \(cancel\)$' '[{"name":"coverage","bucket":"cancel"},'"$F]"
  case_ "coverage/flutter absent, rest settled -> NOT merged" 2 'CHECK PENDING: coverage/flutter never appeared' "[$P]"
  case_ "no checks at all -> NOT merged" 2 'never appeared' '[]'
  case_ "pending, then pass -> waits, then OK" 0 '^CHECKS OK' "[$P,$FP,$BKP]" "[$P,$FP,$BKP]" "[$P,$F,$BKP]"
  case_ "absent (queued), then pending, then pass -> OK" 0 '^CHECKS OK' "[$P,$BKP]" "[$P,$FP,$BKP]" "[$P,$F]"
  case_ "pending forever -> exit 2 after the wait" 2 'CHECK PENDING: coverage/flutter still not passed after 20 min' "[$P,$FP]"
  case_ "gh errors forever -> never passes" 2 'CHECK PENDING: coverage coverage/flutter never appeared' ERR
  case_ "gh errors twice, then pass -> retried, OK" 0 '^CHECKS OK' ERR ERR "[$P,$F]"
  case_ "coverage skipped (draft) + flutter pass -> OK" 0 'CHECK WARN: coverage was skipped' '[{"name":"coverage","bucket":"skipping"},'"$F]"
  REQ=""; case_ "REQUIRED_GH_CHECKS empty (open_memex default, no CI) -> skip" 0 '^CHECKS SKIP: REQUIRED_GH_CHECKS is empty$' '[]'
  REQ="coverage coverage/flutter"
  rm -rf "$tmp"
  echo "SELF-TEST $((n - fails))/$n passed"
  [ "$fails" = 0 ]
}

if [ "${1:-}" = --self-test ]; then self_test; exit $?; fi

PR=${1:-}; RUN=${2:-}; NOTE=${3:-}
case "$PR" in ''|*[!0-9]*) echo "MERGE-PR FAIL: usage: merge-pr.sh <pr> <runDir> \"<note>\""; exit 1 ;; esac
[ -n "$RUN" ] || { echo "MERGE-PR FAIL: usage: merge-pr.sh <pr> <runDir> \"<note>\""; exit 1; }
[ -d "$RUN" ] || { echo "MERGE-PR FAIL: run dir $RUN does not exist"; exit 1; }
RUN=$(cd "$RUN" && pwd)
DRY=${DRY_RUN:-0}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
resolve_main() {
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$d/.." && pwd)
}
MAIN=$(resolve_main "$PWD" || resolve_main "$SCRIPT_DIR") || { echo "MERGE-PR FAIL: not inside a git repo"; exit 1; }
REPO=${ORCH_REPO:-$(cd "$MAIN" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}
[ -n "$REPO" ] || { echo "MERGE-PR FAIL: cannot determine owner/name (set ORCH_REPO)"; exit 1; }
GATE=${MERGE_CHECK_CMD:-$SCRIPT_DIR/merge-check.sh}
EXTRA=${MERGE_CHECK_ARGS:-}
case " $EXTRA " in *" --skip-suites "*)
  [ "$DRY" = 1 ] || { echo "MERGE-PR FAIL: MERGE_CHECK_ARGS contains --skip-suites; a real merge needs the full gate"; exit 1; } ;;
esac
REQ=$(echo "${REQUIRED_GH_CHECKS-}" | tr ',' ' ')
[ "$DRY" = 1 ] && echo "MERGE-PR DRY RUN: nothing will be merged, ticked or pushed"

state=$(gh pr view "$PR" -R "$REPO" --json state -q .state 2>/dev/null) || { echo "MERGE-PR FAIL: cannot read PR #$PR"; exit 1; }
if [ "$state" != OPEN ]; then
  if [ "$DRY" = 1 ]; then echo "MERGE-PR WARN: PR #$PR is $state (continuing: dry run)"
  else echo "MERGE FAIL: PR #$PR is $state"; exit 3; fi
fi

HEAD_GATED=""; BASE_GATED=""; WI=""; LINK=""; GATE_RC=1
round=0
while :; do
  round=$((round + 1))
  LOG="$RUN/gate-$PR-$(date +%Y%m%d-%H%M%S).log"
  echo "GATE RUN $round: $GATE $PR $EXTRA (log $LOG)"
  # shellcheck disable=SC2086
  "$GATE" "$PR" $EXTRA > "$LOG" 2>&1; GATE_RC=$?
  grep -E '^(GATE|MERGE|SCOPE|SCHEMA|FMT|PUB GET|ANALYZE|CLIPPY|[A-Z]+ SUITE|SUITES|STATIC|NATIVE|AC MAP|AC MANUAL|COMPLEXITY|MUTATION|MUTANT (SURVIVED|INVALID|TIMEOUT)|RED ON MAIN|TIME TOTAL)' "$LOG"
  info=$(grep -E '^GATE INFO ' "$LOG" | tail -1)
  HEAD_GATED=$(echo "$info" | sed -n 's/.* head=\([0-9a-f]*\).*/\1/p')
  BASE_GATED=$(echo "$info" | sed -n 's/.* base=\([0-9a-f]*\).*/\1/p')
  WI=$(echo "$info" | sed -n 's/.* wi=\([0-9]*\) .*/\1/p')
  LINK=$(echo "$info" | sed -n 's/.* link=\([a-z-]*\).*/\1/p')
  case $GATE_RC in
    0) ;;
    2) echo "GATE PASS-NEEDS-CI: waiting for every PR check (not expected: the open_memex gate never exits 2)"
       wait_all_checks; rc=$?; [ $rc = 0 ] || exit $rc ;;
    *) echo "MERGE-PR STOP: gate failed (exit $GATE_RC)"; exit 1 ;;
  esac
  [ -n "$HEAD_GATED" ] || { echo "MERGE-PR FAIL: gate output has no 'GATE INFO head=' line"; exit 1; }
  wait_mergeable || exit 3
  wait_required_checks; rc=$?; [ $rc = 0 ] || exit $rc
  cur_main=$(git -C "$MAIN" ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  if [ -n "$cur_main" ] && [ -n "$BASE_GATED" ] && [ "$cur_main" != "$BASE_GATED" ]; then
    if [ "$DRY" = 1 ]; then echo "MERGE-PR WARN: origin/main is ${cur_main:0:8}, gate base was ${BASE_GATED:0:8} (dry run: not re-gating)"; break; fi
    if [ $round -ge 3 ]; then echo "MERGE FAIL: origin/main kept moving during 3 gate rounds; run merge-pr again"; exit 3; fi
    echo "MERGE-PR RE-GATE: origin/main moved ${BASE_GATED:0:8} -> ${cur_main:0:8} since the gate ran"
    continue
  fi
  break
done

cur_head=$(gh pr view "$PR" -R "$REPO" --json headRefOid -q .headRefOid 2>/dev/null)
if [ "$cur_head" != "$HEAD_GATED" ]; then
  echo "MERGE FAIL: PR head is ${cur_head:0:8} but the gate tested ${HEAD_GATED:0:8}; re-run merge-pr"
  [ "$DRY" = 1 ] || exit 3
fi
if [ "$DRY" = 1 ]; then
  echo "DRY RUN: would run: gh pr merge $PR -R $REPO --merge --match-head-commit $HEAD_GATED"
  SHA=DRYRUN
else
  gh pr merge "$PR" -R "$REPO" --merge --match-head-commit "$HEAD_GATED" || { echo "MERGE FAIL: gh pr merge exited non-zero"; exit 3; }
  SHA=""
  for _ in 1 2 3 4 5 6; do
    SHA=$(gh pr view "$PR" -R "$REPO" --json mergeCommit -q '.mergeCommit.oid // ""' 2>/dev/null); [ -n "$SHA" ] && break; sleep 5
  done
  SHA=${SHA:0:8}
fi

TICK="${ORCH_SKILL_DIR:-$HOME/.claude/skills/orchestrate}/scripts/tick-ac.sh"
if [ -z "$WI" ]; then echo "TICK-AC SKIP: no WI in the PR body"
elif [ "$LINK" != closes ]; then echo "TICK-AC SKIP: PR is 'Part of #$WI', not 'Closes'"
elif [ ! -x "$TICK" ]; then echo "TICK-AC WARN: $TICK missing; tick WI #$WI's ACs by hand"
elif [ "$DRY" = 1 ]; then echo "DRY RUN: would run: $TICK --repo $REPO $WI"
else "$TICK" --repo "$REPO" "$WI" || echo "TICK-AC WARN: tick-ac.sh failed for WI #$WI"; fi

LEDGER="$RUN/COORDINATION.md"
kind=gate; [ "$GATE_RC" = 2 ] && kind="gate+CI"
ENTRY="- $(date +%Y-%m-%d) #$PR (WI #${WI:-?}) merged sha=$SHA ($kind)${NOTE:+. $NOTE}"
[ "$DRY" = 1 ] && ENTRY="$ENTRY [DRY RUN]"
[ -f "$LEDGER" ] || : > "$LEDGER"
grep -q '^## Merge log[[:space:]]*$' "$LEDGER" || printf '\n## Merge log\n\n' >> "$LEDGER"
tmp=$(mktemp "$RUN/.ledger.XXXXXX")
# insert after the last non-blank line of the "## Merge log" section
ENTRY="$ENTRY" awk '
  function flush_entry() { print ENVIRON["ENTRY"]; done = 1 }
  /^## Merge log[[:space:]]*$/ { print; insec = 1; next }
  insec && (/^# / || /^## /) { flush_entry(); for (i = 0; i < nb; i++) print ""; nb = 0; insec = 0; print; next }
  insec && /^[[:space:]]*$/ { nb++; next }
  insec { for (i = 0; i < nb; i++) print ""; nb = 0; print; next }
  { print }
  END { if (insec) { flush_entry(); for (i = 0; i < nb; i++) print "" } }
' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
echo "LEDGER OK: $ENTRY"
echo "MERGED #$PR sha=$SHA"
exit 0
