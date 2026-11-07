#!/bin/bash
# wi-setup.sh — prepare the CURRENT git worktree for one Work Item (open_memex adapter).
#
#   wi-setup.sh <id> <branch-name> [base-ref]
#
#   id          a WI number (12) or any label (lead-7). Informational only here (open_memex has
#               no shared test database), printed in the READY line.
#   branch-name e.g. feat/7-12-backlinks-panel
#   base-ref    default origin/main. Use origin/<blocker-branch> to stack on an open PR.
#
# What it does (idempotent):
#   - refuses to run in the main checkout or in the gate worktree ($MAIN/worktrees/_gate)
#   - run from a run's bin/, appends this worktree to <runDir>/worktrees.txt (read by cleanup-run.sh)
#   - git fetch origin (3 tries: parallel fetches race on locks), then creates <branch-name> at
#     <base-ref>; an existing branch is checked out untouched. If another worktree holds the
#     branch (test author -> implementer hand-off) and is clean, it is detached so this one can
#     take the branch over with its commits.
#   - copies the gitignored .claude/settings.local.json from the main checkout, if present
#   - flutter pub get in app/ and cargo fetch at the root (WARN on failure, not fatal)
#
# Cargo: each worktree builds into its own target/ (default). The first `cargo test` in a fresh
# worktree is a cold build of the whole workspace (rusqlite bundled, fastembed, ...). Do not
# share CARGO_TARGET_DIR between worktrees: parallel agents block on the build-dir lock.
#
# Output: one "READY ..." line on success. Exit 0 ok, 1 failure.
set -euo pipefail

ID=${1:?usage: wi-setup.sh <id> <branch-name> [base-ref]}
BR=${2:?usage: wi-setup.sh <id> <branch-name> [base-ref]}
BASE=${3:-origin/main}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
resolve_main() {
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$d/.." && pwd)
}
MAIN=$(resolve_main "$PWD" || resolve_main "$SCRIPT_DIR") || { echo "WI-SETUP FAIL: not inside a git repo" >&2; exit 1; }

TOP=$(git rev-parse --show-toplevel)
if [ "$TOP" = "$MAIN" ]; then echo "WI-SETUP REFUSING: this is the main checkout. Run inside your own worktree." >&2; exit 1; fi
if [ "$TOP" = "$MAIN/worktrees/_gate" ]; then echo "WI-SETUP REFUSING: this is the merge-check gate worktree." >&2; exit 1; fi
cd "$TOP"
# Run from a run's bin/, record this worktree for cleanup-run.sh (PROTOCOL §1 promised it; run 20261106-229-230
# found the list missing, so cleanup missed agent worktrees under .claude/worktrees/).
if [ -f "$SCRIPT_DIR/../run.json" ] && ! grep -qxF "$TOP" "$SCRIPT_DIR/../worktrees.txt" 2>/dev/null; then
  echo "$TOP" >> "$SCRIPT_DIR/../worktrees.txt"
fi

for i in 1 2 3; do git fetch origin --quiet && break; echo "WI-SETUP WARN: git fetch failed (attempt $i; parallel fetches race on locks)" >&2; sleep $((i * 3)); done
if git show-ref --verify --quiet "refs/heads/$BR"; then
  # Hand-off: the test author's (or a replaced implementer's) worktree may still hold the branch.
  # Detach it if it is clean, so this worktree can take the branch over with its commits.
  HOLDER=$(git worktree list --porcelain | awk -v b="branch refs/heads/$BR" '/^worktree /{w=substr($0,10)} $0==b{print w}')
  if [ -n "$HOLDER" ] && [ "$HOLDER" != "$TOP" ]; then
    if [ -z "$(git -C "$HOLDER" status --porcelain --untracked-files=no)" ]; then
      git -C "$HOLDER" checkout --quiet --detach && echo "WI-SETUP: took over $BR from $HOLDER (detached it)"
    else
      echo "WI-SETUP FAIL: $BR is checked out with uncommitted changes in $HOLDER" >&2; exit 1
    fi
  fi
  git checkout --quiet "$BR"
else
  git checkout --quiet -b "$BR" "$BASE"
  git branch --unset-upstream "$BR" 2>/dev/null || true
fi

mkdir -p .claude && { [ -f "$MAIN/.claude/settings.local.json" ] && cp "$MAIN/.claude/settings.local.json" .claude/settings.local.json; true; }

if [ -f app/pubspec.yaml ]; then
  (cd app && flutter pub get >/dev/null 2>&1) || echo "WARN: flutter pub get failed in app/"
  # Flutter 3.47+ pub get adds an analyzer.exclude block to app/analysis_options.yaml until main
  # commits that upgrade. Keep it out of WI commits.
  git diff --quiet -- app/analysis_options.yaml 2>/dev/null \
    || echo "WARN: flutter pub get rewrote app/analysis_options.yaml (Flutter auto-upgrade); do not commit it in a WI PR"
fi
cargo fetch --quiet >/dev/null 2>&1 || echo "WARN: cargo fetch failed (offline? the first cargo build will retry)"

# ~20 parallel worktrees of cold Rust builds (1.5-4 GB each) filled the disk in run 20261003-1.
free_gb=$(df -g "$TOP" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$free_gb" ] && [ "$free_gb" -lt "${WI_MIN_FREE_GB:-20}" ]; then
  echo "WI-SETUP WARN: only ${free_gb} GB free on this volume. Delete finished worktrees' target/ and app/build/ before building." >&2
fi
echo "READY worktree=$TOP branch=$(git branch --show-current) base=$BASE head=$(git rev-parse --short HEAD) id=$ID"
echo "Cargo builds into $TOP/target (per worktree; first build is cold, ~minutes). Do not share CARGO_TARGET_DIR across worktrees."
echo "Heavy suites (cargo test --workspace, full flutter test in app/): $SCRIPT_DIR/suite-slot.sh <command>"
