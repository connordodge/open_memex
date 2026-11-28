#!/usr/bin/env bash
# generate_appcast.sh: inserts or refreshes one Release's <item> in the
# Appcast (Spec #31 reqs 1-3, D12, D21). The release workflow's `appcast` job
# runs it; it only rewrites the given appcast.xml. Committing and pushing
# gh-pages is the caller's job.
#
# Usage:
#   scripts/release/generate_appcast.sh --version <x.y.z> \
#     --input <appcast-input dir> --appcast <gh-pages checkout>/appcast.xml
#
# Run it from the tag's checkout root: like check-version.sh it reads these
# relative to the CURRENT DIRECTORY:
#   - app/pubspec.yaml: `version: <x.y.z>+<build>`; <x.y.z> must equal
#     --version and <build> becomes sparkle:version;
#   - release-notes/v<x.y.z>.md: the raw notes, written byte for byte into
#     <description> as CDATA (any `]]>` split as `]]]]><![CDATA[>`);
#   - app/macos/Runner.xcodeproj/project.pbxproj: MACOSX_DEPLOYMENT_TARGET,
#     which becomes sparkle:minimumSystemVersion (every configuration must
#     agree).
# --input holds Open-Memex-<x.y.z>-arm64.dmg.edsig (the base64 EdDSA
# signature) and Open-Memex-<x.y.z>-arm64.dmg.length (the DMG's byte count),
# one line each, as build.sh writes them.
#
# The item is keyed on sparkle:shortVersionString (trimmed, exact match): an
# item for <x.y.z> is replaced in place, a new version goes first in the
# channel, and every other item is kept as it is, with elements this script
# does not know. The Release URLs always name connordodge/open_memex.
#
# Exit 0 on success, 2 on a usage error, 1 when an input is missing or bad.
# Every failure prints the problem on stderr and leaves --appcast untouched.
# The Appcast and the notes are data: nothing in them is ever run.

set -euo pipefail

usage() {
  printf 'generate_appcast: %s\n' "$1" >&2
  printf 'usage: scripts/release/generate_appcast.sh --version <x.y.z> --input <dir> --appcast <file>\n' >&2
  exit 2
}

fail() {
  printf 'generate_appcast: %s\n' "$1" >&2
  exit 1
}

VERSION=""
INPUT=""
APPCAST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version | --input | --appcast)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case "$1" in
        --version) VERSION=$2 ;;
        --input) INPUT=$2 ;;
        --appcast) APPCAST=$2 ;;
      esac
      shift 2
      ;;
    *) usage "unknown argument $1" ;;
  esac
done

[ -n "$VERSION" ] || usage 'missing --version'
[ -n "$INPUT" ] || usage 'missing --input'
[ -n "$APPCAST" ] || usage 'missing --appcast'
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$VERSION" =~ $VERSION_RE ]] || usage "--version $VERSION is not x.y.z (no leading v)"

# ---------------------------------------------------------------------------
# Inputs. Every check runs before the Appcast is read or written.

NOTES=release-notes/v$VERSION.md
[ -f "$NOTES" ] || fail "$NOTES not found"

DMG=Open-Memex-$VERSION-arm64.dmg
EDSIG_FILE=$INPUT/$DMG.edsig
LENGTH_FILE=$INPUT/$DMG.length
[ -f "$EDSIG_FILE" ] || fail "$EDSIG_FILE not found"
[ -f "$LENGTH_FILE" ] || fail "$LENGTH_FILE not found"
# $(...) drops the trailing newline build.sh writes.
SIGNATURE=$(cat "$EDSIG_FILE")
LENGTH=$(cat "$LENGTH_FILE")
SIG_RE='^[A-Za-z0-9+/]+={0,2}$'
[[ "$SIGNATURE" =~ $SIG_RE ]] || fail "$EDSIG_FILE is empty or not a base64 signature"
LENGTH_RE='^[0-9]+$'
[[ "$LENGTH" =~ $LENGTH_RE ]] || fail "$LENGTH_FILE is not a whole number of bytes: $LENGTH"

PUBSPEC=app/pubspec.yaml
[ -f "$PUBSPEC" ] || fail "$PUBSPEC not found"
# The top-level `version:` key (column 0), as check-version.sh reads it.
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
[ "${pub_raw%%+*}" = "$VERSION" ] || fail "$PUBSPEC version '$pub_raw' does not match $VERSION"
BUILD_RE='^[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)$'
[[ "$pub_raw" =~ $BUILD_RE ]] || fail "$PUBSPEC version $pub_raw has no +<build number>"
BUILD=${BASH_REMATCH[1]}

