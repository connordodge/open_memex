import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';

// Skeleton (#34 red): A2 #34 fills this file and keeps each `defaultX(Ref)`.

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
const installHelperScript = '';

/// The production [InstallHelper] behind `installHelperProvider`: starts
/// `/bin/sh` with [installHelperScript] and its positional arguments through
/// `installHelperRunnerProvider`, with the marker at
/// `failureMarkerFileProvider`, a 60-second wait limit and a system-only
/// PATH.
InstallHelper defaultInstallHelper(Ref ref) => const _InstallHelper();

/// The production detached runner behind `installHelperRunnerProvider`
/// (`Process.start` with `ProcessStartMode.detached`).
InstallHelperRunner defaultInstallHelperRunner(Ref ref) => _runNothing;

Future<void> _runNothing(String executable, List<String> arguments) async {}

class _InstallHelper implements InstallHelper {
  const _InstallHelper();

  @override
  Future<void> start({
    required int pid,
    required String dmgPath,
    required String bundlePath,
  }) async {}
}
