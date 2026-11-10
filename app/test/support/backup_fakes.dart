// WI #321 (A0, D19): the fakes of the backup seams. A0 only: A1-A6 use them
// and never edit this file (a missing capability goes to the lead-315-c
// ruling). Every fake reproduces the real failure modes: exit 2 ("too old")
// and a spawn failure ("binary not found") are distinct results, an
// unreachable vault server is thrown (never returned) as the real
// `VaultUnreachableException`, and a file-system refusal is a real
// `FileSystemException`.
import 'dart:async';
import 'dart:io';

import 'package:open_memex_app/src/cli/backup_cli.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_state_reader.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// FakeBackupRunner
// ---------------------------------------------------------------------------

/// One recorded runner call, in call order.
sealed class FakeRunnerCall {
  const FakeRunnerCall();
}

/// A recorded `backup` call and its arguments.
class FakeBackupCall extends FakeRunnerCall {
  const FakeBackupCall({
    required this.vaultPath,
    required this.destination,
    required this.keep,
    required this.ifChanged,
  });

  final String vaultPath;
  final String destination;
  final int keep;
  final bool ifChanged;

  @override
  String toString() =>
      'FakeBackupCall($vaultPath, $destination, keep: $keep, '
      'ifChanged: $ifChanged)';
}

/// A recorded `restore` call and its arguments.
class FakeRestoreCall extends FakeRunnerCall {
  const FakeRestoreCall({required this.from, required this.to});

  final String from;
  final String to;

  @override
  String toString() => 'FakeRestoreCall($from, $to)';
}

/// A [BackupRunner] that records every call with its arguments, in order,
/// and answers from scripted results. A test holds a run open with
/// [holdRuns] to test "in flight".
class FakeBackupRunner implements BackupRunner {
  /// Every `backup` and `restore` call, in call order.
  final List<FakeRunnerCall> calls = [];

  /// The `backup` calls only, in order.
  List<FakeBackupCall> get backupCalls =>
      calls.whereType<FakeBackupCall>().toList();

  /// The `restore` calls only, in order.
  List<FakeRestoreCall> get restoreCalls =>
      calls.whereType<FakeRestoreCall>().toList();

  /// Answers each `backup` call from the front of this queue; once it is
  /// empty, [defaultBackupResult].
  final List<BackupRunResult> backupScript = [];

  /// Answers each `restore` call from the front of this queue; once it is
  /// empty, [RestoreOk] at the call's `to`.
  final List<RestoreRunResult> restoreScript = [];

  /// What a `backup` call answers when [backupScript] is empty.
  BackupRunResult defaultBackupResult = const BackupCreated(
    file:
        '/fake-backups/Notes-20261109T090000Z-01HV0000000000000000000000'
        '.memex.zip',
    bytes: 1024,
    fingerprint: 'f1',
  );

  /// Runs after a call is recorded and before it answers (a test updates the
  /// fake state file here, the way a real run does).
  FutureOr<void> Function(FakeRunnerCall call)? onCall;

  Completer<void>? _hold;
  int _inFlight = 0;

  /// Calls started and not yet answered.
  int get inFlight => _inFlight;

  /// From now on every call waits, after it is recorded, until the returned
  /// completer completes. Call it again to hold later calls on a new one.
  Completer<void> holdRuns() => _hold = Completer<void>();

  /// Script one `backup` result.
  void scriptBackup(BackupRunResult result) => backupScript.add(result);

  /// Script one `restore` result.
  void scriptRestore(RestoreRunResult result) => restoreScript.add(result);

