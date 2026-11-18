import 'dart:ui' show AppExitType;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_exit.dart';
import '../state/app_version.dart';
import '../state/clock.dart';
import 'appcast.dart';
import 'update_ports.dart';
import 'update_seams.dart';
import 'update_state.dart';
import 'update_version.dart';

/// How a [UpdateController.relaunch] ended.
enum RelaunchOutcome {
  /// The install helper started and the app is exiting.
  exiting,

  /// The person cancelled the quit guard; the update stays Ready.
  cancelled,

  /// The install-location check or the helper failed; the state is Error.
  failed,

  /// Nothing ran: the update isn't Ready, or a relaunch is already running.
  ignored,
}

/// How long after a stamped check the next launch check is due (req 11).
const _checkInterval = Duration(hours: 24);

/// The only sequencer of Self-update and the single source of truth the
/// modal and version labels render from (TD3, D2). It survives the modal
/// closing.
class UpdateController extends Notifier<UpdateState> {
  /// The check in flight, so a check started meanwhile joins it.
  Future<void>? _checking;

  /// Whether a download and verify is running.
  bool _installing = false;

  /// Whether a relaunch is running.
  bool _relaunching = false;

  @override
  UpdateState build() => const UpdateIdle();

  /// Runs the launch sequence (D8); true when the app root should open the
  /// modal.
  ///
  /// With updates disabled it touches nothing (D7). Otherwise it deletes the
  /// leftover download directory, then reads and clears the failure marker:
  /// a recorded reason enters Error and skips this launch's check. Else it
  /// runs the check if one is due (req 11) and answers true only when that
  /// check offers an update.
  Future<bool> launch() async {
    if (!ref.read(updatesEnabledProvider)) return false;
    await ref.read(updateDownloaderProvider).deleteLeftovers();
    final reason = await ref.read(failureMarkerStoreProvider).take();
    if (reason != null) {
      state = UpdateError(UpdateErrorCause.failureRecorded, reason: reason);
      return true;
    }
    await check(manual: false);
    return state is UpdateAvailable;
  }

  /// Checks the Appcast. A [manual] check is never throttled; any other
  /// runs only when due (req 11).
  ///
  /// While Ready, Downloading or Verifying it keeps the current state and
  /// fetches nothing (req 17, D20).
  Future<void> check({required bool manual}) async {
    if (state case UpdateReady() || UpdateDownloading() || UpdateVerifying()) {
      return;
    }
    if (!manual && !await _checkDue()) return;
    await (_checking ??= _runCheck().whenComplete(() => _checking = null));
  }

  /// Whether the last check was never stamped, or stamped at least
  /// [_checkInterval] ago. A stamp in the future is not due.
  Future<bool> _checkDue() async {
    final stamp = await ref.read(lastCheckStoreProvider).read();
    if (stamp == null) return true;
    final elapsed = ref.read(clockProvider).now().difference(stamp);
    return elapsed >= _checkInterval;
  }

  /// Fetches and parses the Appcast, then offers the newest item the
  /// version decision picks (req 9). A fetched and parsed Appcast stamps
  /// the last check; a failed fetch does not.
  Future<void> _runCheck() async {
    state = const UpdateChecking();
    final List<AppcastItem> items;
    try {
      items = await ref.read(appcastFetcherProvider).fetch();
    } on UpdateFailure catch (failure) {
      state = _error(failure);
      return;
    }
    final offered = decideUpdate(
      items,
      installedVersion: ref.read(appVersionProvider),
      installedBuild: ref.read(appBuildNumberProvider),
      runningMacos: ref.read(runningMacosVersionProvider),
    );
    state = offered == null ? const UpdateUpToDate() : UpdateAvailable(offered);
    await ref.read(lastCheckStoreProvider).write(ref.read(clockProvider).now());
  }

  /// Downloads and verifies the offered update. Outside Available it does
  /// nothing.
  Future<void> install() async {
    final current = state;
    if (_installing || current is! UpdateAvailable) return;
    await _install(current.item);
  }

  /// Downloads [item], verifies it and stages it Ready; a failure enters
  /// Error with its cause and [item].
  Future<void> _install(AppcastItem item) async {
    _installing = true;
    try {
      state = UpdateDownloading(item);
      final dmgPath = await ref
          .read(updateDownloaderProvider)
          .download(
            item,
            onProgress: (progress) =>
                state = UpdateDownloading(item, progress: progress),
          );
      state = UpdateVerifying(item);
      await ref
          .read(edDsaVerifierProvider)
          .verify(dmgPath: dmgPath, edSignature: item.edSignature);
      state = UpdateReady(item, dmgPath: dmgPath);
    } on UpdateFailure catch (failure) {
      state = _error(failure, item: item);
    } finally {
      _installing = false;
    }
  }

  /// **try again**: goes where the error cause's target says (req 15). A
  /// check cause runs a new check; a download or signature cause downloads
  /// the same item again. Outside Error it does nothing.
  Future<void> tryAgain() async {
    final current = state;
    if (current is! UpdateError) return;
    final item = current.item;
    switch (current.cause.tryAgain) {
      case UpdateRetryTarget.checking:
        await check(manual: true);
      case UpdateRetryTarget.downloading:
        if (item != null && !_installing) await _install(item);
      case UpdateRetryTarget.none:
        return;
    }
  }

  /// **later** (req 16, 16a): on Available it goes back to Idle, so the
  /// next due or manual check offers the update again. In any other state
  /// it leaves the state, and any running work, alone.
  void later() {
    if (state is UpdateAvailable) state = const UpdateIdle();
  }

  /// **relaunch** (req 23, D2): location check, then [confirmQuit], then
  /// the install helper, then the confirmed process exit.
  Future<RelaunchOutcome> relaunch({
    required Future<bool> Function() confirmQuit,
  }) async {
    final ready = state;
    if (_relaunching || ready is! UpdateReady) return RelaunchOutcome.ignored;
    _relaunching = true;
    try {
      final String bundlePath;
      try {
        bundlePath = await ref.read(installLocationCheckProvider).check();
      } on UpdateFailure catch (failure) {
        state = _error(failure, item: ready.item);
        return RelaunchOutcome.failed;
      }
      if (!await confirmQuit()) return RelaunchOutcome.cancelled;
      try {
        await ref
            .read(installHelperProvider)
            .start(
              pid: ref.read(currentPidProvider),
              dmgPath: ready.dmgPath,
              bundlePath: bundlePath,
            );
      } on UpdateFailure catch (failure) {
        state = _error(failure, item: ready.item);
        return RelaunchOutcome.failed;
      }
      ref.read(appExitConfirmationProvider).confirm();
      await ref.read(appProcessExitProvider)(AppExitType.required);
      return RelaunchOutcome.exiting;
    } finally {
      _relaunching = false;
    }
  }

  /// The Error state for [failure], about [item] when one is being
  /// installed.
  UpdateError _error(UpdateFailure failure, {AppcastItem? item}) => UpdateError(
    failure.cause,
    item: item,
    folder: failure.folder,
    reason: failure.reason,
  );
}

/// The app's [UpdateController].
final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
