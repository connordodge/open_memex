#!/usr/bin/env bash
# check-version.sh: checks that a release tag matches the checkout's versions
# and release notes (Spec #367, requirement 24).
#
# Usage:
#   scripts/release/check-version.sh <tag>
#
# Run it from the repo root: it reads app/pubspec.yaml, Cargo.toml and
# release-notes/ relative to the CURRENT DIRECTORY, not to this script's own
# location. The release workflow calls it from the checkout root.
#
# Exit 0 only when all of these hold:
#   - <tag> is v<x.y.z> (digits only, three parts);
#   - <x.y.z> equals the top-level `version:` in app/pubspec.yaml before any
#     `+<build>`;
#   - <x.y.z> equals `version` in Cargo.toml's [workspace.package] table;
#   - release-notes/v<x.y.z>.md exists, with non-empty `## Highlights`,
#     `## Upgrade` and `## Requirements` sections (a section runs from its
#     heading to the next `#` or `##` heading; white space alone is empty);
#   - the `## Upgrade` section says `No vault changes` or `schema V<n>`.
#
# Otherwise exit 1 and print one line per failed condition on stderr. A
# malformed tag stops the other checks, since there is no version to compare.

set -u

fail_count=0

fail() {
  printf 'check-version: %s\n' "$1" >&2
  fail_count=$((fail_count + 1))
}

if [ $# -ne 1 ]; then
  fail 'usage: scripts/release/check-version.sh <tag>, where <tag> is v<x.y.z>'
  exit 1
fi

TAG=$1
TAG_RE='^v[0-9]+\.[0-9]+\.[0-9]+$'
if ! [[ "$TAG" =~ $TAG_RE ]]; then
  fail "tag $TAG is not v<x.y.z>"
  exit 1
fi
VERSION=${TAG#v}

# ---------------------------------------------------------------------------
# app/pubspec.yaml: the top-level `version:` key (column 0), not a nested
# dependency `version:`.

PUBSPEC=app/pubspec.yaml
if [ ! -f "$PUBSPEC" ]; then
  fail "$PUBSPEC not found"
else
  pub_raw=$(awk '
    { sub(/\r$/, "") }
    /^version:/ {
      v = $0
      sub(/^version:[ \t]*/, "", v)
      sub(/[ \t]+#.*$/, "", v)
      gsub(/["\047]/, "", v)
      sub(/[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$PUBSPEC")
  if [ -z "$pub_raw" ]; then
    fail "$PUBSPEC has no top-level version"
  elif [ "${pub_raw%%+*}" != "$VERSION" ]; then
    fail "$PUBSPEC version $pub_raw does not match $TAG"
  fi
fi

# ---------------------------------------------------------------------------
# Cargo.toml: `version` inside the [workspace.package] table only.

CARGO=Cargo.toml
if [ ! -f "$CARGO" ]; then
  fail "$CARGO not found"
else
  cargo_raw=$(awk '
    { sub(/\r$/, "") }
    /^[ \t]*\[/ {
      h = $0
      gsub(/[ \t]/, "", h)
      sub(/#.*$/, "", h)
      in_table = (h == "[workspace.package]")
      next
    }
    in_table && /^[ \t]*version[ \t]*=/ {
      v = $0
      sub(/^[^=]*=[ \t]*/, "", v)
      sub(/[ \t]*#.*$/, "", v)
      gsub(/["\047]/, "", v)
      sub(/[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$CARGO")
  if [ -z "$cargo_raw" ]; then
    fail "$CARGO has no [workspace.package] version"
  elif [ "$cargo_raw" != "$VERSION" ]; then
    fail "$CARGO [workspace.package] version $cargo_raw does not match $TAG"
  fi
fi

# ---------------------------------------------------------------------------
# release-notes/v<x.y.z>.md.

NOTES=release-notes/v$VERSION.md

# Prints the body of the section headed exactly $1 (trailing white space
# ignored) in file $2. Exits 3 when there is no such heading.
section_body() {
  awk -v heading="$1" '
    { sub(/\r$/, "") }
    in_section && /^##?[ \t]/ { exit }
    in_section { print; next }
    {
      line = $0
      sub(/[ \t]+$/, "", line)
      if (line == heading) { in_section = 1; found = 1 }
    }
    END { exit found ? 0 : 3 }
  ' "$2"
}

has_text() {
  printf '%s' "$1" | grep -q '[^[:space:]]'
}

if [ ! -f "$NOTES" ]; then
  fail "$NOTES not found"
else
  upgrade_body=""
  for heading in '## Highlights' '## Upgrade' '## Requirements'; do
    body=$(section_body "$heading" "$NOTES")
    rc=$?
    if [ "$rc" -eq 3 ]; then
      fail "$NOTES: section $heading is missing"
    elif [ "$rc" -ne 0 ]; then
      fail "$NOTES: could not read section $heading"
    elif ! has_text "$body"; then
      fail "$NOTES: section $heading is empty"
    fi
    [ "$heading" = '## Upgrade' ] && upgrade_body=$body
  done
  if ! printf '%s\n' "$upgrade_body" | grep -qF 'No vault changes' &&
    ! printf '%s\n' "$upgrade_body" | grep -qE 'schema V[0-9]+'; then
    fail "$NOTES: ## Upgrade must say No vault changes or schema V<n>"
  fi
fi

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
printf 'check-version: %s matches %s, %s and %s\n' "$TAG" "$PUBSPEC" "$CARGO" "$NOTES"
exit 0
