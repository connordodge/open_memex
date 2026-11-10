#!/usr/bin/env bash
# rewrite-history.sh: the history rewrite for the public repo cutover
# (Spec #367, requirement 11).
#
# Writes a rewritten copy of <source> into <out> for a person to push to the
# new public repo. It never pushes, never fetches and never writes to
# <source>: it reads <source> through a fresh mirror clone and works only in
# <out>.
#
# Usage:
#   rewrite-history.sh --source <repo-path> --out <dir> \
#                      --noreply <id+name@users.noreply.github.com> \
#                      --patterns <file>
#
# What <out> holds afterwards:
#   - Exactly two refs: refs/heads/main (from <source>'s refs/heads/main,
#     whatever HEAD is) and refs/tags/v0.1.0. Every other branch and tag,
#     refs/remotes/*, review refs and the rest are dropped.
#   - Replacements (git filter-repo), from the deny-list in --patterns (one
#     entry per line, blank lines ignored, surrounding whitespace trimmed;
#     the same reading as leak-check.sh):
#       an entry containing @ is an email: it becomes <noreply> in author,
#         committer and tagger emails, in blob contents and in commit and
#         tag messages, matched case-insensitively (ASCII);
#       any other entry is a path: it becomes ~ in blob contents and in
#         commit and tag messages, matched case-sensitively. So does this
#         machine's $HOME, as given and with symlinks resolved.
#     Entries are literals, never regular expressions. Emails are replaced
#     before paths, and longer paths before shorter ones. File names are
#     not rewritten, and filter-repo leaves binary blobs alone: the Leak
#     check below reports what survives.
#   - One final commit on main, authored and committed as <noreply>, that
#     removes .claude/orchestration, .act, ai_specs, CLAUDE.md and AGENTS.md
#     (they move to a private companion dir). Its message is exactly
#     "chore: move dev files out of the public repo". It is signed when the
#     invoking user's git config sets commit.gpgsign.
#   - No remote: the mirror's origin (which points at <source>) is removed.
#
# Then it runs leak-check.sh --history <out> --patterns <file>. On success it
# prints the commit count, the kept refs, main's SHA, "leaks: 0" and the push
# commands, and runs none of them.
#
# Exit status:
#   0  rewritten, and the Leak check is clean.
#   1  the Leak check found a leak (its redacted LEAK lines are printed):
#      <out> is left in place, refs and all, for inspection, and must not be
#      pushed. Or a step after the clone into <out> failed, or the run was
#      interrupted (INT, TERM, HUP): then every ref in <out> is deleted
#      (the objects stay), so there is nothing to push, and the message says
#      where main was.
#   2  refused, with nothing created or changed: a usage error, a missing
#      patterns file, a non-empty <out>, <out> inside <source>, a dirty
#      <source>, <source>'s refs/heads/main not equal to its
#      refs/remotes/origin/main, no `git filter-repo` on PATH, a --noreply
#      that is not a users.noreply.github.com address, or an empty
#      deny-list.
#
# Tools: bash (3.2 is enough), git, git-filter-repo (and the python3 it
# runs on) and the POSIX basics.

export LC_ALL=C
set -u
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LEAK_CHECK="$SCRIPT_DIR/../leak-check.sh"

FINAL_MESSAGE='chore: move dev files out of the public repo'
DEV_PATHS='.claude/orchestration .act ai_specs CLAUDE.md AGENTS.md'
KEEP_MAIN='refs/heads/main'
KEEP_TAG='refs/tags/v0.1.0'

TMP=""
# 1 from just before the clone into <out> until the Leak check has run: an
# exit in that window, for any reason, deletes every ref in <out>.
ARMED=0
cleanup() {
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi
}

# Leaves <out> with no refs, so a half-done rewrite (the original history
# before filter-repo, or a tree that still has the dev files before the
# final commit) cannot be pushed. Uses --git-dir, never discovery, so it
# can only touch the repo the clone made.
disarm_out() {
  ARMED=0
  git --git-dir="$OUT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local at
  at=$(git --git-dir="$OUT" rev-parse -q --verify "$KEEP_MAIN" 2>/dev/null)
  git --git-dir="$OUT" for-each-ref --format='%(refname)' 2>/dev/null |
    while IFS= read -r r; do printf 'option no-deref\ndelete %s\n' "$r"; done |
    git --git-dir="$OUT" update-ref --stdin 2>/dev/null
  if [ -z "$(git --git-dir="$OUT" for-each-ref --format='%(refname)' 2>/dev/null)" ]; then
    printf 'rewrite-history: the rewrite did not finish, so every ref in %s was deleted: do NOT push it. Run again into a new --out.\n' "$OUT" >&2
    if [ -n "$at" ]; then
      printf 'rewrite-history: main was at %s (unfinished; kept only as objects for inspection).\n' "$at" >&2
    fi
  else
    printf 'rewrite-history: the rewrite did not finish and the refs in %s could not be deleted: do NOT push it. Delete it and run again.\n' "$OUT" >&2
  fi
}

