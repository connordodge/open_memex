// WI #32 (A0, D19): a recording fake for every updater port, the low-level
// updater seams, the process-exit seam and the update controller, plus the
// Appcast fixtures loader and an item builder.
//
// FROZEN after #32: sibling WIs (#33 #34 #36 #37 #38 #39) build on these in
// parallel. Never rename or reshape a member; a WI that needs something else
// writes a local double in its own test file.
//
// Every async fake records the call when it starts, then waits on its
// [hold] completer when one is set (so a test can act while the call is in
// flight), then throws its [failure] when one is set (an [UpdateFailure], as
// the real ports do), and otherwise answers with its configured value.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

/// The text of the Appcast fixture [name] in `test/fixtures/updater/`
/// (`flutter test` runs with `app/` as the working directory).
String updaterFixture(String name) =>
    File('test/fixtures/updater/$name').readAsStringSync();

/// An [AppcastItem] built from run-time values. Defaults describe Release
/// `1.3.0` build `9`; [link] and [url] follow [shortVersionString] unless
/// given.
AppcastItem testAppcastItem({
  String shortVersionString = '1.3.0',
  String version = '9',
  String? url,
  String? notes,
  String? link,
  String edSignature = 'dGVzdC1zaWduYXR1cmU=',
  int? length = 1024,
  String minimumSystemVersion = '14.0',
}) => AppcastItem(
  version: version,
  shortVersionString: shortVersionString,
  url:
      url ??
      'https://github.com/connordodge/open_memex/releases/download/'
          'v$shortVersionString/Open-Memex-$shortVersionString-arm64.dmg',
  notes: notes ?? '## v$shortVersionString\n- Release notes',
  link:
      link ??
      'https://github.com/connordodge/open_memex/releases/tag/'
          'v$shortVersionString',
  edSignature: edSignature,
  length: length,
  minimumSystemVersion: minimumSystemVersion,
);

Future<void> _await(Completer<void>? hold) async {
  if (hold != null) await hold.future;
}

/// A fake [AppcastFetcher]: answers [items] (a copy) or throws [failure].
class FakeAppcastFetcher implements AppcastFetcher {
  FakeAppcastFetcher({List<AppcastItem>? items, this.failure})
    : items = items ?? [];

  /// The items the next fetch answers.
  List<AppcastItem> items;

  /// Thrown by the next fetch when set.
  UpdateFailure? failure;

  /// When set, a fetch waits for it before answering.
  Completer<void>? hold;

  /// How many fetches started.
  int fetchCount = 0;

  @override
  Future<List<AppcastItem>> fetch() async {
    fetchCount++;
    await _await(hold);
    final f = failure;
    if (f != null) throw f;
    return List.of(items);
  }
}

/// A fake [UpdateDownloader]: reports each of [progress] in order, then
/// throws [failure] or answers [dmgPath].
class FakeUpdateDownloader implements UpdateDownloader {
  /// The path a download answers.
  String dmgPath = '/updater-test/open-memex-update/Open-Memex-update.dmg';

  /// The progress values a download reports before it ends.
  List<double?> progress = [0.5, 1.0];

  /// Thrown by a download (after its progress) when set.
  UpdateFailure? failure;

  /// When set, a download waits for it before reporting progress.
  Completer<void>? hold;

  /// Every item a download started for, oldest first.
  final List<AppcastItem> downloads = [];

  /// The last download's progress callback, so a test can report progress
  /// while the download is held.
  void Function(double? progress)? onProgress;

  /// How many times the leftover download directory was deleted.
  int deleteLeftoversCount = 0;

  @override
  Future<String> download(
    AppcastItem item, {
    void Function(double? progress)? onProgress,
  }) async {
    downloads.add(item);
    this.onProgress = onProgress;
    await _await(hold);
    for (final p in progress) {
      onProgress?.call(p);
    }
    final f = failure;
    if (f != null) throw f;
    return dmgPath;
  }

  @override
  Future<void> deleteLeftovers() async {
    deleteLeftoversCount++;
  }
}

/// A fake [EdDsaVerifier] that never spawns an isolate (D6): completes, or
/// throws [failure].
class FakeEdDsaVerifier implements EdDsaVerifier {
  /// Thrown by a verify when set.
  UpdateFailure? failure;

  /// When set, a verify waits for it before answering.
  Completer<void>? hold;

  /// Every verify call, oldest first.
  final List<({String dmgPath, String edSignature})> calls = [];

  @override
  Future<void> verify({
    required String dmgPath,
    required String edSignature,
  }) async {
    calls.add((dmgPath: dmgPath, edSignature: edSignature));
    await _await(hold);
    final f = failure;
    if (f != null) throw f;
  }
}

/// A fake [InstallLocationCheck]: answers [bundlePath] or throws [failure].
class FakeInstallLocationCheck implements InstallLocationCheck {
  /// The bundle path a check answers.
  String bundlePath = '/Applications/Open Memex.app';

  /// Thrown by a check when set.
  UpdateFailure? failure;

  /// When set, a check waits for it before answering.
  Completer<void>? hold;

  /// How many checks started.
  int checkCount = 0;

  @override
  Future<String> check() async {
    checkCount++;
    await _await(hold);
    final f = failure;
    if (f != null) throw f;
    return bundlePath;
  }
}

/// A fake [InstallHelper]: records every start, or throws [failure].
class FakeInstallHelper implements InstallHelper {
  /// Thrown by a start when set.
  UpdateFailure? failure;

