// WI #37 (A3): local doubles for the update controller tests. The shared
// fakes in test/support/ are frozen after #32, so the call-order recorders
// live here: each one subclasses a shared fake and adds a line to one log.
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/fake_clock.dart';
import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';

/// [UpdaterFakes] whose ports also write every call, in order, to [log].
class LoggingUpdaterFakes extends UpdaterFakes {
  LoggingUpdaterFakes({super.clock});

  /// Every port call, oldest first.
  final List<String> log = [];

  late final _fetcher = _LoggingFetcher(log);
  late final _downloader = _LoggingDownloader(log);
  late final _verifier = _LoggingVerifier(log);
  late final _location = _LoggingLocation(log);
  late final _helper = _LoggingHelper(log);
  late final _marker = _LoggingMarker(log);
  late final _lastCheck = _LoggingLastCheck(log);
  late final _exit = _LoggingExit(log);

  @override
  FakeAppcastFetcher get fetcher => _fetcher;
  @override
  FakeUpdateDownloader get downloader => _downloader;
  @override
  FakeEdDsaVerifier get verifier => _verifier;
  @override
  FakeInstallLocationCheck get location => _location;
  @override
  FakeInstallHelper get helper => _helper;
  @override
  FakeFailureMarkerStore get marker => _marker;
  @override
  FakeLastCheckStore get lastCheck => _lastCheck;
  @override
  RecordingProcessExit get exit => _exit;
}

class _LoggingFetcher extends FakeAppcastFetcher {
  _LoggingFetcher(this._log);
  final List<String> _log;

  @override
  Future<List<AppcastItem>> fetch() {
    _log.add('fetch');
    return super.fetch();
  }
}

class _LoggingDownloader extends FakeUpdateDownloader {
  _LoggingDownloader(this._log);
  final List<String> _log;

  @override
  Future<String> download(
    AppcastItem item, {
    void Function(double? progress)? onProgress,
  }) {
    _log.add('download');
    return super.download(item, onProgress: onProgress);
  }

  @override
  Future<void> deleteLeftovers() {
    _log.add('deleteLeftovers');
    return super.deleteLeftovers();
  }
}

class _LoggingVerifier extends FakeEdDsaVerifier {
  _LoggingVerifier(this._log);
  final List<String> _log;

  @override
  Future<void> verify({required String dmgPath, required String edSignature}) {
    _log.add('verify');
    return super.verify(dmgPath: dmgPath, edSignature: edSignature);
  }
}

class _LoggingLocation extends FakeInstallLocationCheck {
  _LoggingLocation(this._log);
  final List<String> _log;

  @override
  Future<String> check() {
    _log.add('location');
    return super.check();
  }
}

class _LoggingHelper extends FakeInstallHelper {
  _LoggingHelper(this._log);
  final List<String> _log;

  @override
  Future<void> start({
    required int pid,
    required String dmgPath,
    required String bundlePath,
  }) {
    _log.add('helper');
    return super.start(pid: pid, dmgPath: dmgPath, bundlePath: bundlePath);
  }
}

class _LoggingMarker extends FakeFailureMarkerStore {
  _LoggingMarker(this._log);
  final List<String> _log;

  @override
  Future<String?> take() {
    _log.add('takeMarker');
    return super.take();
  }
}

class _LoggingLastCheck extends FakeLastCheckStore {
  _LoggingLastCheck(this._log);
  final List<String> _log;

  @override
  Future<DateTime?> read() {
    _log.add('readLastCheck');
    return super.read();
  }

  @override
  Future<void> write(DateTime time) {
    _log.add('writeLastCheck');
    return super.write(time);
  }
}

class _LoggingExit extends RecordingProcessExit {
  _LoggingExit(this._log);
  final List<String> _log;

  @override
  Future<AppExitResponse> call(AppExitType type) {
    _log.add('exit ${type.name}');
    return super.call(type);
  }
}

/// An [ExitConfirmation] that writes `confirm` to [log] when confirmed.
class LoggingExitConfirmation extends ExitConfirmation {
  LoggingExitConfirmation(this.log);

  final List<String> log;

  @override
  void confirm() {
    log.add('confirm');
    super.confirm();
  }
}

/// The real [UpdateController] over [fakes], plus every state it emits.
class ControllerRig {
  ControllerRig._(this.fakes, this.container) {
    container.listen<UpdateState>(
      updateControllerProvider,
      (_, next) => states.add(next),
    );
  }

  /// A rig over [fakes] (fresh ones by default) with [overrides] on top of
  /// the harness's. Call it inside a test: the container is disposed at the
  /// test's end.
  factory ControllerRig({
    UpdaterFakes? fakes,
    List<Override> overrides = const [],
  }) {
    final f = fakes ?? UpdaterFakes();
    return ControllerRig._(f, updaterContainer(fakes: f, overrides: overrides));
  }

  final UpdaterFakes fakes;
  final ProviderContainer container;

  /// Every state the controller emitted, oldest first.
  final List<UpdateState> states = [];

  UpdateController get controller =>
      container.read(updateControllerProvider.notifier);

  UpdateState get state => container.read(updateControllerProvider);

  FakeClock get clock => fakes.clock;
}

/// A newer item than the harness's installed `1.2.3` build `7`, built from
/// run-time values.
AppcastItem newerItem({String shortVersionString = '1.3.0'}) =>
    testAppcastItem(shortVersionString: shortVersionString, version: '9');

/// Runs a manual check that offers [item] (a newer item by default) and
/// returns it; fails the test unless the controller reached Available.
Future<AppcastItem> driveToAvailable(
  ControllerRig rig, {
  AppcastItem? item,
}) async {
  final offered = item ?? newerItem();
  rig.fakes.fetcher
    ..failure = null
    ..items = [offered];
  await rig.controller.check(manual: true);
  expect(
    rig.state,
    isA<UpdateAvailable>().having((s) => s.item, 'item', same(offered)),
    reason: 'setup: a manual check should offer the newer item',
  );
  return offered;
}

/// Drives the controller to Ready with [item] and returns the Ready state.
Future<UpdateReady> driveToReady(ControllerRig rig, {AppcastItem? item}) async {
  final offered = await driveToAvailable(rig, item: item);
  await rig.controller.install();
  final state = rig.state;
  expect(
    state,
    isA<UpdateReady>().having((s) => s.item, 'item', same(offered)),
    reason: 'setup: install should reach Ready',
  );
  return state as UpdateReady;
}

/// An Error state with [cause] (and [item] when given).
Matcher isUpdateError(UpdateErrorCause cause, {Object? item}) {
  var m = isA<UpdateError>().having((e) => e.cause, 'cause', cause);
  if (item != null) m = m.having((e) => e.item, 'item', item);
  return m;
}
