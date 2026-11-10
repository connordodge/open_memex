#!/usr/bin/env bash
# leak-check.sh: the Leak check (Spec #367, requirements 7-10).
#
# Looks for private data in text, a diff, a directory tree, a git history or
# a release artifact. A hit on any one rule is a leak:
#   (a) deny-list  a private literal from --patterns <file> and/or the
#                  LEAK_PATTERNS environment variable (newline-separated,
#                  blank lines ignored). An entry containing @ is an email and
#                  matches case-insensitively; any other entry is a path and
#                  matches case-sensitively. Entries are literals, never
#                  regular expressions.
#   (b) HOME       the running machine's $HOME path.
#   (c) home-path  a /Users/<name>/ or /home/<name>/ path whose <name> is not
#                  a placeholder name in scripts/leak-allow.txt. A <name> is
#                  letters, digits, . _ - and non-ASCII bytes, with inner
#                  spaces allowed.
# Text that starts with a third-party prefix from leak-allow.txt is exempt
# from rules (b) and (c), never from rule (a).
#
# Usage:
#   leak-check.sh [options] --text <file|->      text (a PR body, a file)
#   leak-check.sh [options] --diff <file|->      added lines of a unified diff
#   leak-check.sh [options] --tree <dir>         every file under a directory
#   leak-check.sh [options] --history <git-dir>  every reachable blob, file
#                                               path, commit and tag object
#   leak-check.sh [options] --artifact <path>... an .app, binary, zip or DMG,
#                                               and the zips and DMGs inside
# Options (in any order):
#   --patterns <file>       add the deny-list entries in <file> (repeatable)
#   --allow-empty-patterns  run rules (b) and (c) when the deny-list is empty
#
# Output: one line per hit and rule on stdout,
#   LEAK <file-or-ref>:<line-or-offset> <rule> <excerpt>
# where every match in the excerpt (and in the location) is replaced by
# [redacted]. Binary content is searched as raw bytes; a hit in a line that
# holds a NUL byte reports its byte offset instead of a line number. The
# leaked text never appears in stdout or stderr.
# A hit in a file's own name is reported as "<path> (name):1" (--tree and
# --artifact: every entry below the root; --diff: every added, renamed or
# copied file), and one in a symlink's target as "<link> (symlink):1".
# A symlink given as the --tree or --artifact root is read through; symlinks
# below it are never followed. --diff cannot see a binary file's bytes, so it
# prints "LEAK WARN: binary file not scanned: <path>" on stderr for each one
# that is not deleted, with any hit in <path> shown as [redacted]. The warning
# leaves the exit status unchanged; a hit in the binary file's path is still
# a LEAK line ("<path> (name):1") and exit 1. Scanning the bytes is the
# caller's job (--tree or --artifact on the merged tree). --diff strips colour
# codes, and a scan fails (exit 2) on input it cannot read as a plain unified
# diff: no diff header or hunk at all, a word diff or a combined diff.
# --history reads objects as stored, ignoring refs/replace, gitattributes and
# filters, and refuses a repository with an info/grafts file. --artifact
# fails on a zip whose entry names collide.
#
# Exit status: 0 clean, 1 at least one leak, 2 usage error (unknown mode,
# missing input path or patterns file, an empty deny-list without
# --allow-empty-patterns) or a scan that could not complete.
#
# Tools: bash (3.2 is enough), git, grep, unzip, hdiutil and the POSIX
# basics (awk, tr, find, od, mktemp). It installs nothing.

export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ALLOW_FILE="$SCRIPT_DIR/leak-allow.txt"

TMP=""
MOUNTS=""
FOUND=0
FAILED=0
SEQ=0

cleanup() {
  local m kept=0
  if [ -n "$MOUNTS" ]; then
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      hdiutil detach "$m" -quiet </dev/null >/dev/null 2>&1 ||
        hdiutil detach "$m" -force -quiet </dev/null >/dev/null 2>&1 ||
        kept=1
    done <<EOF
$MOUNTS
EOF
  fi
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then
    if [ "$kept" = 0 ]; then
      rm -rf "$TMP"
    else
      printf 'leak-check: a DMG could not be detached; kept its temp dir\n' >&2
    fi
  fi
}
trap cleanup EXIT
trap 'exit 2' INT TERM HUP

usage() {
  cat >&2 <<'EOF'
usage: leak-check.sh [--patterns <file>]... [--allow-empty-patterns] MODE
  MODE is one of:
    --text <file|->       text (a PR body, a file)
    --diff <file|->       the added lines of a unified diff
    --tree <dir>          every file under a directory
    --history <git-dir>   every reachable blob, file path, commit and tag
    --artifact <path>...  an .app, binary, zip or DMG, and archives inside
  Deny-list entries also come from LEAK_PATTERNS (newline-separated).
  --diff cannot see a binary file's bytes: it prints
    LEAK WARN: binary file not scanned: <path, hits [redacted]>
  on stderr and leaves the exit status unchanged (a hit in that path is
  still a LEAK line and exit 1). Scan the file itself with --tree/--artifact.
  --diff exits 2 on input that is not a plain unified diff (colour is fine).
  Exit status: 0 clean, 1 leak, 2 usage error or incomplete scan.
EOF
}

