#!/usr/bin/env bash
# notices.sh: writes THIRD_PARTY_NOTICES.txt for the release build (Spec #367,
# requirement 20).
#
# Usage:
#   notices.sh [--fonts-dir <dir>] [--licenses-dir <dir>] <out-file>
#
# The notices hold, in this order:
#   1. every Rust crate linked into memex: each normal (non-dev, non-build)
#      dependency reachable from memex-mcp in
#      `cargo metadata --format-version 1 --filter-platform aarch64-apple-darwin`,
#      with its name, version, licence identifier and the text of its licence
#      files. A crate's own licence files (LICENSE*, LICENCE*, COPYING*,
#      NOTICE* in its manifest directory, plus the file its manifest names in
#      license-file) are used first. Only when it has none are the committed
#      texts in <licenses-dir>/<crate-name>/ used (default
#      scripts/release/third_party/licenses; each dir's SOURCE file records
#      where the text came from and is not copied into the notices).
#      Workspace members are this project's own code and are not listed.
#   2. onnxruntime's LICENSE and ThirdPartyNotices.txt from
#      scripts/release/third_party/onnxruntime/ (ort links it statically, so
#      it is not in cargo metadata);
#   3. the font licences: every OFL-*.txt in <fonts-dir> (default
#      app/assets/google_fonts).
#
# Exit status: 0 written; 1 a crate's licence text, the onnxruntime notices
# or the font licences could not be found (the message names the crate), or
# cargo metadata failed; 2 usage error or jq missing.
#
# Tools: bash 3.2, cargo (metadata only; it installs nothing), jq, and the
# POSIX basics.

set -u
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
ORT_DIR="$SCRIPT_DIR/third_party/onnxruntime"
LICENSES_DIR="$SCRIPT_DIR/third_party/licenses"
FONTS_DIR="$ROOT/app/assets/google_fonts"
ROOT_CRATE=memex-mcp
TRIPLE=aarch64-apple-darwin

usage() {
  echo "usage: notices.sh [--fonts-dir <dir>] [--licenses-dir <dir>] <out-file>" >&2
}

die() {
  printf 'notices: %s\n' "$2" >&2
  exit "$1"
}

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fonts-dir)
      [ $# -ge 2 ] || { usage; exit 2; }
      FONTS_DIR=$2
      shift
      ;;
    --licenses-dir)
      [ $# -ge 2 ] || { usage; exit 2; }
      LICENSES_DIR=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage
      die 2 "unknown option: $1"
      ;;
    *)
      [ -z "$OUT" ] || { usage; exit 2; }
      OUT=$1
      ;;
  esac
  shift
done
[ -n "$OUT" ] || { usage; exit 2; }

command -v jq >/dev/null 2>&1 || die 2 "jq is required (it ships with macOS 15 and GitHub's macOS runners)"
command -v cargo >/dev/null 2>&1 || die 2 "cargo is required"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/notices.XXXXXX") || die 1 "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

(cd "$ROOT" && cargo metadata --format-version 1 --filter-platform "$TRIPLE" --locked) \
  >"$TMP/metadata.json" || die 1 "cargo metadata failed"

