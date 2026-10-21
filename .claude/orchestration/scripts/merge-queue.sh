#!/bin/bash
# merge-queue.sh <runDir>: the ONE merge queue. Pops PR numbers from <runDir>/merge-queue.txt (one per line,
# appended or reordered by the orchestrator) and merges each via merge-pr.sh. A PR that fails its gate or can't
# merge is dropped and reported (route it as a REVIEW); the queue keeps going. On an infra failure (cannot fetch or
# check out, INFRA, interrupted) it stops and keeps the PR queued. Exits when the file is empty.
# Run it with Bash run_in_background and a 7200000 timeout; never run two at once (run 20261020-66).
RUN=$1; Q=$RUN/merge-queue.txt
# MUTATION_OFF=1 in the environment pauses the MUTATION stage for every PR in the queue.
[ -n "${MUTATION_OFF:-}" ] && export MUTATION_OFF
while :; do
  p=$(grep -m1 -E '^[0-9]+' "$Q" 2>/dev/null | awk '{print $1}')
  [ -n "$p" ] || { echo "QUEUE DONE"; exit 0; }
  out=$("$RUN/bin/merge-pr.sh" "$p" "$RUN" "${QUEUE_NOTE:-WI PR}" 2>&1); rc=$?
  # Infra failures (gate worktree, fetch, disk) are not the PR's fault: keep the PR queued and stop.
  if [ $rc != 0 ] && echo "$out" | grep -qE "MERGE FAIL: cannot (check out|fetch|create)|INFRA:|GATE FAIL: interrupted"; then
    echo "== #$p INFRA STOP $(date +%H:%M)"; echo "$out" | grep -E "MERGE FAIL|INFRA|interrupted" | tail -3; echo "QUEUE STOPPED (infra)"; exit 0
  fi
  # drop the first line naming this PR
  awk -v p="$p" 'done!=1 && $1==p {done=1; next} {print}' "$Q" > "$Q.tmp" && mv "$Q.tmp" "$Q"
  echo "== #$p exit=$rc $(date +%H:%M)"
  echo "$out" | grep -E "GATE (PASS|FAIL)|MERGED|ALREADY MERGED|MERGE FAIL|MERGE-PR STOP|RED ON MAIN (OK|FAIL)|AC MAP (OK|FAIL)|SUITE FAIL|INFRA|conflict:" | tail -6
done