die() {
  printf 'leak-check: %s\n' "$1" >&2
  exit 2
}

warn() {
  printf 'leak-check: %s\n' "$1" >&2
}

# ---------------------------------------------------------------------------
# awk programs. Records reaching MATCHER look like grep -H -n -b --null output
# with NUL turned into \001:  <label>\001<line>:<byte-offset>:<content>
# (a byte offset of -1 means "no offset; report the line").

MATCHER='
function loadlist(f, arr,    n, l) {
  n = 0
  if (f == "") return 0
  while ((getline l < f) > 0) arr[++n] = l
  close(f)
  return n
}
function addI(a, b) { nI++; IA[nI] = a; IB[nI] = b }
function findlit(s, e,    len, start, k, pos, cnt) {
  len = length(e)
  if (len == 0) return 0
  start = 1; cnt = 0
  while ((k = index(substr(s, start), e)) > 0) {
    pos = start + k - 1
    addI(pos, pos + len - 1)
    cnt++
    start = pos + len
  }
  return cnt
}
function pad(n,    r) {
  if (n in PAD) return PAD[n]
  r = ""
  while (length(r) < n) r = r "\002"
  PAD[n] = r
  return r
}
# Overwrites every third-party prefix with \002 bytes (same length), so
# rules b and c cannot match inside it and positions still line up.
function mask(s,    i, e, len, out, start, k, pos) {
  for (i = 1; i <= nx; i++) {
    e = X[i]; len = length(e)
    if (len == 0) continue
    out = ""; start = 1
    while ((k = index(substr(s, start), e)) > 0) {
      pos = start + k - 1
      out = out substr(s, start, pos - start) pad(len)
      start = pos + len
    }
    s = out substr(s, start)
  }
  return s
}
# Collects the hit intervals of s in IA/IB; sets hA, hB, hC per rule.
function scan(s,    i, M, LS, start, t, ns, name, abs) {
  nI = 0; hA = 0; hB = 0; hC = 0
  for (i = 1; i <= np; i++) if (findlit(s, P[i])) hA = 1
  if (ne) {
    LS = tolower(s)
    for (i = 1; i <= ne; i++) if (findlit(LS, E[i])) hA = 1
  }
  M = nx ? mask(s) : s
  for (i = 1; i <= nh; i++) if (findlit(M, H[i])) hB = 1
  start = 1
  while (1) {
    t = substr(M, start)
    if (!match(t, /\/(Users|home)\/[^\/]+\//)) break
    ns = (substr(t, RSTART + 1, 1) == "U") ? 7 : 6
    name = substr(t, RSTART + ns, RLENGTH - ns - 1)
    if (isname(name) && !(name in ALLOW)) {
      abs = start + RSTART - 1 + ns
      addI(abs, abs + length(name) - 1)
      hC = 1
    }
    # Go on from the slash before the name, so a home path that starts
    # inside this one (its name being Users or home) is found too.
    start = start + RSTART + ns - 2
  }
  return hA || hB || hC
}
# A user name: letters, digits, . _ - and non-ASCII bytes, with inner (never
# leading or trailing) spaces. Anything else (<name>, $USER, *) is not one.
function isname(n,    r, i) {
  if (substr(n, 1, 1) == " " || substr(n, length(n)) == " ") return 0
  r = n
  gsub(/[A-Za-z0-9._ -]/, "", r)
  for (i = 1; i <= length(r); i++) if (!(substr(r, i, 1) in HI)) return 0
  return 1
}
# s with every interval from the last scan replaced by [redacted]; sets
# first to the position of the first hit.
function render(s,    i, j, a, b, m, out, pos) {
  for (i = 2; i <= nI; i++) {
    a = IA[i]; b = IB[i]; j = i - 1
    while (j >= 1 && IA[j] > a) { IA[j + 1] = IA[j]; IB[j + 1] = IB[j]; j-- }
    IA[j + 1] = a; IB[j + 1] = b
  }
  m = 0
  for (i = 1; i <= nI; i++) {
    if (m && IA[i] <= MB[m] + 1) {
      if (IB[i] > MB[m]) MB[m] = IB[i]
    } else {
      m++; MA[m] = IA[i]; MB[m] = IB[i]
    }
  }
  first = m ? MA[1] : 1
  out = ""; pos = 1
  for (i = 1; i <= m; i++) {
    out = out substr(s, pos, MA[i] - pos) "[redacted]"
    pos = MB[i] + 1
  }
  return out substr(s, pos)
}
function excerpt(r,    p, st, ex) {
  p = index(r, "[redacted]")
  st = p - 60
  if (st < 1) st = 1
  ex = substr(r, st, 200)
  gsub(/[^ -~]/, ".", ex)
  if (st > 1) ex = "..." ex
  if (st + 200 <= length(r)) ex = ex "..."
  return ex
}
function fixlabel(l) {
  if (strip != "" && substr(l, 1, length(strip)) == strip)
    l = put substr(l, length(strip) + 1)
  if (l in MAP) l = MAP[l]
  if (scan(l)) l = render(l)
  gsub(/[^ -~]/, "?", l)
  return l
}
BEGIN {
  split("", P); split("", E); split("", H); split("", X); split("", N)
  for (i = 128; i < 256; i++) HI[sprintf("%c", i)] = 1
  np = loadlist(ENVIRON["LK_PATHS"], P)
  ne = loadlist(ENVIRON["LK_EMAILS"], E)
  for (i = 1; i <= ne; i++) E[i] = tolower(E[i])
  nh = loadlist(ENVIRON["LK_HOMES"], H)
  nx = loadlist(ENVIRON["LK_PREFIXES"], X)
  nn = loadlist(ENVIRON["LK_NAMES"], N)
  for (i = 1; i <= nn; i++) ALLOW[N[i]] = 1
  strip = ENVIRON["LK_STRIP"]; put = ENVIRON["LK_PUT"]
  mapf = ENVIRON["LK_MAP"]
  if (mapf != "") {
    while ((getline l < mapf) > 0) {
      k = index(l, "\t")
      if (k) MAP[substr(l, 1, k - 1)] = substr(l, k + 1)
    }
    close(mapf)
  }
  redactonly = (ENVIRON["LK_MODE"] == "redact")
  found = 0
}
redactonly {
  l = $0
  if (scan(l)) l = render(l)
  gsub(/[^ -~]/, "?", l)
  print l
  next
}
{
  rec = $0
  k = index(rec, "\001")
  if (!k) next
  label = substr(rec, 1, k - 1); rest = substr(rec, k + 1)
  k = index(rest, ":"); ln = substr(rest, 1, k - 1); rest = substr(rest, k + 1)
  k = index(rest, ":"); off = substr(rest, 1, k - 1); line = substr(rest, k + 1)
  if (!scan(line)) next
  a = hA; b = hB; c = hC
  ex = excerpt(render(line))
  if (off + 0 >= 0 && index(line, "\001") > 0) {
    num = off + first - 1; kind = "[byte offset] "
  } else {
    num = ln; kind = ""
  }
  where = fixlabel(label)
  if (a) print "LEAK " where ":" num " deny-list " kind ex
  if (b) print "LEAK " where ":" num " HOME " kind ex
  if (c) print "LEAK " where ":" num " home-path " kind ex
  found = 1
}
END { if (!redactonly) exit found }
'

# The added lines of a unified diff, labelled <new file>:<new line>, and the
# path of every added, renamed or copied file, labelled "<path> (name):1".
# The new path of a binary file (whose bytes a diff does not show) is also
# scanned as a "(name)" record, added or not, and goes to the file LK_BINLIST.
DIFF_PRODUCER='
function unq(s) {
  if (length(s) > 1 && substr(s, 1, 1) == "\"" && substr(s, length(s)) == "\"")
    s = substr(s, 2, length(s) - 2)
  return s
}
function hdr(s, pre) {
  s = substr(s, 5)
  sub(/\t.*$/, "", s)
  s = unq(s)
  if (substr(s, 1, 2) == pre) s = substr(s, 3)
  return s
}
function lastidx(s, t,    k, at) {
  at = 0
  while ((k = index(substr(s, at + 1), t)) > 0) at += k
  return at
}
function emit(text) { printf "%s\001%d:-1:%s\n", file, nl, text; nl++ }
function name(p) {
  if (p == "" || p == "/dev/null" || (p in seen)) return
  seen[p] = 1
  printf "%s (name)\0011:-1:%s\n", p, p
}
function bin(p) {
  if (p == "" || p == "/dev/null" || (p in binseen)) return
  binseen[p] = 1
  name(p)
  print p > binf
}
# Ends the "diff --git" section in progress.
function flush() {
  if (gp != "" && !gdel) {
    if (gnew) name(gp)
    if (gbin) bin(gp)
  }
  gp = ""; gnew = 0; gdel = 0; gbin = 0
}
# The new path of "diff --git <a> <b>" without the usual b/ prefix: both
# halves the same (diff.noprefix), or the same after a one-letter prefix
# (diff.mnemonicPrefix: i/ w/ c/ o/).
function samehalves(s,    n, h, a, b) {
  n = length(s)
  if (n % 2 == 0) return ""
  h = (n - 1) / 2
  if (substr(s, h + 1, 1) != " ") return ""
  a = substr(s, 1, h); b = substr(s, h + 2)
  if (a == b) return b
  if (h > 2 && substr(a, 2, 1) == "/" && substr(b, 2, 1) == "/" && substr(a, 3) == substr(b, 3))
    return substr(b, 3)
  return ""
}
BEGIN {
  file = ENVIRON["LK_DIFFNAME"]; binf = ENVIRON["LK_BINLIST"]
  inh = 0; nl = 1; nc = 0; oc = 0; pnull = 0
  gp = ""; gnew = 0; gdel = 0; gbin = 0
  # bad: 3 a hunk line that is not context, added or removed (a word diff),
  # 4 a combined diff, 5 no diff structure at all. Each fails the scan.
  bad = 0; shape = 0; text = 0
}
{
  # Colour (git diff --color=always, color.ui=always) would hide every line.
  gsub(/\033\[[0-9;]*[A-Za-z]/, "")
  if (!text && $0 ~ /[^ \t\r]/) text = 1
  if (inh) {
    c = substr($0, 1, 1)
    if (c == "+") { emit(substr($0, 2)); nc-- }
    else if (c == "-") { oc-- }
    else if (c == " " || $0 == "") { nl++; nc--; oc-- }
    else if (c == "\\") { }
    else {
      inh = 0
      # Wrong hunk counts may run into the next header; anything else in a
      # hunk is a format this parser cannot read.
      if (substr($0, 1, 5) != "diff " && substr($0, 1, 2) != "@@" && !bad) bad = 3
    }
    if (inh) {
      if (nc <= 0 && oc <= 0) inh = 0
      next
    }
  }
  if (substr($0, 1, 10) == "diff --cc " || substr($0, 1, 16) == "diff --combined " || substr($0, 1, 4) == "@@@ ") {
    bad = 4
    next
  }
  if (substr($0, 1, 11) == "diff --git ") {
    flush()
    shape = 1
    s = substr($0, 12)
    k = lastidx(s, " \"b/")
    if (k) gp = unq(substr(s, k + 1))
    else if ((k = lastidx(s, " b/")) > 0) gp = substr(s, k + 1)
    else gp = samehalves(s)
    if (substr(gp, 1, 2) == "b/") gp = substr(gp, 3)
    next
  }
  if (substr($0, 1, 14) == "new file mode ") { gnew = 1; next }
  if (substr($0, 1, 18) == "deleted file mode ") { gdel = 1; next }
  if (substr($0, 1, 10) == "rename to ") { name(unq(substr($0, 11))); next }
  if (substr($0, 1, 8) == "copy to ") { name(unq(substr($0, 9))); next }
  if ($0 == "GIT binary patch") { gbin = 1; next }
  if (substr($0, 1, 13) == "Binary files " && substr($0, length($0) - 6) == " differ") {
    shape = 1
    if (gp != "") { gbin = 1; next }
    s = substr($0, 14, length($0) - 20)
    k = lastidx(s, " and ")
    if (!k) next
    a = unq(substr(s, 1, k - 1)); f = unq(substr(s, k + 5))
    if (substr(f, 1, 2) == "b/") f = substr(f, 3)
    if (a == "/dev/null") name(f)
    bin(f)
    next
  }
  if (substr($0, 1, 4) == "+++ ") {
    shape = 1
    f = hdr($0, "b/")
    if (f != "/dev/null") { file = f; if (pnull) name(f) }
    pnull = 0
    next
  }
  if (substr($0, 1, 4) == "--- ") {
    f = hdr($0, "a/")
    pnull = (f == "/dev/null")
    if (!pnull) file = f
    next
  }
  if (substr($0, 1, 3) == "@@ ") {
    shape = 1
    oc = 1; nc = 1; nl = 1
    if (match($0, /-[0-9]+(,[0-9]+)?/)) {
      s = substr($0, RSTART + 1, RLENGTH - 1)
      k = index(s, ",")
      if (k) oc = substr(s, k + 1) + 0
    }
    if (match($0, / \+[0-9]+(,[0-9]+)?/)) {
      s = substr($0, RSTART + 2, RLENGTH - 2)
      k = index(s, ",")
      if (k) { nl = substr(s, 1, k - 1) + 0; nc = substr(s, k + 1) + 0 }
      else nl = s + 0
    }
    inh = (nc > 0 || oc > 0)
    next
  }
  # Outside a hunk: still treat a "+" line as added, so a diff with wrong
  # hunk counts cannot hide one.
  if (substr($0, 1, 1) == "+") emit(substr($0, 2))
}
END {
  flush()
  if (!bad && text && !shape) bad = 5
  exit bad
}
'

# git cat-file --batch output (commit and tag objects) as one record per line.
BATCH_PRODUCER='
st == 0 {
  if (NF < 3 || $2 == "missing") next
  lab = $2 " " substr($1, 1, 12); rem = $3 + 1; ln = 0; st = 1
  next
}
{
  ln++
  rem -= length($0) + 1
  printf "%s\001%d:-1:%s\n", lab, ln, $0
  if (rem <= 0) st = 0
}
'

# git log --name-only output as one record per distinct file path. The label
# names the commit, never the path.
PATH_PRODUCER='
substr($0, 1, 1) == "\001" { c = substr($0, 2, 12); next }
$0 == "" { next }
!($0 in seen) { seen[$0] = 1; printf "path in commit %s\0011:-1:%s\n", c, $0 }
'

# find output (one path per line) as one record per entry: the label is the
# path, the content the part of it below the root LK_ROOT.
NAMES_PRODUCER='
BEGIN { root = ENVIRON["LK_ROOT"]; n = length(root) }
substr($0, 1, n) == root { printf "%s (name)\0011:-1:%s\n", $0, substr($0, n + 1) }
'

# ---------------------------------------------------------------------------
# Scanning helpers. Each records hits in FOUND and failures in FAILED.

# Creates a fresh temp dir and sets NEWDIR to it. Never call it inside $(...):
# the counter must live in this shell.
newtmp() {
  SEQ=$((SEQ + 1))
  NEWDIR="$TMP/$1$SEQ"
  mkdir "$NEWDIR" || die "cannot create a temp dir"
}

# Prints a message to stderr with any leak in its argument redacted.
fail_about() {
  local shown
  shown=$(printf '%s\n' "$2" | LK_MODE=redact awk "$MATCHER")
  printf 'leak-check: %s: %s\n' "$1" "$shown" >&2
  FAILED=1
}

# Records the outcome of a "producer | matcher" pipeline: $1 is the producer's
# status (0 and 1 are fine for grep), $2 the matcher's.
note() {
  if [ "$1" -gt 1 ]; then FAILED=1; fi
  case "$2" in
    0) ;;
    1) FOUND=1 ;;
    *) FAILED=1 ;;
  esac
}