  Future<void> _enter(FakeRunnerCall call) async {
    calls.add(call);
    _inFlight++;
    try {
      await onCall?.call(call);
      final hold = _hold;
      if (hold != null) await hold.future;
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<BackupRunResult> backup({
    required String vaultPath,
    required String destination,
    required int keep,
    required bool ifChanged,
  }) async {
    await _enter(
      FakeBackupCall(
        vaultPath: vaultPath,
        destination: destination,
        keep: keep,
        ifChanged: ifChanged,
      ),
    );
    return backupScript.isEmpty
        ? defaultBackupResult
        : backupScript.removeAt(0);
  }

  @override
  Future<RestoreRunResult> restore({
    required String from,
    required String to,
  }) async {
    await _enter(FakeRestoreCall(from: from, to: to));
    return restoreScript.isEmpty
        ? RestoreOk(
            vaultId: '01HV0000000000000000000000',
            path: to,
            createdAt: DateTime.utc(2026, 11, 9, 9),
          )
        : restoreScript.removeAt(0);
  }
}

// ---------------------------------------------------------------------------
// FakeBackupStateReader
// ---------------------------------------------------------------------------

/// One recorded `read`.
class FakeStateRead {
  const FakeStateRead(this.vaultPath, this.destination);

  final String vaultPath;
  final String destination;

  @override
  String toString() => 'FakeStateRead($vaultPath, $destination)';
}

/// A [BackupStateReader] over an in-memory map. Like the real reader it
/// finds an entry by the exact destination string and answers null for a
/// vault or destination it has nothing for. It never throws.
class FakeBackupStateReader implements BackupStateReader {
  final Map<(String, String), BackupStatus> _entries = {};

  /// Every `read` call, in order.
  final List<FakeStateRead> reads = [];

  /// Sets what `<vaultPath>/backup-state.json` holds for [destination].
  void setEntry(String vaultPath, String destination, BackupStatus status) {
    _entries[(vaultPath, destination)] = status;
  }

  /// Removes the entry (a missing file or entry reads as null).
  void clearEntry(String vaultPath, String destination) {
    _entries.remove((vaultPath, destination));
  }

  @override
  Future<BackupStatus?> read({
    required String vaultPath,
    required String destination,
  }) async {
    reads.add(FakeStateRead(vaultPath, destination));
    return _entries[(vaultPath, destination)];
  }
}

// ---------------------------------------------------------------------------
// FakeHostedBackupApi
// ---------------------------------------------------------------------------

/// A [HostedBackupApi] with scripted answers. An unreachable server is
/// thrown as the real [VaultUnreachableException], never returned.
class FakeHostedBackupApi implements HostedBackupApi {
  /// Every call, in order: `status` or `start`.
  final List<String> calls = [];

  int get statusCalls => calls.where((c) => c == 'status').length;
  int get startCalls => calls.where((c) => c == 'start').length;

  /// What `status` answers when [statusScript] is empty: a server with
  /// backups on, nothing backed up yet.
  HostedBackupResult defaultStatus = const HostedBackupOk(
    BackupStatus(enabled: true, keep: 30),
  );

  /// What `start` answers when [startScript] is empty: 202 with the server
  /// backing up.
  HostedBackupResult defaultStart = const HostedBackupOk(
    BackupStatus(enabled: true, keep: 30, inProgress: true),
  );

  /// Each entry is a [HostedBackupResult] to return or an [Exception] to
  /// throw, consumed in order.
  final List<Object> statusScript = [];
  final List<Object> startScript = [];

  /// When set, every call throws it (the server cannot be reached).
  VaultUnreachableException? unreachable;

  Completer<void>? _holdStart;

  /// From now on `start` waits for the returned completer.
  Completer<void> holdStart() => _holdStart = Completer<void>();

  /// Script one `status` answer: a [HostedBackupResult] or an exception.
  void scriptStatus(Object resultOrError) => statusScript.add(resultOrError);

  /// Script one `start` answer.
  void scriptStart(Object resultOrError) => startScript.add(resultOrError);

  /// Every later call throws a [VaultUnreachableException] for [serverName].
  void goUnreachable({
    String serverName = 'nas',
    bool mayHaveCommitted = false,
  }) {
    unreachable = VaultUnreachableException(
      serverName: serverName,
      mayHaveCommitted: mayHaveCommitted,
    );
  }

  /// The server answers again.
  void comeBack() => unreachable = null;

  HostedBackupResult _answer(List<Object> script, HostedBackupResult fallback) {
    final next = script.isEmpty ? fallback : script.removeAt(0);
    if (next is HostedBackupResult) return next;
    throw next;
  }

  @override
  Future<HostedBackupResult> status() async {
    calls.add('status');
    final down = unreachable;
    if (down != null) throw down;
    return _answer(statusScript, defaultStatus);
  }

  @override
  Future<HostedBackupResult> start() async {
    calls.add('start');
    final down = unreachable;
    if (down != null) throw down;
    final hold = _holdStart;
    if (hold != null) await hold.future;
    return _answer(startScript, defaultStart);
  }
}

// ---------------------------------------------------------------------------
// FakeCloudFolderProbe
// ---------------------------------------------------------------------------

/// The default fake home. Never the real home folder.
const fakeHome = '/Users/tester';

enum _Kind { dir, file, link }

class _Entry {
  _Entry(this.kind, [this.target]);

  final _Kind kind;
  final String? target;
}

/// A [CloudFolderProbe] over an in-memory tree under a fake home: nothing
/// reaches the real file system, so no test sees the real `~/Library`.
/// Entries list in insertion order (a real folder's order is unspecified, so
/// a caller must sort). Failures are real [FileSystemException]s.
class FakeCloudFolderProbe implements CloudFolderProbe {
  FakeCloudFolderProbe({String home = fakeHome}) : _home = home {
    addDirectory(home);
  }

  final String _home;
  final Map<String, _Entry> _tree = {'/': _Entry(_Kind.dir)};
  final Set<String> _denied = {};

  /// Every call, in order, as `<method> <path>` (`home` has no path).
  final List<String> calls = [];

  /// The resolved path of each successful `createDirectory` call, in order.
  final List<String> createdDirectories = [];

  /// `<home>/Library/Mobile Documents/com~apple~CloudDocs`.
  String get icloudFolder =>
      p.posix.join(_home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs');

  /// `<home>/Library/CloudStorage/GoogleDrive-<account>/My Drive`.
  String googleDriveFolder(String account) => p.posix.join(
    _home,
    'Library',
    'CloudStorage',
    'GoogleDrive-$account',
    'My Drive',
  );

  /// `<home>/Library/CloudStorage/OneDrive-<name>`.
  String oneDriveFolder(String name) =>
      p.posix.join(_home, 'Library', 'CloudStorage', 'OneDrive-$name');

  /// Installs iCloud Drive.
  void seedIcloud() => addDirectory(icloudFolder);

  /// Installs a Google Drive account.
  void seedGoogleDrive(String account) =>
      addDirectory(googleDriveFolder(account));

  /// Installs a OneDrive account.
  void seedOneDrive(String name) => addDirectory(oneDriveFolder(name));

  /// Adds the folder [path] and every missing parent.
  void addDirectory(String path) {
    var current = '/';
    for (final part in p.posix.split(p.posix.normalize(path)).skip(1)) {
      current = p.posix.join(current, part);
      _tree.putIfAbsent(current, () => _Entry(_Kind.dir));
    }
  }

  /// Adds a file (and its parent folders).
  void addFile(String path) {
    addDirectory(p.posix.dirname(path));
    _tree[p.posix.normalize(path)] = _Entry(_Kind.file);
  }

  /// Adds a symbolic link at [link] pointing at the absolute path [target].
  void addSymlink(String link, String target) {
    addDirectory(p.posix.dirname(link));
    _tree[p.posix.normalize(link)] = _Entry(_Kind.link, target);
  }

  /// `createDirectory` of [path] or anything below it fails with a
  /// permission error (the macOS Files and Folders refusal).
  void denyCreate(String path) => _denied.add(p.posix.normalize(path));

  FileSystemException _error(
    String message,
    String path,
    String os,
    int code,
  ) => FileSystemException(message, path, OSError(os, code));

  /// [path] with symlinks resolved, or null when a component is missing.
  String? _resolve(String path) {
    var pending = p.posix.split(p.posix.normalize(path)).skip(1).toList();
    var current = '/';
    var hops = 0;
    while (pending.isNotEmpty) {
      final part = pending.removeAt(0);
      final next = p.posix.join(current, part);
      final entry = _tree[next];
      if (entry == null) return null;
      if (entry.kind == _Kind.link) {
        if (++hops > 32) return null;
        pending = [
          ...p.posix.split(p.posix.normalize(entry.target!)).skip(1),
          ...pending,
        ];
        current = '/';
        continue;
      }
      current = next;
    }
    return current;
  }

  @override
  Future<String> home() async {
    calls.add('home');
    return _home;
  }

  @override
  Future<bool> isDirectory(String path) async {
    calls.add('isDirectory $path');
    final resolved = _resolve(path);
    return resolved != null && _tree[resolved]!.kind == _Kind.dir;
  }

  @override
  Future<List<String>> listNames(String directory) async {
    calls.add('listNames $directory');
    final resolved = _resolve(directory);
    if (resolved == null) {
      throw _error(
        'Directory listing failed',
        directory,
        'No such file or directory',
        2,
      );
    }
    if (_tree[resolved]!.kind != _Kind.dir) {
      throw _error(
        'Directory listing failed',
        directory,
        'Not a directory',
        20,
      );
    }
    return [
      for (final e in _tree.entries)
        if (e.key != resolved && p.posix.dirname(e.key) == resolved)
          p.posix.basename(e.key),
    ];
  }

  @override
  Future<void> createDirectory(String path) async {
    calls.add('createDirectory $path');
    final normal = p.posix.normalize(path);
    for (final denied in _denied) {
      if (normal == denied || p.posix.isWithin(denied, normal)) {
        throw _error('Creation failed', path, 'Operation not permitted', 1);
      }
    }
    var current = '/';
    for (final part in p.posix.split(normal).skip(1)) {
      final next = p.posix.join(current, part);
      final entry = _tree[next];
      if (entry == null) {
        _tree[next] = _Entry(_Kind.dir);
        current = next;
        continue;
      }
      final resolved = entry.kind == _Kind.link ? _resolve(next) : next;
      if (resolved == null || _tree[resolved]!.kind != _Kind.dir) {
        throw _error('Creation failed', path, 'Not a directory', 20);
      }
      current = resolved;
    }
    createdDirectories.add(current);
  }

  @override
  Future<String> resolveSymbolicLinks(String path) async {
    calls.add('resolveSymbolicLinks $path');
    final resolved = _resolve(path);
    if (resolved == null) {
      throw _error(
        'Cannot resolve symbolic links',
        path,
        'No such file or directory',
        2,
      );
    }
    return resolved;
  }
}

// ---------------------------------------------------------------------------
// FakeBackupController
// ---------------------------------------------------------------------------

/// A [BackupController] a test drives by hand: it records each call, and a
/// test sets any vault's view state with [setViewState].
class FakeBackupController extends BackupController {
  FakeBackupController([super.initial = const {}]);

  /// Each `backUpNow` call's vault, in order.
  final List<VaultRef> backUpNowCalls = [];

  /// Each `openSheet` call's vault, in order.
  final List<VaultRef> openSheetCalls = [];

  /// Each `closeSheet` call's vault, in order.
  final List<VaultRef> closeSheetCalls = [];

  Completer<void>? _holdBackUpNow;

  /// From now on `backUpNow` waits for the returned completer.
  Completer<void> holdBackUpNow() => _holdBackUpNow = Completer<void>();

  /// Shows [view] for [vault]; widgets watching the provider rebuild.
  void setViewState(VaultRef vault, BackupViewState view) {
    state = {...state, vault: view};
  }

  @override
  BackupViewState viewStateOf(VaultRef vault) =>
      state[vault] ??
      BackupViewState(
        mode: BackupSheetMode.off,
        hosted: vault is HostedVaultRef,
      );

  @override
  Future<void> backUpNow(VaultRef vault) async {
    backUpNowCalls.add(vault);
    final hold = _holdBackUpNow;
    if (hold != null) await hold.future;
  }

  @override
  void openSheet(VaultRef vault) => openSheetCalls.add(vault);

  @override
  void closeSheet(VaultRef vault) => closeSheetCalls.add(vault);
}