  /// When set, a start waits for it before answering.
  Completer<void>? hold;

  /// Every start, oldest first.
  final List<({int pid, String dmgPath, String bundlePath})> starts = [];

  @override
  Future<void> start({
    required int pid,
    required String dmgPath,
    required String bundlePath,
  }) async {
    starts.add((pid: pid, dmgPath: dmgPath, bundlePath: bundlePath));
    await _await(hold);
    final f = failure;
    if (f != null) throw f;
  }
}

/// A fake [FailureMarkerStore]: [take] answers [reason] and clears it, as
/// the real store clears the marker.
class FakeFailureMarkerStore implements FailureMarkerStore {
  FakeFailureMarkerStore({this.reason});

  /// The recorded reason; null for no marker.
  String? reason;

  /// How many takes ran.
  int takeCount = 0;

  @override
  Future<String?> take() async {
    takeCount++;
    final r = reason;
    reason = null;
    return r;
  }
}

/// A fake [LastCheckStore] holding [stamp] in memory.
class FakeLastCheckStore implements LastCheckStore {
  FakeLastCheckStore({this.stamp});

  /// The stamped time; null when never stamped.
  DateTime? stamp;

  /// Every stamp written, oldest first.
  final List<DateTime> writes = [];

  /// How many reads ran.
  int readCount = 0;

  @override
  Future<DateTime?> read() async {
    readCount++;
    return stamp;
  }

  @override
  Future<void> write(DateTime time) async {
    writes.add(time);
    stamp = time;
  }
}

/// The process-exit seam's double: records every exit type and answers
/// [response]. Override `appProcessExitProvider` with [call].
class RecordingProcessExit {
  /// What every exit answers.
  AppExitResponse response = AppExitResponse.exit;

  /// Every exit type, oldest first.
  final List<AppExitType> calls = [];

  Future<AppExitResponse> call(AppExitType type) async {
    calls.add(type);
    return response;
  }
}

/// The low-level updater seams' doubles (D6): nothing here touches the
/// network, the file system or a process.
class RecordingUpdaterIo {
  /// Every request a client from [clientFactory] received. Each answers
  /// [httpStatus] with an empty body.
  final List<http.Request> httpRequests = [];

  /// The status every request answers.
  int httpStatus = 404;

  /// Every folder [folderWritable] probed, oldest first.
  final List<String> writableProbes = [];

  /// What [folderWritable] answers.
  bool writable = true;

  /// Every [runHelper] call, oldest first.
  final List<({String executable, List<String> arguments})> helperRuns = [];

  /// The update download directory.
  String downloadDir = '/updater-test/open-memex-update';

  /// The running executable.
  String resolvedExecutable =
      '/Applications/Open Memex.app/Contents/MacOS/Open Memex';

  /// The failure marker's path.
  String failureMarkerFile =
      '/updater-test/Application Support/self_update_failure';

  /// An HTTP client factory answering every request with [httpStatus].
  http.Client clientFactory() => _RecordingClient(this);

  Future<bool> folderWritable(String folder) async {
    writableProbes.add(folder);
    return writable;
  }

  Future<void> runHelper(String executable, List<String> arguments) async {
    helperRuns.add((executable: executable, arguments: List.of(arguments)));
  }
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._io);

  final RecordingUpdaterIo _io;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) _io.httpRequests.add(request);
    return http.StreamedResponse(const Stream.empty(), _io.httpStatus);
  }
}

/// A fake [UpdateController]: holds [initial] until a test calls [emit],
/// records every call in [calls] and changes no state on its own.
///
/// [relaunch] runs `confirmQuit`, records its answer in
/// [confirmQuitAnswers] and returns [relaunchOutcome] when it is true,
/// [RelaunchOutcome.cancelled] when false. [launch] returns [launchResult].
///
/// Override with `updateControllerProvider.overrideWith(() => fake)`.
class FakeUpdateController extends UpdateController {
  FakeUpdateController([this.initial = const UpdateIdle()]);

  /// The state the controller builds with.
  final UpdateState initial;

  /// What [launch] returns.
  bool launchResult = false;

  /// What [relaunch] returns once `confirmQuit` answers true.
  RelaunchOutcome relaunchOutcome = RelaunchOutcome.exiting;

  /// Every call, oldest first: `launch`, `check(manual: true)`,
  /// `check(manual: false)`, `install`, `tryAgain`, `later`, `relaunch`.
  final List<String> calls = [];

  /// Every `confirmQuit` answer [relaunch] got, oldest first.
  final List<bool> confirmQuitAnswers = [];

  @override
  UpdateState build() => initial;

  /// The current state.
  UpdateState get current => state;

  /// Moves the controller to [next].
  void emit(UpdateState next) => state = next;

  @override
  Future<bool> launch() async {
    calls.add('launch');
    return launchResult;
  }

  @override
  Future<void> check({required bool manual}) async {
    calls.add('check(manual: $manual)');
  }

  @override
  Future<void> install() async {
    calls.add('install');
  }

  @override
  Future<void> tryAgain() async {
    calls.add('tryAgain');
  }

  @override
  void later() {
    calls.add('later');
  }

  @override
  Future<RelaunchOutcome> relaunch({
    required Future<bool> Function() confirmQuit,
  }) async {
    calls.add('relaunch');
    final confirmed = await confirmQuit();
    confirmQuitAnswers.add(confirmed);
    return confirmed ? relaunchOutcome : RelaunchOutcome.cancelled;
  }
}