on_exit() {
  local status=$?
  if [ "$ARMED" = 1 ]; then disarm_out; fi
  cleanup
  exit "$status"
}
trap on_exit EXIT
trap 'exit 1' INT TERM HUP

usage() {
  cat >&2 <<'EOF'
usage: rewrite-history.sh --source <repo-path> --out <dir>
                          --noreply <id+name@users.noreply.github.com>
                          --patterns <file>
  Writes a rewritten mirror of <source> into <out> (empty or missing).
  Never pushes, fetches or writes to <source>.
  Exit status: 0 done and leak-free, 1 leak found (<out> kept, do not
  push) or a step failed or was interrupted (<out> kept with no refs),
  2 refused (nothing changed).
EOF
}

refuse() {
  printf 'rewrite-history: refused: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'rewrite-history: failed: %s\n' "$1" >&2
  exit 1
}

trim() {
  local v="$1"
  v=${v%$'\r'}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

# Physical absolute path of $1, which need not exist: its deepest existing
# ancestor is resolved and the rest appended.
physical_path() {
  local p="$1" rest="" base dir
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p=${p%/}; done
  while [ ! -d "$p" ]; do
    base=${p##*/}
    dir=${p%/*}
    [ -n "$dir" ] || dir=/
    if [ -n "$rest" ]; then rest="$base/$rest"; else rest="$base"; fi
    p=$dir
  done
  dir=$(cd "$p" && pwd -P) || return 1
  if [ -z "$rest" ]; then
    printf '%s' "$dir"
  elif [ "$dir" = / ]; then
    printf '/%s' "$rest"
  else
    printf '%s/%s' "$dir" "$rest"
  fi
}

# True when path $1 is $2 or lies under it.
is_within() {
  [ "$1" = "$2" ] && return 0
  case "$1" in "${2%/}"/*) return 0 ;; esac
  return 1
}

# A deny-list literal as a Python regex: every metacharacter escaped, and =
# too, so no entry can spell filter-repo's ==> separator.
regex_literal() {
  printf '%s' "$1" | sed 's/[][\.*^$?+(){}|/=#&~-]/\\&/g'
}

# The path as a shell word for a copy-paste command.
shell_word() {
  case "$1" in
    *[!A-Za-z0-9_./+:@%,-]* | '') printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Arguments.

SOURCE=""
OUT=""
NOREPLY=""
PATTERNS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source | --out | --noreply | --patterns)
      [ $# -ge 2 ] || { usage; refuse "$1 needs a value"; }
      case "$1" in
        --source) SOURCE=$2 ;;
        --out) OUT=$2 ;;
        --noreply) NOREPLY=$2 ;;
        --patterns) PATTERNS=$2 ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      refuse "unknown argument: $1"
      ;;
  esac
done

[ -n "$SOURCE" ] || { usage; refuse "--source is required"; }
[ -n "$OUT" ] || { usage; refuse "--out is required"; }
[ -n "$NOREPLY" ] || { usage; refuse "--noreply is required"; }
[ -n "$PATTERNS" ] || { usage; refuse "--patterns is required"; }

# ---------------------------------------------------------------------------
# Refusals. Every one runs before anything is created.

[ -f "$PATTERNS" ] && [ -r "$PATTERNS" ] || refuse "--patterns: file not found"

case "$NOREPLY" in
  *[!A-Za-z0-9._+-]*@users.noreply.github.com | @users.noreply.github.com)
    refuse "--noreply must be a GitHub noreply address (<id>+<name>@users.noreply.github.com)"
    ;;
  *@users.noreply.github.com) ;;
  *) refuse "--noreply must end in @users.noreply.github.com" ;;
esac

DENY_COUNT=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$(trim "$line")" ] && DENY_COUNT=$((DENY_COUNT + 1))
done <"$PATTERNS"
[ "$DENY_COUNT" -gt 0 ] || refuse "the deny-list in --patterns is empty"

if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ -d "$OUT" ] || refuse "--out exists and is not a directory"
  [ -z "$(ls -A "$OUT" 2>/dev/null)" ] || refuse "--out exists and is not empty"
fi

command -v git >/dev/null 2>&1 || refuse "git is not on PATH"
git filter-repo --version >/dev/null 2>&1 ||
  refuse "git filter-repo is not on PATH (install it, for example with Homebrew)"

# Read-only from here on: no optional index refresh in <source>.
export GIT_OPTIONAL_LOCKS=0

[ "$(git -C "$SOURCE" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
  refuse "--source is not a git working tree"
SRC_TOP=$(git -C "$SOURCE" rev-parse --show-toplevel) || refuse "cannot read --source"
SRC_GIT=$(git -C "$SOURCE" rev-parse --absolute-git-dir) || refuse "cannot read --source"
SRC_COMMON=$(git -C "$SOURCE" rev-parse --path-format=absolute --git-common-dir) ||
  refuse "cannot read --source"
OUT_PHYS=$(physical_path "$OUT") || refuse "cannot resolve --out"
for d in "$SRC_TOP" "$SRC_GIT" "$SRC_COMMON"; do
  d=$(physical_path "$d") || refuse "cannot resolve --source"
  is_within "$OUT_PHYS" "$d" && refuse "--out is inside --source"
done

DIRTY=$(git -C "$SOURCE" status --porcelain) || refuse "cannot read the status of --source"
[ -z "$DIRTY" ] || refuse "--source has uncommitted changes (commit or remove them first)"

MAIN=$(git -C "$SOURCE" rev-parse -q --verify "$KEEP_MAIN^{commit}") ||
  refuse "--source has no refs/heads/main"
ORIGIN_MAIN=$(git -C "$SOURCE" rev-parse -q --verify 'refs/remotes/origin/main^{commit}') ||
  refuse "--source has no refs/remotes/origin/main"
[ "$MAIN" = "$ORIGIN_MAIN" ] ||
  refuse "--source main ($MAIN) differs from its refs/remotes/origin/main ($ORIGIN_MAIN); push or pull first (this script never fetches)"

[ -f "$LEAK_CHECK" ] || refuse "leak-check.sh is missing next to scripts/public-cutover"

# ---------------------------------------------------------------------------
# The deny-list, split into emails and paths (as leak-check.sh reads it).

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rewrite-history.XXXXXX") || refuse "cannot create a temp dir"
EMAILS="$TMP/emails"
PATHS="$TMP/paths"
EXPRS="$TMP/expressions"
: >"$EMAILS"
: >"$PATHS"
while IFS= read -r line || [ -n "$line" ]; do
  v=$(trim "$line")
  [ -n "$v" ] || continue
  case "$v" in
    *@*) printf '%s\n' "$v" | tr 'A-Z' 'a-z' >>"$EMAILS" ;;
    *) printf '%s\n' "$v" >>"$PATHS" ;;
  esac
done <"$PATTERNS"

home=${HOME:-}
while [ "${home%/}" != "$home" ]; do home=${home%/}; done
if [ -n "$home" ]; then
  printf '%s\n' "$home" >>"$PATHS"
  real=$(cd "$home" 2>/dev/null && pwd -P)
  if [ -n "$real" ] && [ "$real" != "$home" ] && [ "$real" != "/" ]; then
    printf '%s\n' "$real" >>"$PATHS"
  fi
fi

# filter-repo applies the lines in order: emails first, then paths, longest
# first, so a shorter entry never cuts into a longer one.
{
  sort -u "$EMAILS" | while IFS= read -r e; do
    printf 'regex:(?i)%s==>%s\n' "$(regex_literal "$e")" "$NOREPLY"
  done
  sort -u "$PATHS" | awk '{ print length($0) "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 |
    cut -f2- | while IFS= read -r p; do
      printf 'regex:%s==>~\n' "$(regex_literal "$p")"
    done
} >"$EXPRS"

# ---------------------------------------------------------------------------
# The mirror. From here on a failure exits 1 and leaves <out> with no refs.

# The top of the working tree, so a --source inside it works too.
ARMED=1
git clone -q --mirror --no-local "$SRC_TOP" "$OUT" || fail "git clone --mirror"
OUT=$(cd "$OUT" && pwd) || fail "cannot enter --out"

# Drop the remote that points back at <source> (filter-repo would also run
# `git remote rm origin`, which walks the mirror refspec).
git -C "$OUT" config --remove-section remote.origin 2>/dev/null
git -C "$OUT" symbolic-ref HEAD "$KEEP_MAIN" || fail "cannot point HEAD at main"

# Keeps refs/heads/main and refs/tags/v0.1.0 and deletes every other ref.
# Runs before filter-repo (which would turn refs/remotes/origin/* into
# branches) and again after it.
filter_refs() {
  git -C "$OUT" for-each-ref --format='%(refname)' >"$TMP/refs" || return 1
  while IFS= read -r r; do
    case "$r" in
      "$KEEP_MAIN" | "$KEEP_TAG") ;;
      *) printf 'option no-deref\ndelete %s\n' "$r" ;;
    esac
  done <"$TMP/refs" | git -C "$OUT" update-ref --stdin
}
filter_refs || fail "cannot drop the other refs"
[ "$(git -C "$OUT" rev-parse -q --verify "$KEEP_MAIN")" = "$MAIN" ] ||
  fail "the mirror's main is not the source's refs/heads/main"

export RW_EMAILS="$EMAILS" RW_NOREPLY="$NOREPLY"
# shellcheck disable=SC2016 # Python, not shell.
EMAIL_CALLBACK='
import os
g = globals()
if "_rw_deny_emails" not in g:
  with open(os.environ["RW_EMAILS"], "rb") as f:
    g["_rw_deny_emails"] = set(l.strip() for l in f if l.strip())
if email.lower() in g["_rw_deny_emails"]:
  return os.environ["RW_NOREPLY"].encode()
return email
'
# Never prune: a commit that only scrubbed a deny-listed string becomes
# empty after the replacements, and a merge of such commits degenerate.
# filter-repo's default would drop both and move a tag on one to its parent.
if ! git -C "$OUT" filter-repo --force --quiet \
  --prune-empty never --prune-degenerate never \
  --replace-text "$EXPRS" \
  --replace-message "$EXPRS" \
  --email-callback "$EMAIL_CALLBACK" >"$TMP/filter-repo.log" 2>&1; then
  cat "$TMP/filter-repo.log" >&2
  fail "git filter-repo"
fi

filter_refs || fail "cannot drop the other refs"
git -C "$OUT" rev-parse -q --verify "$KEEP_MAIN" >/dev/null || fail "main is missing after the rewrite"

# ---------------------------------------------------------------------------
# The final commit: main's tree without the dev paths, on a temp index.

# shellcheck disable=SC2086 # DEV_PATHS is a fixed word list.
TREE=$(
  export GIT_INDEX_FILE="$TMP/index"
  git -C "$OUT" read-tree "$KEEP_MAIN" &&
    git -C "$OUT" rm -r -q --cached --ignore-unmatch -- $DEV_PATHS >/dev/null &&
    git -C "$OUT" write-tree
) || fail "cannot build the final tree"

SIGN=()
if [ "$(git -C "$OUT" config --bool commit.gpgsign 2>/dev/null)" = true ]; then
  SIGN=(-S)
fi
FINAL=$(
  GIT_AUTHOR_EMAIL="$NOREPLY" GIT_COMMITTER_EMAIL="$NOREPLY" \
    git -C "$OUT" commit-tree ${SIGN[@]+"${SIGN[@]}"} -p "$KEEP_MAIN" -m "$FINAL_MESSAGE" "$TREE"
) || fail "cannot create the final commit"
git -C "$OUT" update-ref "$KEEP_MAIN" "$FINAL" || fail "cannot move main to the final commit"

# ---------------------------------------------------------------------------
# The Leak check on the result.

LEAK_OK=1
bash "$LEAK_CHECK" --history "$OUT" --patterns "$PATTERNS" || LEAK_OK=0
# The run is complete either way: a leak keeps <out> whole for inspection.
ARMED=0
if [ "$LEAK_OK" = 0 ]; then
  printf 'rewrite-history: the Leak check found private data in %s (see the LEAK lines above);\n' "$OUT" >&2
  printf 'rewrite-history: nothing to push. Fix the deny-list or the history and run again into a new --out.\n' >&2
  exit 1
fi

REFS=$(git -C "$OUT" for-each-ref --format='%(refname)' | tr '\n' ' ')
COUNT=$(git -C "$OUT" rev-list --count "$KEEP_MAIN") || fail "cannot count commits"
OUT_WORD=$(shell_word "$OUT")

printf 'rewritten: %s\n' "$OUT"
printf 'commits: %s\n' "$COUNT"
printf 'refs: %s\n' "${REFS% }"
printf 'main: %s\n' "$FINAL"
printf 'leaks: 0\n'
printf '\nNothing was pushed. To publish, run:\n'
printf '  git -C %s remote add <new-remote> <public-repo-url>\n' "$OUT_WORD"
printf '  git -C %s push <new-remote> main v0.1.0\n' "$OUT_WORD"