# One line per linked crate: name, version, licence, licence file, manifest
# dir, separated by the unit separator \037 (a tab is IFS white space, so
# read would merge an empty field into the next one). The walk follows only normal dependency edges (a
# dep_kinds entry with kind null), so dev-only and build-only crates, and
# whatever only they pull in, are left out.
# shellcheck disable=SC2016
JQ_LINKED='
  . as $m
  | ($m.workspace_members) as $members
  | ($m.resolve.nodes
      | map({key: .id,
             value: [.deps[] | select(any(.dep_kinds[]; .kind == null)) | .pkg]})
      | from_entries) as $g
  | def walk_from($seen):
      ($seen + [$seen[] | ($g[.] // [])[]] | unique) as $next
      | if ($next | length) == ($seen | length) then $seen else walk_from($next) end;
  [$m.packages[] | select(.name == $root and (.id as $i | $members | index($i))) | .id] as $roots
  | if ($roots | length) == 0 then error("no workspace member named " + $root) else . end
  | walk_from($roots) as $linked
  | [$m.packages[]
      | select(.id as $i | ($linked | index($i)) and ($members | index($i) | not))]
  | sort_by(.name, .version)[]
  | [.name, .version, (.license // ""), (.license_file // ""),
     (.manifest_path | sub("/[^/]*$"; ""))]
  | join("\u001f")
'
jq -r --arg root "$ROOT_CRATE" "$JQ_LINKED" "$TMP/metadata.json" >"$TMP/linked.txt" ||
  die 1 "could not read the cargo metadata"

RULE='================================================================================'
SUB='--------------------------------------------------------------------------------'

# Appends file $1 to the notices under the heading $2.
add_text() {
  {
    printf '%s\n\n' "-- $2 --"
    cat "$1"
    printf '\n\n'
  } >>"$TMP/out"
}

# Lists a crate's own licence files (one per line, sorted).
own_files() {
  local dir="$1" lf="$2"
  {
    find "$dir" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'LICENCE*' \
      -o -iname 'COPYING*' -o -iname 'NOTICE*' \) 2>/dev/null
    if [ -n "$lf" ] && [ -f "$dir/$lf" ]; then printf '%s\n' "$dir/$lf"; fi
  } | sort -u
}

{
  printf 'Third-party notices for Open Memex\n\n'
  printf 'Open Memex and memex include the third-party software listed below.\n'
  printf 'Dart and Flutter package notices are in the app bundle'"'"'s NOTICES file,\n'
  printf 'which Flutter generates.\n\n'
  printf '%s\n' "$RULE"
  printf 'Rust crates linked into memex\n'
  printf '%s\n\n' "$RULE"
} >"$TMP/out"

missing=""
count=0
SEP=$(printf '\037')
while IFS="$SEP" read -r name version license lf dir; do
  [ -n "$name" ] || continue
  own_files "$dir" "$lf" >"$TMP/files"
  if [ ! -s "$TMP/files" ] && [ -d "$LICENSES_DIR/$name" ]; then
    find "$LICENSES_DIR/$name" -maxdepth 1 -type f ! -name SOURCE | sort >"$TMP/files"
  fi
  if [ ! -s "$TMP/files" ]; then
    missing="$missing $name $version;"
    continue
  fi
  {
    printf '%s\n' "$SUB"
    printf '%s %s\n' "$name" "$version"
    if [ -n "$license" ]; then
      printf 'License: %s\n' "$license"
    else
      printf 'License: see %s\n' "${lf:-the text below}"
    fi
    printf '%s\n\n' "$SUB"
  } >>"$TMP/out"
  while IFS= read -r f; do
    add_text "$f" "$(basename "$f")"
  done <"$TMP/files"
  count=$((count + 1))
done <"$TMP/linked.txt"

if [ -n "$missing" ]; then
  printf 'notices: no licence text found for crate%s\n' "$missing" >&2
  printf 'notices: add its upstream licence under %s/<crate>/ with a SOURCE file\n' \
    "scripts/release/third_party/licenses" >&2
  exit 1
fi
[ "$count" -gt 0 ] || die 1 "no linked crates found for $ROOT_CRATE"

# onnxruntime.
for f in LICENSE ThirdPartyNotices.txt; do
  [ -s "$ORT_DIR/$f" ] || die 1 "onnxruntime notices missing: scripts/release/third_party/onnxruntime/$f"
done
{
  printf '%s\n' "$RULE"
  printf 'ONNX Runtime (statically linked into memex through the ort crate)\n'
  printf '%s\n\n' "$RULE"
} >>"$TMP/out"
add_text "$ORT_DIR/LICENSE" "onnxruntime LICENSE"
add_text "$ORT_DIR/ThirdPartyNotices.txt" "onnxruntime ThirdPartyNotices.txt"

# Fonts.
find "$FONTS_DIR" -maxdepth 1 -type f -name 'OFL-*.txt' 2>/dev/null | sort >"$TMP/fonts"
[ -s "$TMP/fonts" ] || die 1 "no font licences (OFL-*.txt) in the fonts directory"
{
  printf '%s\n' "$RULE"
  printf 'Fonts bundled with the app (SIL Open Font License 1.1)\n'
  printf '%s\n\n' "$RULE"
} >>"$TMP/out"
while IFS= read -r f; do
  add_text "$f" "$(basename "$f")"
done <"$TMP/fonts"

cp "$TMP/out" "$OUT" || die 1 "cannot write the notices file"
printf 'notices: %s crates, onnxruntime and %s font licences\n' "$count" \
  "$(wc -l <"$TMP/fonts" | tr -d ' ')" >&2
exit 0
