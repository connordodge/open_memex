#!/usr/bin/env bash
# image-tags.sh <x.y.z>
#
# Prints the image tags a release gets, one per line, from the v* tags in the
# current git repo (it needs full tag history: fetch-depth 0 in CI):
#
#   <x.y.z>   always
#   <x.y>     when v<x.y.z> is the highest v<x.y>.* tag
#   latest    when v<x.y.z> is the highest v* tag
#
# A malformed version (not three dot-separated digit groups) prints nothing on
# stdout and exits 2. Runs on macOS bash 3.2 and Ubuntu: version order comes
# from `git tag --sort=-v:refname`, not a GNU-only sort flag.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: scripts/docker/image-tags.sh <x.y.z>" >&2
  exit 2
fi
VERSION=$1
RELEASE_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if ! [[ "$VERSION" =~ $RELEASE_RE ]]; then
  echo "image-tags.sh: '$VERSION' is not a version <x.y.z> (digits only)" >&2
  exit 2
fi
MINOR=${VERSION%.*}

# The highest release tag (v<d>.<d>.<d> only; other v* tags are ignored).
highest_all=$(git tag --list 'v*' --sort=-v:refname \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)
# The highest release tag of this minor.
highest_minor=$(git tag --list "v$MINOR.*" --sort=-v:refname \
  | grep -E "^v${MINOR//./\\.}\\.[0-9]+\$" | head -n 1 || true)

echo "$VERSION"
if [ "$highest_minor" = "v$VERSION" ]; then
  echo "$MINOR"
fi
if [ "$highest_all" = "v$VERSION" ]; then
  echo latest
fi