PBXPROJ=app/macos/Runner.xcodeproj/project.pbxproj
[ -f "$PBXPROJ" ] || fail "$PBXPROJ not found"
targets=$(sed -n -E 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = "?([0-9]+(\.[0-9]+)*)"?;[[:space:]]*$/\1/p' "$PBXPROJ" | sort -u)
[ -n "$targets" ] || fail "$PBXPROJ sets no MACOSX_DEPLOYMENT_TARGET"
[ "$(printf '%s\n' "$targets" | wc -l | tr -d ' ')" = 1 ] ||
  fail "$PBXPROJ sets more than one MACOSX_DEPLOYMENT_TARGET: $(printf '%s' "$targets" | tr '\n' ' ')"
MIN_SYSTEM=$targets

[ -f "$APPCAST" ] || fail "$APPCAST not found (is the gh-pages checkout there?)"

# ---------------------------------------------------------------------------
# The XML edit, in Python's standard library (minidom keeps every other item,
# its CDATA and its unknown elements as written). Values go in through the
# environment, never through the script text.

APPCAST="$APPCAST" \
  NOTES="$NOTES" \
  VERSION="$VERSION" \
  BUILD="$BUILD" \
  SIGNATURE="$SIGNATURE" \
  LENGTH="$LENGTH" \
  MIN_SYSTEM="$MIN_SYSTEM" \
  python3 -I - <<'PY'
import os
import stat
import sys
import tempfile
from xml.dom import minidom
from xml.parsers.expat import ExpatError

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASES = "https://github.com/connordodge/open_memex/releases"

appcast = os.environ["APPCAST"]
version = os.environ["VERSION"]


def fail(message):
    print("generate_appcast: " + message, file=sys.stderr)
    sys.exit(1)


with open(os.environ["NOTES"], encoding="utf-8", newline="") as f:
    notes = f.read()

try:
    doc = minidom.parse(appcast)
except ExpatError as e:
    fail("%s is not well-formed XML: %s" % (appcast, e))

root = doc.documentElement
if root.getAttribute("xmlns:sparkle") != SPARKLE:
    fail("%s does not declare xmlns:sparkle=\"%s\" on its root" % (appcast, SPARKLE))


def children(node, local, ns=None):
    return [
        c
        for c in node.childNodes
        if c.nodeType == c.ELEMENT_NODE and c.localName == local and c.namespaceURI == ns
    ]


def text_of(node):
    return "".join(
        c.data for c in node.childNodes if c.nodeType in (c.TEXT_NODE, c.CDATA_SECTION_NODE)
    )


channels = children(root, "channel")
if len(channels) != 1:
    fail("%s must hold exactly one <channel>, found %d" % (appcast, len(channels)))
channel = channels[0]


def short_version(item):
    return [text_of(s).strip() for s in children(item, "shortVersionString", SPARKLE)]


def cdata_sections(text):
    # A section may not hold "]]>": end one after "]]" and start the next
    # with ">", which serializes as "]]]]><![CDATA[>".
    parts = text.split("]]>")
    sections = [parts[0]]
    for part in parts[1:]:
        sections[-1] += "]]"
        sections.append(">" + part)
    return sections


INDENT = "\n      "
item = doc.createElement("item")


def add(child):
    item.appendChild(doc.createTextNode(INDENT))
    item.appendChild(child)


def element(name, value=None, ns=None):
    e = doc.createElementNS(ns, name) if ns else doc.createElement(name)
    if value is not None:
        e.appendChild(doc.createTextNode(value))
    return e


add(element("title", "Open Memex " + version))
add(element("sparkle:version", os.environ["BUILD"], SPARKLE))
add(element("sparkle:shortVersionString", version, SPARKLE))
add(element("sparkle:minimumSystemVersion", os.environ["MIN_SYSTEM"], SPARKLE))
description = element("description")
for section in cdata_sections(notes):
    description.appendChild(doc.createCDATASection(section))
add(description)
add(element("link", "%s/tag/v%s" % (RELEASES, version)))
enclosure = element("enclosure")
enclosure.setAttribute("url", "%s/download/v%s/Open-Memex-%s-arm64.dmg" % (RELEASES, version, version))
enclosure.setAttributeNS(SPARKLE, "sparkle:edSignature", os.environ["SIGNATURE"])
enclosure.setAttribute("length", os.environ["LENGTH"])
enclosure.setAttribute("type", "application/octet-stream")
add(enclosure)
item.appendChild(doc.createTextNode("\n    "))

items = children(channel, "item")
same = [i for i in items if version in short_version(i)]
if same:
    # Replace this version's item where it stands; drop any duplicates.
    channel.replaceChild(item, same[0])
    for extra in same[1:]:
        before = extra.previousSibling
        if before is not None and before.nodeType == before.TEXT_NODE and not before.data.strip():
            channel.removeChild(before)
        channel.removeChild(extra)
elif items:
    # Newest first: before the first item, after the channel metadata.
    channel.insertBefore(item, items[0])
    channel.insertBefore(doc.createTextNode("\n    "), items[0])
else:
    last = channel.lastChild
    if last is not None and last.nodeType == last.TEXT_NODE and not last.data.strip():
        channel.insertBefore(doc.createTextNode("\n    "), last)
        channel.insertBefore(item, last)
    else:
        channel.appendChild(doc.createTextNode("\n    "))
        channel.appendChild(item)
        channel.appendChild(doc.createTextNode("\n  "))

out = '<?xml version="1.0" encoding="utf-8"?>\n' + "".join(n.toxml() + "\n" for n in doc.childNodes)
try:
    minidom.parseString(out.encode("utf-8"))
except ExpatError as e:
    fail("the new %s would not be well-formed XML (%s); the notes may hold a character XML forbids" % (appcast, e))

directory = os.path.dirname(os.path.abspath(appcast))
mode = stat.S_IMODE(os.stat(appcast).st_mode)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".appcast.", suffix=".tmp")
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(out)
    os.chmod(tmp, mode)
    os.replace(tmp, appcast)
except BaseException:
    os.unlink(tmp)
    raise

print("generate_appcast: wrote %s+%s to %s" % (version, os.environ["BUILD"], appcast), file=sys.stderr)
PY