# grep every file under $1 (or the file $1) for candidates; labels starting
# with $2 are shown with $3 in its place, then looked up in the map file $4.
scan_files() {
  local s
  grep -r -a -H -n -b -i -F -s -D skip --null -f "$CAND" -- "$1" |
    tr '\000' '\001' |
    LK_STRIP="$2" LK_PUT="$3" LK_MAP="${4:-}" awk "$MATCHER"
  s=("${PIPESTATUS[@]}")
  if [ "${s[0]}" -gt 1 ]; then fail_about 'could not read every file under' "$3"; fi
  note 0 "${s[2]}"
}

# The name of every entry below the directory $1 and the target of every
# symlink in it (neither grep -r nor find -type f reads a link). Labels as in
# scan_files.
scan_names() {
  local s l t
  {
    find "$1" -mindepth 1 -print0 2>/dev/null |
      tr '\n\000' '?\n' |
      LK_ROOT="$1" awk "$NAMES_PRODUCER"
    find "$1" -mindepth 1 -type l -print0 2>/dev/null |
      while IFS= read -r -d '' l; do
        t=$(readlink -- "$l") || { printf '%s (symlink)\0011:-1:\n' "$l"; continue; }
        t=${t//$'\n'/?}
        l=${l//$'\n'/?}
        printf '%s (symlink)\0011:-1:%s\n' "$l" "$t"
      done
  } | LK_STRIP="$2" LK_PUT="$3" awk "$MATCHER"
  s=("${PIPESTATUS[@]}")
  note 0 "${s[1]}"
}

# Sets REAL to $1 with every symlink in it resolved. BSD grep -r and find
# skip a symlink even when it is the path they are given, so a symlinked
# root would otherwise be scanned as empty. Only the root is resolved:
# symlinks below it are never followed.
resolve() {
  local p="$1" t n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    t=$(readlink -- "$p") || return 1
    case "$t" in
      /*) p=$t ;;
      *) p=$(dirname -- "$p")/$t ;;
    esac
  done
  if [ -d "$p" ]; then
    p=$(CDPATH='' cd -P -- "$p" && pwd -P) || return 1
  else
    t=$(CDPATH='' cd -P -- "$(dirname -- "$p")" && pwd -P) || return 1
    p=${t%/}/$(basename -- "$p")
  fi
  REAL=$p
}

# $1 without trailing slashes (but never empty).
noslash() {
  local v="$1"
  while [ "${v%/}" != "$v" ] && [ "${v%/}" != "" ]; do v=${v%/}; done
  printf '%s' "$v"
}

# One file (a regular file, a FIFO or a copy of stdin), shown as $2.
scan_text() {
  local s
  grep -a -H -n -b -i -F -s --null -f "$CAND" -- "$1" |
    tr '\000' '\001' |
    LK_STRIP="$1" LK_PUT="$2" awk "$MATCHER"
  s=("${PIPESTATUS[@]}")
  note "${s[0]}" "${s[2]}"
}

scan_diff() {
  local s bins="$TMP/binaries"
  : >"$bins"
  tr '\000' '\001' <"$1" |
    LK_DIFFNAME="$2" LK_BINLIST="$bins" awk "$DIFF_PRODUCER" |
    awk "$MATCHER"
  s=("${PIPESTATUS[@]}")
  note "${s[1]}" "${s[2]}"
  case "${s[1]}" in
    0) ;;
    3) warn "--diff: a hunk holds a line that is not context, added or removed (a word diff?)" ;;
    4) warn "--diff: combined diffs (diff --cc) are not supported" ;;
    5) warn "--diff: the input is not a unified diff" ;;
    *) warn "--diff: could not parse the diff" ;;
  esac
  # A diff does not show a binary file's bytes: say so (redacted), so the
  # caller can scan the file itself with --text or --tree.
  if [ -s "$bins" ]; then
    LK_MODE=redact awk "$MATCHER" <"$bins" |
      while IFS= read -r l; do
        printf 'LEAK WARN: binary file not scanned: %s\n' "$l" >&2
      done
  fi
}

scan_history() {
  local in="$1" g h s common
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_REPLACE_REF_BASE \
    GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_NAMESPACE GIT_ATTR_SOURCE
  newtmp hist
  h=$NEWDIR
  # Read the objects as stored: git push sends them so, whatever
  # refs/replace or a graft file says. (The replacement objects are still
  # scanned, since refs/replace/* are among --all.)
  export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE="$h/no-grafts"
  if [ -e "$in/.git" ]; then
    g=$(git -C "$in" rev-parse --absolute-git-dir 2>/dev/null)
  else
    g=$(git --git-dir="$in" rev-parse --absolute-git-dir 2>/dev/null)
  fi
  [ -n "$g" ] || die "--history: not a git repository"
  # A linked worktree keeps its objects and info/ in the common dir.
  common=$(git --git-dir="$g" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$common" ] || die "--history: not a git repository"
  if [ -s "$g/info/grafts" ] || [ -s "$common/info/grafts" ]; then
    die "--history: info/grafts is not supported (git replace --convert-graft-file)"
  fi
  mkdir "$h/blobs" || die "cannot create a temp dir"
  # Blobs are checked out through an empty repository that borrows the
  # scanned one's objects, so no gitattributes (info/attributes, the user's
  # or the system's) and no filter or encoding in its config rewrite them.
  git init -q --bare --template= "$h/repo" >/dev/null 2>&1 ||
    die "--history: git init failed"
  mkdir -p "$h/repo/objects/info" &&
    printf '%s\n' "$common/objects" >"$h/repo/objects/info/alternates" ||
    die "cannot create a temp dir"

  git --git-dir="$g" rev-list --all --objects >"$h/revs" ||
    die "--history: git rev-list failed"
  [ -s "$h/revs" ] || return 0
  git --git-dir="$g" cat-file --batch-check='%(objecttype) %(objectname) %(rest)' \
    <"$h/revs" >"$h/objs" || die "--history: git cat-file failed"

  # Every reachable blob, written once to blobs/<sha> through a private index.
  awk '$1 == "blob" { printf "100644 %s\t%s\n", $2, $2 }' "$h/objs" >"$h/idx"
  awk '$1 == "blob" {
    p = $0; sub(/^blob [^ ]* ?/, "", p)
    printf "%s\tblob %s %s\n", $2, substr($2, 1, 12), p
  }' "$h/objs" >"$h/map"
  if [ -s "$h/idx" ]; then
    GIT_INDEX_FILE="$h/index" git --git-dir="$h/repo" --work-tree="$h/blobs" \
      update-index --index-info <"$h/idx" || die "--history: git update-index failed"
    (cd "$h/blobs" && GIT_ATTR_NOSYSTEM=1 GIT_INDEX_FILE="$h/index" \
      git --git-dir="$h/repo" --work-tree=. \
      -c core.attributesFile=/dev/null -c core.autocrlf=false -c core.eol=lf \
      -c core.safecrlf=false -c core.fsmonitor=false checkout-index -a -f) ||
      die "--history: git checkout-index failed"
    scan_files "$h/blobs" "$h/blobs/" "" "$h/map"
  fi

  # Commit and tag objects, raw: author, committer, tagger and message.
  awk '$1 == "commit" || $1 == "tag" { print $2 }' "$h/objs" |
    git --git-dir="$g" cat-file --batch |
    tr '\000' '\001' |
    awk "$BATCH_PRODUCER" |
    awk "$MATCHER"
  s=("${PIPESTATUS[@]}")
  note "${s[1]}" "${s[4]}"

  # Every file path in every reachable tree: each one is added by some
  # commit relative to some parent (or the empty tree, for a root commit),
  # so --root and a diff per merge parent cover them all.
  git --git-dir="$g" -c core.quotePath=false -c log.showSignature=false \
    -c log.showRoot=true -c diff.relative=false \
    log --all --root --diff-merges=separate --no-relative --no-renames \
    --no-ext-diff --no-textconv --no-notes \
    --name-only --format='%x01%H' |
    awk "$PATH_PRODUCER" |
    awk "$MATCHER"
  s=("${PIPESTATUS[@]}")
  note "${s[0]}" "${s[2]}"
}

is_dmg() {
  case "$1" in
    *.dmg | *.DMG | *.Dmg) return 0 ;;
  esac
  return 1
}

is_zip() {
  local magic
  case "$1" in
    *.zip | *.ZIP | *.Zip) return 0 ;;
  esac
  [ "${2:-}" = magic ] || return 1
  magic=$(head -c 4 <"$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$magic" = 504b0304 ]
}

# Scans the zip or DMG $1 (shown as $2) from the inside.
scan_container() {
  local f="$1" label="$2" depth="$3" d want got
  if [ "$depth" -gt 6 ]; then
    fail_about 'archives nested too deep at' "$label"
    return
  fi
  if is_dmg "$f"; then
    command -v hdiutil >/dev/null 2>&1 || { fail_about 'hdiutil is needed for' "$label"; return; }
    newtmp mnt
    d=$NEWDIR
    if hdiutil attach -readonly -nobrowse -noautoopen -noverify \
      -mountpoint "$d" "$f" </dev/null >/dev/null 2>&1; then
      MOUNTS="$MOUNTS$d
"
      scan_artifact "$d" "$label!" $((depth + 1))
      if hdiutil detach "$d" -quiet </dev/null >/dev/null 2>&1 ||
        hdiutil detach "$d" -force -quiet </dev/null >/dev/null 2>&1; then
        MOUNTS=${MOUNTS//"$d
"/}
      fi
    else
      fail_about 'could not attach the DMG' "$label"
    fi
  elif is_zip "$f" "${4:-}"; then
    newtmp zip
    d=$NEWDIR
    unzip -qq -o "$f" -d "$d" </dev/null >/dev/null 2>&1
    if [ $? -gt 1 ]; then
      fail_about 'could not unzip' "$label"
      return
    fi
    # Entries whose names collide (the same name twice, or names that differ
    # only in case on a case-insensitive volume) extract to one file, and
    # the others would go unscanned: every entry must have its own file.
    want=$(unzip -Z1 "$f" </dev/null 2>/dev/null | grep -c -v '/$')
    got=$(find "$d" ! -type d -print0 2>/dev/null | tr -cd '\000' | wc -c | tr -d ' ')
    if [ "$want" != "$got" ]; then
      fail_about 'zip entries collide (or could not be listed) in' "$label"
      return
    fi
    scan_artifact "$d" "$label!" $((depth + 1))
  fi
}

# Scans $1 (shown as $2): its raw bytes, then the zips and DMGs inside it.
scan_artifact() {
  local p="$1" label="$2" depth="${3:-0}" list f
  scan_files "$p" "$p" "$label"
  if [ -d "$p" ]; then
    scan_names "$p" "$p" "$label"
    newtmp list
    list=$NEWDIR
    find "$p" -type f \( -iname '*.zip' -o -iname '*.dmg' \) -print0 >"$list/files" 2>/dev/null
    while IFS= read -r -d '' f; do
      scan_container "$f" "$label${f#"$p"}" "$depth"
    done <"$list/files"
  else
    scan_container "$p" "$label" "$depth" magic
  fi
}

trim() {
  local v="$1"
  v=${v%$'\r'}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

# Splits deny-list lines on stdin into the path and email lists.
add_entries() {
  local line v
  while IFS= read -r line || [ -n "$line" ]; do
    v=$(trim "$line")
    [ -n "$v" ] || continue
    case "$v" in
      *@*) printf '%s\n' "$v" >>"$LK_EMAILS" ;;
      *) printf '%s\n' "$v" >>"$LK_PATHS" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Arguments.

MODE=""
ALLOW_EMPTY=0
INPUTS=()
PATFILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --text | --diff | --tree | --history | --artifact)
      [ -z "$MODE" ] || die "give one mode only"
      MODE=${1#--}
      ;;
    --patterns)
      [ $# -ge 2 ] || die "--patterns needs a file"
      PATFILES+=("$2")
      shift
      ;;
    --allow-empty-patterns) ALLOW_EMPTY=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        INPUTS+=("$1")
        shift
      done
      break
      ;;
    -) INPUTS+=("-") ;;
    -*) die "unknown mode or option (see --help)" ;;
    *) INPUTS+=("$1") ;;
  esac
  shift
done

[ -n "$MODE" ] || { usage; die "no mode given"; }
case "$MODE" in
  artifact) [ ${#INPUTS[@]} -ge 1 ] || die "--artifact needs at least one path" ;;
  *) [ ${#INPUTS[@]} -eq 1 ] || die "--$MODE needs exactly one path" ;;
esac

for f in ${PATFILES[@]+"${PATFILES[@]}"}; do
  [ -f "$f" ] && [ -r "$f" ] || die "--patterns: file not found"
done
[ -f "$ALLOW_FILE" ] || die "allow-list missing next to the script"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/leak-check.XXXXXX") || die "cannot create a temp dir"
export LK_PATHS="$TMP/paths" LK_EMAILS="$TMP/emails" LK_HOMES="$TMP/homes"
export LK_PREFIXES="$TMP/prefixes" LK_NAMES="$TMP/names"
CAND="$TMP/candidates"
: >"$LK_PATHS"
: >"$LK_EMAILS"
: >"$LK_HOMES"
: >"$LK_PREFIXES"
: >"$LK_NAMES"

# Rule a: the deny-list.
for f in ${PATFILES[@]+"${PATFILES[@]}"}; do
  add_entries <"$f"
done
if [ -n "${LEAK_PATTERNS:-}" ]; then
  printf '%s\n' "$LEAK_PATTERNS" | add_entries
fi
if [ ! -s "$LK_PATHS" ] && [ ! -s "$LK_EMAILS" ]; then
  [ "$ALLOW_EMPTY" = 1 ] || die "empty deny-list: give --patterns or LEAK_PATTERNS (or --allow-empty-patterns)"
  printf 'LEAK WARN: no deny-list\n' >&2
fi

# The inputs must exist before anything is scanned.
for f in "${INPUTS[@]}"; do
  case "$MODE" in
    text | diff)
      if [ "$f" != "-" ]; then
        [ -e "$f" ] && [ ! -d "$f" ] && [ -r "$f" ] || die "--$MODE: input not found"
      fi
      ;;
    tree) [ -d "$f" ] || die "--tree: directory not found" ;;
    history) [ -d "$f" ] || die "--history: git dir not found" ;;
    artifact)
      [ "$f" != "-" ] || die "--artifact: stdin is not supported"
      [ -e "$f" ] || die "--artifact: path not found"
      ;;
  esac
done

# Rule b: $HOME, as given and with symlinks resolved.
home=${HOME:-}
while [ "${home%/}" != "$home" ]; do home=${home%/}; done
if [ -n "$home" ]; then
  printf '%s\n' "$home" >>"$LK_HOMES"
  real=$(cd "$home" 2>/dev/null && pwd -P)
  if [ -n "$real" ] && [ "$real" != "$home" ] && [ "$real" != "/" ]; then
    printf '%s\n' "$real" >>"$LK_HOMES"
  fi
fi

# Rule c names and the third-party prefixes.
while IFS= read -r line || [ -n "$line" ]; do
  v=$(trim "$line")
  case "$v" in
    '' | '#'*) ;;
    prefix:*) printf '%s\n' "${v#prefix:}" >>"$LK_PREFIXES" ;;
    *) printf '%s\n' "$v" >>"$LK_NAMES" ;;
  esac
done <"$ALLOW_FILE"

# grep pre-filter: any line a rule could hit holds one of these
# (case-insensitively).
{
  cat "$LK_PATHS" "$LK_EMAILS" "$LK_HOMES"
  printf '/%s/\n' Users home
} >"$CAND"

# ---------------------------------------------------------------------------
# Scan.

case "$MODE" in
  text | diff)
    f=${INPUTS[0]}
    shown=$f
    if [ "$f" = "-" ]; then
      cat >"$TMP/stdin" || die "cannot read stdin"
      f="$TMP/stdin"
      shown=stdin
    fi
    if [ "$MODE" = text ]; then
      scan_text "$f" "$shown"
    else
      scan_diff "$f" "$shown"
    fi
    ;;
  tree)
    f=${INPUTS[0]}
    resolve "$f" || die "--tree: cannot resolve the directory"
    shown=$(noslash "$f")
    scan_files "$REAL" "$REAL" "$shown"
    scan_names "$REAL" "$REAL" "$shown"
    ;;
  history)
    scan_history "${INPUTS[0]}"
    ;;
  artifact)
    for f in "${INPUTS[@]}"; do
      resolve "$f" || die "--artifact: cannot resolve a path"
      scan_artifact "$REAL" "$(noslash "$f")" 0
    done
    ;;
esac

if [ "$FAILED" = 1 ]; then
  printf 'leak-check: the scan did not complete\n' >&2
  exit 2
fi
[ "$FOUND" = 1 ] && exit 1
exit 0
