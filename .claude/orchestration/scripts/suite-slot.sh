#!/bin/bash
# suite-slot.sh <command...>
# Runs a HEAVY test command (full `cargo test --workspace`, full `flutter test` in app/)
# only when one of $SUITE_SLOTS (default 3) machine-wide slots is free. With 10+ parallel
# agents each compiling the Rust workspace into its own target/, the Mac saturates and test
# timeouts look like regressions and aren't. Queue here instead.
#
#   <adapter>/scripts/suite-slot.sh cargo test --workspace
#   (cd app && <adapter>/scripts/suite-slot.sh flutter test)
#
# Focused single-file runs don't need a slot. The slot directory is machine-wide on purpose
# (default /tmp/open-memex-suite-slots, override with SUITE_SLOT_DIR) so every worktree and
# every session shares the same 3 slots. Exits with the command's exit code.
SLOTS=${SUITE_SLOTS:-3}
DIR=${SUITE_SLOT_DIR:-/tmp/open-memex-suite-slots}
mkdir -p "$DIR"
[ $# -gt 0 ] || { echo "usage: suite-slot.sh <command...>" >&2; exit 64; }
slot=""
waited=0
while [ -z "$slot" ]; do
  for i in $(seq 1 "$SLOTS"); do
    d="$DIR/slot-$i"
    if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; slot=$d; break; fi
    p=$(cat "$d/pid" 2>/dev/null)
    if [ -n "$p" ]; then
      # reclaim a slot whose holder died
      kill -0 "$p" 2>/dev/null || rm -rf "$d"
    elif [ -n "$(find "$d" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      # holder died between mkdir and writing its pid
      rm -rf "$d"
    fi
  done
  if [ -z "$slot" ]; then
    [ $((waited % 60)) -eq 0 ] && echo "[suite-slot] all $SLOTS slots busy; waiting (${waited}s)" >&2
    sleep 5; waited=$((waited + 5))
  fi
done
trap 'rm -rf "$slot"' EXIT
trap 'exit 130' INT TERM
echo "[suite-slot] got $(basename "$slot") after ${waited}s: $*" >&2
"$@"
