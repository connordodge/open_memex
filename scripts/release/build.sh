#!/usr/bin/env bash
# build.sh: builds the Open Memex release artifacts (Spec #367,
# requirements 13, 19-23).
#
# Usage:
#   scripts/release/build.sh --version <x.y.z> [--dry-run] [--out <dir>]
#                            [--patterns <file>]...
#
#   --version <x.y.z>  the release version (names the DMG, the zip and the
#                      DMG's volume)
#   --dry-run          sign ad hoc (identity -, no timestamp); never
#                      notarize, staple or upload. The Leak check runs
#                      with --allow-empty-patterns when no deny-list is set.
#   --out <dir>        where the artifacts go (default: <checkout>/dist)
#   --patterns <file>  a Leak check deny-list file (repeatable), added to
#                      LEAK_PATTERNS
#
# Signed mode (no --dry-run) refuses to start, exit 2, unless these are all
# set and non-empty: MACOS_SIGN_IDENTITY, NOTARY_KEY_P8_PATH, NOTARY_KEY_ID,
# NOTARY_ISSUER_ID, and a deny-list (LEAK_PATTERNS or --patterns). It also
# refuses a checkout with uncommitted or untracked files (a dry run warns).
#
# Steps (each prints `STEP <n> <name>`; a failing step prints
# `FAILED <n> <name>` and exits 1):
#   1 memex      cargo build --release --locked -p memex-mcp for
#                aarch64-apple-darwin, MACOSX_DEPLOYMENT_TARGET=14.0, with
#                $HOME and the checkout remapped out of the binary
#   2 app        copy the tracked app/ files to a neutral build location
#                outside $HOME; there flutter pub get --enforce-lockfile and
#                flutter build macos --release (prefix maps for $HOME)
#   3 embed      copy the app to a work dir and memex into Contents/MacOS;
#                every Mach-O must be arm64 only
#   4 notices    scripts/release/notices.sh into Contents/Resources
#   5 sign       memex, then every nested framework and dylib, then the app
#                (hardened runtime, timestamp, Release.entitlements for the
#                app); codesign --verify --deep --strict
#   6 dmg        Open-Memex-<ver>-arm64.dmg holding the signed app (signed
#                mode: sign the DMG)
#   7 notarize   (signed mode) notarize the DMG and staple it. This is the
#                only notarization: Apple notarizes the app and memex inside
#                it too, by their code signatures, and the zip's memex is the
#                app's signed memex. The app inside is not stapled itself, so
#                Gatekeeper fetches its ticket online on first launch.
#   8 zip        memex-<ver>-macos-arm64.zip with memex, LICENSE and the
#                notices
#   9 leak check scripts/leak-check.sh --artifact over the app, memex, the
#                DMG and the zip; prints `leaks: 0` when clean
#  10 checksums  move the artifacts into <out> and write SHA256SUMS.txt
#
# Nothing reaches <out> until the Leak check passes. Exit status: 0 built,
# 1 a step failed, 2 usage error or signed-mode refusal (before STEP 1).
#
# Tools (found on PATH): git, tar, cargo, flutter, codesign, xcrun, hdiutil, ditto,
# lipo, jq, shasum.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
TRIPLE=aarch64-apple-darwin
DEPLOYMENT_TARGET=14.0
APP_NAME="Open Memex.app"
ENTITLEMENTS="$ROOT/app/macos/Runner/Release.entitlements"

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build.sh --version <x.y.z> [--dry-run] [--out <dir>]
                                [--patterns <file>]...
Signed mode needs MACOS_SIGN_IDENTITY, NOTARY_KEY_P8_PATH, NOTARY_KEY_ID,
NOTARY_ISSUER_ID and a deny-list (LEAK_PATTERNS or --patterns).
EOF
}

die_usage() {
  printf 'build: %s\n' "$1" >&2
  usage
  exit 2
}

# ---------------------------------------------------------------------------
# Arguments.

