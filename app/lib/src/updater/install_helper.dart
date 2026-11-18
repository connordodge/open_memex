import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The install helper script (req 25, 26, D13): constant text, run as
///
/// ```text
/// /bin/sh -c <installHelperScript> <$0 name> <pid> <dmg> <bundle> <marker> <wait seconds> <PATH>
/// ```
///
/// so `$1` is the app's pid, `$2` the staged DMG, `$3` the installed bundle
/// path, `$4` the failure marker path, `$5` the wait limit in seconds (60 in
/// production) and `$6` the PATH every tool is looked up on. Nothing
/// variable is interpolated into the text. It exits 0 when the new app is in
/// place (even if deleting `Open Memex.app.old` fails) and 1 after writing
/// one of the five fixed reasons to the marker.
const installHelperScript = r'''
# Open Memex install helper (Self-update). Runs detached and keeps running
# after the app exits. Arguments: $1 the app's pid, $2 the staged DMG, $3 the
# installed bundle, $4 the failure marker, $5 the wait limit in seconds, $6
# the PATH every tool is looked up on. Exits 0 once the new app is in place
# and 1 after recording one fixed reason to the marker.
[ "$#" -eq 6 ] || exit 2
case "$1" in
  '' | *[!0-9]*) exit 2 ;;
esac
PATH=$6
export PATH
APP_PID=$1
DMG=$2
BUNDLE=$3
MARKER=$4
WAIT=$5
case "$WAIT" in
  '' | *[!0-9]*) WAIT=0 ;;
esac
DIR=$(dirname "$BUNDLE")
NEW="$DIR/Open Memex.app.new"
OLD="$DIR/Open Memex.app.old"
TMP=${TMPDIR:-/tmp}
TMP=${TMP%/}
MOUNT=''
MOUNTED=''

record() {
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null
  printf '%s\n' "$1" > "$MARKER"
}

unmount() {
  if [ -n "$MOUNTED" ]; then
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 ||
      hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1
    MOUNTED=''
  fi
  if [ -n "$MOUNT" ]; then
    rmdir "$MOUNT" 2>/dev/null
    MOUNT=''
  fi
}

# A step failed after the app quit: record its reason, drop the copy, detach
# and relaunch the app at the installed path (the old one, restored if it was
# moved).
fail() {
  record "$1"
  rm -rf "$NEW" 2>/dev/null
  unmount
  open "$BUNDLE" >/dev/null 2>&1
  exit 1
}

# 1. Wait for the app to exit, polling its pid ten times a second. Still
# running at the limit: record it and touch nothing.
LIMIT=$((WAIT * 10))
TICKS=0
while kill -0 "$APP_PID" 2>/dev/null; do
  if [ "$TICKS" -ge "$LIMIT" ]; then
    record "the app didn't quit in time"
    exit 1
  fi
  sleep 0.1
  TICKS=$((TICKS + 1))
done

# 2. Mount the DMG read-only at a mount point of our own, never in Finder.
MOUNT=$(mktemp -d "$TMP/open-memex-update-mount.XXXXXX") || {
  MOUNT=''
  fail "the disk image couldn't be opened"
}
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" -noautoopen "$DMG" >/dev/null 2>&1 ||
  fail "the disk image couldn't be opened"
MOUNTED=yes

# 3. Copy the app at the mount root next to the installed one, as .new only:
# never over the installed (possibly running) bundle. A stale .new from an
# earlier attempt goes first.
SRC="$MOUNT/Open Memex.app"
[ -d "$SRC" ] || fail "the new app couldn't be copied"
rm -rf "$NEW" 2>/dev/null
[ ! -e "$NEW" ] || fail "the new app couldn't be copied"
ditto "$SRC" "$NEW" || fail "the new app couldn't be copied"

# 4. Verify the copy's signature.
codesign --verify --deep --strict "$NEW" >/dev/null 2>&1 ||
  fail "the new app's signature didn't verify"

# 5. Rename swap. Before the second rename the old app can be restored; after
# it the new app is in place and a failed delete of .old is not a failure.
rm -rf "$OLD" 2>/dev/null
[ ! -e "$OLD" ] || fail "the new app couldn't be moved into place"
mv "$BUNDLE" "$OLD" 2>/dev/null || fail "the new app couldn't be moved into place"
if ! mv "$NEW" "$BUNDLE" 2>/dev/null; then
  mv "$OLD" "$BUNDLE" 2>/dev/null
  fail "the new app couldn't be moved into place"
fi
rm -rf "$OLD" 2>/dev/null

# 6. Strip quarantine, detach, then launch the new app.
xattr -dr com.apple.quarantine "$BUNDLE" 2>/dev/null
unmount
open "$BUNDLE" >/dev/null 2>&1
exit 0
''';

/// The helper's `$0` name.
const _helperName = 'open-memex-install-helper';

/// How long the helper waits for the app to exit (req 25).
const _helperWaitSeconds = 60;

/// The helper's PATH: system folders only, never the user's PATH.
const _helperPath = '/usr/bin:/bin:/usr/sbin:/sbin';

/// The production [InstallHelper] behind `installHelperProvider`: starts
/// `/bin/sh` with [installHelperScript] and its positional arguments through
/// `installHelperRunnerProvider`, with the marker at
/// `failureMarkerFileProvider`, a 60-second wait limit and a system-only
/// PATH.
InstallHelper defaultInstallHelper(Ref ref) => _InstallHelper(ref);

/// The production detached runner behind `installHelperRunnerProvider`
/// (`Process.start` with `ProcessStartMode.detached`).
InstallHelperRunner defaultInstallHelperRunner(Ref ref) => _runDetached;

Future<void> _runDetached(String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

class _InstallHelper implements InstallHelper {
  const _InstallHelper(this._ref);

  final Ref _ref;

  @override
  Future<void> start({
    required int pid,
    required String dmgPath,
    required String bundlePath,
  }) async {
    try {
      final run = _ref.read(installHelperRunnerProvider);
      final marker = _ref.read(failureMarkerFileProvider);
      await run('/bin/sh', [
        '-c',
        installHelperScript,
        _helperName,
        '$pid',
        dmgPath,
        bundlePath,
        marker,
        '$_helperWaitSeconds',
        _helperPath,
      ]);
    } catch (_) {
      throw const UpdateFailure(
        UpdateErrorCause.failureRecorded,
        reason: "the install helper couldn't be started",
      );
    }
  }
}
