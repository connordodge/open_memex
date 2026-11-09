#!/bin/bash
# staging-build.sh <staging-tag>: point <repo>/worktrees/_staging at the tag, build the release CLI and
# the macOS app, and verify the app's code signature (adapter.md, Release, Staging step 3).
#
#   staging-build.sh staging-20261109.1
#
# Prints SIGN OK and the two paths on success. If the signature doesn't verify, it prints SIGN WARN,
# deletes app/build/macos and rebuilds once; a second failure prints SIGN FAIL and exits 1.
# Why (2026-11-09, staging-20261109.1): an incremental `flutter build macos --release` rebuilt
# App.framework but kept the previous build's ad-hoc signature. `codesign --verify --deep` then said
# "nested code is modified or invalid", so Gatekeeper could refuse the app. A clean build fixed it.
set -euo pipefail
TAG=${1:?usage: staging-build.sh <staging-tag>}
REPO=$(git rev-parse --path-format=absolute --git-common-dir); REPO=${REPO%/.git}
S="$REPO/worktrees/_staging"
git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "no tag $TAG" >&2; exit 1; }

if [ -d "$S" ]; then
  # The last build leaves app/macos dirty (Podfile, Runner.xcodeproj, SwiftPM folders).
  git -C "$S" restore app/macos
  git -C "$S" clean -fdq app/macos
  git -C "$S" checkout -q --detach "$TAG"
else
  git -C "$REPO" worktree add -q --detach "$S" "$TAG"
fi
GUARD="$S/.claude/orchestration/scripts/run-guarded.sh"
APP="$S/app/build/macos/Build/Products/Release/Open Memex.app"

(cd "$S" && "$GUARD" 1800 cargo build --release -p memex-mcp)
build_app() { (cd "$S/app" && "$GUARD" 1800 flutter build macos --release); }
verify() { codesign --verify --deep --strict "$APP" 2>&1; }

build_app
if ! out=$(verify); then
  echo "SIGN WARN: $out"
  echo "SIGN WARN: rebuilding the app from clean"
  rm -rf "$S/app/build/macos"
  build_app
  out=$(verify) || { echo "SIGN FAIL: $out"; exit 1; }
fi
echo "SIGN OK: $APP"
echo "BIN: $S/target/release/memex"