VERSION=""
DRY_RUN=0
OUT=""
PATFILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      [ $# -ge 2 ] || die_usage "--version needs a value"
      VERSION=$2
      shift
      ;;
    --dry-run) DRY_RUN=1 ;;
    --out)
      [ $# -ge 2 ] || die_usage "--out needs a directory"
      OUT=$2
      shift
      ;;
    --patterns)
      [ $# -ge 2 ] || die_usage "--patterns needs a file"
      PATFILES+=("$2")
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die_usage "unknown option: $1" ;;
  esac
  shift
done

[ -n "$VERSION" ] || die_usage "--version <x.y.z> is required"
case "$VERSION" in
  *[!0-9.]* | .* | *. | *..*) die_usage "--version must look like 1.2.3" ;;
esac
case "$VERSION" in
  *.*.*.*) die_usage "--version must look like 1.2.3" ;;
  *.*.*) ;;
  *) die_usage "--version must look like 1.2.3" ;;
esac

for f in ${PATFILES[@]+"${PATFILES[@]}"}; do
  [ -f "$f" ] && [ -r "$f" ] || die_usage "--patterns: file not found"
done

# Whether a deny-list entry is set: a non-blank line in LEAK_PATTERNS or in a
# --patterns file.
has_deny_list() {
  local f
  if printf '%s\n' "${LEAK_PATTERNS:-}" | grep -q '[^[:space:]]'; then return 0; fi
  for f in ${PATFILES[@]+"${PATFILES[@]}"}; do
    if grep -q '[^[:space:]]' "$f"; then return 0; fi
  done
  return 1
}

if [ "$DRY_RUN" = 0 ]; then
  missing=""
  for v in MACOS_SIGN_IDENTITY NOTARY_KEY_P8_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    printf 'build: signed mode needs%s (or pass --dry-run)\n' "$missing" >&2
    exit 2
  fi
  if ! has_deny_list; then
    printf 'build: signed mode needs a non-empty deny-list: set LEAK_PATTERNS or pass --patterns <file>\n' >&2
    exit 2
  fi
  [ -f "$NOTARY_KEY_P8_PATH" ] && [ -r "$NOTARY_KEY_P8_PATH" ] ||
    { printf 'build: NOTARY_KEY_P8_PATH is not a readable file\n' >&2; exit 2; }
fi

[ -n "${HOME:-}" ] || die_usage "HOME is not set"
HOME_DIR=${HOME%/}
REAL_HOME=$(cd "$HOME_DIR" 2>/dev/null && pwd -P) || REAL_HOME=$HOME_DIR
REAL_ROOT=$(cd "$ROOT" && pwd -P)
# RUSTFLAGS and Xcode build settings split on white space.
case "$HOME_DIR$REAL_HOME$ROOT$REAL_ROOT" in
  *[[:space:]]*) die_usage "HOME and the checkout path must not contain white space" ;;
esac

tools="git tar cargo flutter codesign hdiutil ditto lipo jq shasum"
[ "$DRY_RUN" = 1 ] || tools="$tools xcrun"
for t in $tools; do
  command -v "$t" >/dev/null 2>&1 || die_usage "$t is required on PATH"
done

# A release is built from a clean checkout: step 1 builds memex from the whole
# working tree and step 2 copies the tracked app/ files as they are on disk, so
# local edits or untracked files would ship in a build that matches no commit.
# Signed mode refuses; a dry run warns. Ignored files (target/, dist/) do not count.
if ! dirty=$(git -C "$ROOT" status --porcelain --untracked-files=normal 2>/dev/null); then
  [ "$DRY_RUN" = 1 ] || { printf 'build: signed mode needs a git checkout\n' >&2; exit 2; }
  dirty=""
fi
if [ -n "$dirty" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    printf 'build: WARNING: the checkout has uncommitted or untracked files; a signed run refuses this\n' >&2
  else
    printf 'build: signed mode needs a clean checkout (commit or remove local changes and untracked files)\n' >&2
    exit 2
  fi
fi

[ -n "$OUT" ] || OUT="$ROOT/dist"
mkdir -p "$OUT" || die_usage "cannot create --out"
OUT=$(cd "$OUT" && pwd)

DMG_NAME="Open-Memex-$VERSION-arm64.dmg"
ZIP_NAME="memex-$VERSION-macos-arm64.zip"
NOTICES_NAME=THIRD_PARTY_NOTICES.txt
SUMS_NAME=SHA256SUMS.txt
VOLUME="Open Memex $VERSION"

# The work dir doubles as the app's neutral build location, so it must not
# sit under $HOME.
tmp_base=${TMPDIR:-/tmp}
case "$tmp_base" in "$HOME_DIR"/* | "$REAL_HOME"/*) tmp_base=/tmp ;; esac
WORK=$(mktemp -d "${tmp_base%/}/open-memex-release.XXXXXX") || die_usage "cannot create a temp dir"
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/$APP_NAME"
DMG="$WORK/$DMG_NAME"
ZIP="$WORK/$ZIP_NAME"
NOTICES="$WORK/$NOTICES_NAME"

# ---------------------------------------------------------------------------
# Steps.

STEP_N=0
STEP_NAME=""

step() {
  STEP_N=$1
  STEP_NAME=$2
  printf 'STEP %s %s\n' "$1" "$2"
}

fail() {
  [ -z "${1:-}" ] || printf 'build: %s\n' "$1" >&2
  printf 'FAILED %s %s\n' "$STEP_N" "$STEP_NAME"
  exit 1
}

# Prints prefix-map flags: $1 is the flag, $2 is "=" to join it to its value
# or " " to keep it apart, and each later argument is <dir>=<replacement>.
# $HOME (as given and with symlinks resolved) comes first and maps to ~; the
# later ones follow it, because the last matching map wins.
remaps() {
  local flag="$1" sep="$2" pair d seen=""
  shift 2
  for pair in "$HOME_DIR=~" "$REAL_HOME=~" "$@"; do
    d=${pair%=*}
    case " $seen " in *" $d "*) continue ;; esac
    seen="$seen $d"
    printf '%s%s%s ' "$flag" "$sep" "$pair"
  done
}

# Submits $1 for notarization and waits. On a rejection prints notarytool's
# log for the submission and fails the step.
notarize() {
  local file="$1" res="$WORK/notary-$STEP_N.json" code id status
  xcrun notarytool submit "$file" --wait --key "$NOTARY_KEY_P8_PATH" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --output-format json >"$res"
  code=$?
  cat "$res"
  printf '\n'
  id=$(jq -r '.id // empty' "$res" 2>/dev/null)
  status=$(jq -r '.status // empty' "$res" 2>/dev/null)
  if [ "$code" = 0 ] && [ "$status" = Accepted ]; then
    return 0
  fi
  printf 'build: notarization of %s: %s\n' "$(basename "$file")" "${status:-no status (notarytool exit $code)}" >&2
  if [ -n "$id" ]; then
    printf 'build: notarytool log %s:\n' "$id" >&2
    xcrun notarytool log "$id" --key "$NOTARY_KEY_P8_PATH" \
      --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  fi
  fail "notarization was not accepted"
}

if [ "$DRY_RUN" = 1 ]; then
  IDENTITY=-
  TIMESTAMP=--timestamp=none
  echo "build: dry run: ad hoc signing, no notarization"
else
  IDENTITY=$MACOS_SIGN_IDENTITY
  TIMESTAMP=--timestamp
fi

# 1. memex ------------------------------------------------------------------
step 1 memex
TARGET_DIR=${CARGO_TARGET_DIR:-$ROOT/target}
case "$TARGET_DIR" in /*) ;; *) TARGET_DIR="$ROOT/$TARGET_DIR" ;; esac
(
  cd "$ROOT" || exit 1
  unset CARGO_ENCODED_RUSTFLAGS
  export MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET
  export RUSTFLAGS="$(remaps --remap-path-prefix = "$ROOT=." "$REAL_ROOT=.")"
  # C and C++ that build scripts (cc, cmake) compile for the target.
  cmaps=$(remaps -ffile-prefix-map = "$ROOT=." "$REAL_ROOT=.")
  export CFLAGS_aarch64_apple_darwin="$cmaps"
  export CXXFLAGS_aarch64_apple_darwin="$cmaps"
  exec cargo build --release --locked -p memex-mcp --target "$TRIPLE" \
    --target-dir "$TARGET_DIR"
) || fail "cargo build failed"
MEMEX_BUILT="$TARGET_DIR/$TRIPLE/release/memex"
[ -f "$MEMEX_BUILT" ] || fail "memex was not built at the expected path"

# 2. app --------------------------------------------------------------------
# A neutral build location: the checkout's tracked app/ files are copied to
# a temp dir outside $HOME and built there, so the Runner executable,
# App.framework (the Dart snapshot keeps file: URIs, such as the generated
# plugin registrant's) and the plugin frameworks (debug-map object paths)
# hold the temp path, never $HOME or the checkout. Prefix maps cover what
# still comes from under $HOME (the Flutter SDK, the pub cache).
step 2 app
SRC="$WORK/src"
mkdir "$SRC" || fail
(cd "$ROOT" && git ls-files -z -- app) >"$WORK/app-files" || fail "git ls-files failed (not a git checkout?)"
[ -s "$WORK/app-files" ] || fail "no tracked files under app/"
(cd "$ROOT" && tar --null -T "$WORK/app-files" -cf -) | (cd "$SRC" && tar -xf -)
s=("${PIPESTATUS[@]}")
[ "${s[0]}" = 0 ] && [ "${s[1]}" = 0 ] || fail "could not copy app/ to the build location"
(cd "$SRC/app" && flutter pub get --enforce-lockfile) || fail "flutter pub get failed"
(
  cd "$SRC/app" || exit 1
  # FLUTTER_XCODE_<setting> reaches xcodebuild as <setting> for the Runner
  # and every Pods target.
  export FLUTTER_XCODE_OTHER_CFLAGS="\$(inherited) $(remaps -ffile-prefix-map = "$SRC=.")"
  export FLUTTER_XCODE_OTHER_SWIFT_FLAGS="\$(inherited) $(remaps -file-prefix-map ' ' "$SRC=.")"
  export FLUTTER_XCODE_OTHER_LDFLAGS="\$(inherited) -Wl,-oso_prefix,$SRC/"
  exec flutter build macos --release
) || fail "flutter build macos failed"
APP_BUILT="$SRC/app/build/macos/Build/Products/Release/$APP_NAME"
[ -d "$APP_BUILT" ] || fail "the app was not built at the expected path"

# 3. embed ------------------------------------------------------------------
step 3 embed
ditto "$APP_BUILT" "$APP" || fail "could not copy the app"
cp "$MEMEX_BUILT" "$APP/Contents/MacOS/memex" || fail "could not copy memex"
chmod 755 "$APP/Contents/MacOS/memex" || fail

# Nested code, deepest first: frameworks and dylibs under Contents.
find "$APP/Contents" \( -name '*.framework' -type d \) -o \( -name '*.dylib' -type f \) |
  awk -F/ '{ print NF "\t" $0 }' | sort -rn -k1,1 | cut -f2- >"$WORK/nested"

# Every Mach-O the app ships is arm64 only.
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null) ||
  fail "no CFBundleExecutable in Info.plist"
{
  printf '%s\n' "$APP/Contents/MacOS/$exe" "$APP/Contents/MacOS/memex"
  while IFS= read -r n; do
    case "$n" in
      *.framework) printf '%s\n' "$n/$(basename "$n" .framework)" ;;
      *) printf '%s\n' "$n" ;;
    esac
  done <"$WORK/nested"
} >"$WORK/machos"
while IFS= read -r m; do
  archs=$(lipo -archs "$m") || fail "lipo could not read ${m#"$WORK/"}"
  printf 'lipo -archs %s: %s\n' "${m#"$WORK/"}" "$archs"
  [ "$archs" = arm64 ] || fail "${m#"$WORK/"} is not arm64 only"
done <"$WORK/machos"

# 4. notices ----------------------------------------------------------------
step 4 notices
"$SCRIPT_DIR/notices.sh" "$NOTICES" || fail "notices.sh failed"
cp "$NOTICES" "$APP/Contents/Resources/$NOTICES_NAME" || fail "could not copy the notices"

# 5. sign -------------------------------------------------------------------
step 5 sign
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" \
  "$APP/Contents/MacOS/memex" || fail "could not sign memex"
while IFS= read -r n; do
  codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" "$n" ||
    fail "could not sign ${n#"$APP/"}"
done <"$WORK/nested"
codesign --force --sign "$IDENTITY" --options runtime "$TIMESTAMP" \
  --entitlements "$ENTITLEMENTS" "$APP" || fail "could not sign the app"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign --verify failed for the app"

# 6. dmg --------------------------------------------------------------------
step 6 dmg
mkdir "$WORK/dmg" || fail
ditto "$APP" "$WORK/dmg/$APP_NAME" || fail "could not stage the app"
ln -s /Applications "$WORK/dmg/Applications" || fail
hdiutil create -volname "$VOLUME" -srcfolder "$WORK/dmg" -fs HFS+ \
  -format UDZO -ov "$DMG" || fail "hdiutil create failed"
[ -f "$DMG" ] || fail "the DMG was not created"
if [ "$DRY_RUN" = 0 ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG" || fail "could not sign the DMG"
fi

# 7. notarize ---------------------------------------------------------------
# One submission: the DMG. Apple notarizes the signed code inside it (the app,
# its frameworks and memex) by code signature, so the zip's memex, a copy of
# the app's, is covered too. Each submission can wait a long time in Apple's
# queue (v0.3.0: about 20 minutes each), so there is only one.
step 7 notarize
if [ "$DRY_RUN" = 1 ]; then
  echo "build: dry run: not notarized"
else
  notarize "$DMG"
  xcrun stapler staple "$DMG" || fail "could not staple the DMG"
fi

# 8. zip --------------------------------------------------------------------
step 8 zip
mkdir "$WORK/zip" || fail
cp "$APP/Contents/MacOS/memex" "$WORK/zip/memex" || fail "could not stage memex"
cp "$ROOT/LICENSE" "$WORK/zip/LICENSE" || fail "could not stage LICENSE"
cp "$NOTICES" "$WORK/zip/$NOTICES_NAME" || fail "could not stage the notices"
ditto -c -k --norsrc --noextattr "$WORK/zip" "$ZIP" || fail "could not make the zip"

# 9. leak check -------------------------------------------------------------
step 9 "leak check"
leak_args=()
for f in ${PATFILES[@]+"${PATFILES[@]}"}; do
  leak_args+=(--patterns "$f")
done
if [ "$DRY_RUN" = 1 ] && ! has_deny_list; then
  leak_args+=(--allow-empty-patterns)
fi
"$ROOT/scripts/leak-check.sh" ${leak_args[@]+"${leak_args[@]}"} \
  --artifact "$APP" "$APP/Contents/MacOS/memex" "$DMG" "$ZIP"
case $? in
  0) echo "leaks: 0" ;;
  1) fail "the Leak check found leaks; nothing was written to the output directory" ;;
  *) fail "the Leak check could not complete" ;;
esac

# 10. checksums -------------------------------------------------------------
step 10 checksums
for n in "$DMG_NAME" "$ZIP_NAME" "$NOTICES_NAME" "$SUMS_NAME"; do
  rm -f "$OUT/$n" || fail "could not replace $n in the output directory"
done
mv "$DMG" "$OUT/$DMG_NAME" && mv "$ZIP" "$OUT/$ZIP_NAME" &&
  cp "$NOTICES" "$OUT/$NOTICES_NAME" || fail "could not move the artifacts to the output directory"
(
  cd "$OUT" || exit 1
  shasum -a 256 "$DMG_NAME" "$ZIP_NAME" "$NOTICES_NAME" >"$WORK/$SUMS_NAME" || exit 1
  mv "$WORK/$SUMS_NAME" "$OUT/$SUMS_NAME"
) || fail "could not write $SUMS_NAME"
cat "$OUT/$SUMS_NAME"
echo "build: artifacts in $OUT"
exit 0
