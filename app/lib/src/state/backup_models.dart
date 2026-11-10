// WI #321 (A0, D19): the frozen backup models. Every app backup WI (#322-#328)
// builds on these names and shapes; they change only by lead ruling.
//
// Each contract below is pinned by `test/state/backup_seam_test.dart`.
//
// Times: every instant is a UTC [DateTime]. JSON carries unix milliseconds
// (`backup-state.json`, the hosted `GET .../backup` body, `memex restore`'s
// `created_at`), and `fromJson` converts with `isUtc: true`.

/// Smallest and largest `--keep` (Spec req 12) and its default.
const int backupKeepMin = 1;
const int backupKeepMax = 365;
const int backupKeepDefault = 30;

/// One vault's backup settings, stored in `AppSettings.vaultBackups` keyed by
/// the local vault path as opened (req 21, D22).
///
/// Defaults: backups off, no destination, keep [backupKeepDefault], automatic
/// on. A [keep] outside [backupKeepMin]..[backupKeepMax] is rejected: the
/// constructor throws an [AssertionError] (debug) and `fromJson` throws a
/// [FormatException] (always).
class VaultBackupSettings {
  const VaultBackupSettings({
    this.enabled = false,
    this.destination,
    this.keep = backupKeepDefault,
    this.automatic = true,
  }) : assert(
         keep >= backupKeepMin && keep <= backupKeepMax,
         'keep must be $backupKeepMin to $backupKeepMax',
       );

  /// Reads `{"enabled":bool,"destination":string|null,"keep":int,
  /// "automatic":bool}`. A missing key takes its default; a value of the
  /// wrong type, or a keep out of range, throws [FormatException].
  factory VaultBackupSettings.fromJson(Map<String, Object?> json) {
    final keep = _readInt(json, 'keep') ?? backupKeepDefault;
    if (keep < backupKeepMin || keep > backupKeepMax) {
      throw FormatException(
        'keep must be $backupKeepMin to $backupKeepMax, got $keep',
      );
    }
    return VaultBackupSettings(
      enabled: _readBool(json, 'enabled') ?? false,
      destination: _readString(json, 'destination'),
      keep: keep,
      automatic: _readBool(json, 'automatic') ?? true,
    );
  }

  /// Whether backups are on for this vault.
  final bool enabled;

  /// The destination folder, absolute and with symlinks resolved (the form
  /// `backup-state.json` keys it by); null before one is chosen.
  final String? destination;

  /// How many backups the destination keeps (1-365).
  final int keep;

  /// "Back up automatically".
  final bool automatic;

  /// `{"enabled":…,"destination":…,"keep":…,"automatic":…}`; a null
  /// destination is written as JSON null.
  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'destination': destination,
    'keep': keep,
    'automatic': automatic,
  };

  /// A copy with the given fields replaced. [destination] cannot be cleared
  /// through this method (pass a new settings value instead).
  VaultBackupSettings copyWith({
    bool? enabled,
    String? destination,
    int? keep,
    bool? automatic,
  }) => VaultBackupSettings(
    enabled: enabled ?? this.enabled,
    destination: destination ?? this.destination,
    keep: keep ?? this.keep,
    automatic: automatic ?? this.automatic,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultBackupSettings &&
          other.enabled == enabled &&
          other.destination == destination &&
          other.keep == keep &&
          other.automatic == automatic;

  @override
  int get hashCode => Object.hash(enabled, destination, keep, automatic);

  @override
  String toString() => 'VaultBackupSettings(${toJson()})';
}

/// A cloud provider whose sync folder the destination picker can find.
enum BackupProvider {
  icloud,
  googleDrive,
  oneDrive;

  /// The id used in Keys and wire text: `icloud`, `google_drive`, `onedrive`.
  String get wireId => switch (this) {
    BackupProvider.icloud => 'icloud',
    BackupProvider.googleDrive => 'google_drive',
    BackupProvider.oneDrive => 'onedrive',
  };
}

/// One row of the destination picker (req 20): a provider's folder or
/// "Choose folder…".
class BackupDestinationOption {
  const BackupDestinationOption({
    this.provider,
    required this.label,
    this.path,
  });

  /// Null for "Choose folder…".
  final BackupProvider? provider;

  /// The row's text: the provider, or the account / name that tells two
  /// accounts apart.
  final String label;

  /// The destination this row makes (`<provider folder>/Open Memex Backups`);
  /// null for "Choose folder…", which asks the folder picker.
  final String? path;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupDestinationOption &&
          other.provider == provider &&
          other.label == label &&
          other.path == path;

  @override
  int get hashCode => Object.hash(provider, label, path);

  @override
  String toString() => 'BackupDestinationOption($provider, $label, $path)';
}

/// One destination's backup history (req 10a): a `backup-state.json` entry,
/// or the hosted `GET .../backup` body (req 30). A field the source doesn't
/// carry is null (or false for [inProgress]).
class BackupStatus {
  const BackupStatus({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.lastResult,
    this.lastError,
    this.lastFile,
    this.lastFileCreatedAt,
    this.lastBytes,
    this.lastFingerprint,
    this.enabled,
    this.keep,
    this.inProgress = false,
  });

  /// One `backup-state.json` destination entry (all keys of req 10a). A
  /// missing key is null; a wrong-typed value throws [FormatException].
  factory BackupStatus.fromStateJson(Map<String, Object?> json) => BackupStatus(
    lastAttemptAt: _readInstant(json, 'last_attempt_at'),
    lastSuccessAt: _readInstant(json, 'last_success_at'),
    lastResult: _readString(json, 'last_result'),
    lastError: _readString(json, 'last_error'),
    lastFile: _readString(json, 'last_file'),
    lastFileCreatedAt: _readInstant(json, 'last_file_created_at'),
    lastBytes: _readInt(json, 'last_bytes'),
    lastFingerprint: _readString(json, 'last_fingerprint'),
  );

  /// The hosted `GET .../backup` body (D17): the state keys except
  /// `last_fingerprint`, plus `enabled`, `keep` and `in_progress`. A missing
  /// key is null (`in_progress` false); a wrong-typed value throws
  /// [FormatException].
  factory BackupStatus.fromHostedJson(Map<String, Object?> json) =>
      BackupStatus(
        lastAttemptAt: _readInstant(json, 'last_attempt_at'),
        lastSuccessAt: _readInstant(json, 'last_success_at'),
        lastResult: _readString(json, 'last_result'),
        lastError: _readString(json, 'last_error'),
        lastFile: _readString(json, 'last_file'),
        lastFileCreatedAt: _readInstant(json, 'last_file_created_at'),
        lastBytes: _readInt(json, 'last_bytes'),
        enabled: _readBool(json, 'enabled'),
        keep: _readInt(json, 'keep'),
        inProgress: _readBool(json, 'in_progress') ?? false,
      );

  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;

  /// `created`, `unchanged` or the error code.
  final String? lastResult;
  final String? lastError;

  /// The last file a backup wrote there (a name, not a path).
  final String? lastFile;
  final DateTime? lastFileCreatedAt;
  final int? lastBytes;
  final String? lastFingerprint;

  /// Hosted only: whether the server has `--backup-dir`. Null for a local
  /// state entry.
  final bool? enabled;

  /// Hosted only: the server's `--backup-keep`.
  final int? keep;

  /// Hosted only: a backup is running on the server.
  final bool inProgress;

  /// True when the last attempt ended in an error code: [lastResult] is set
  /// and is neither `created` nor `unchanged` (req 24's warning rule).
  bool get lastAttemptFailed {
    final result = lastResult;
    return result != null && result != 'created' && result != 'unchanged';
  }

  /// True when a backup file was ever written there ([lastFile] is set).
  /// False reads as "Never" in the sheet.
  bool get hasBackup => lastFile != null;

  /// The `backup-state.json` entry shape (req 10a), times as unix ms.
  Map<String, Object?> toStateJson() => {
    'last_attempt_at': lastAttemptAt?.millisecondsSinceEpoch,
    'last_success_at': lastSuccessAt?.millisecondsSinceEpoch,
    'last_result': lastResult,
    'last_error': lastError,
    'last_file': lastFile,
    'last_file_created_at': lastFileCreatedAt?.millisecondsSinceEpoch,
    'last_bytes': lastBytes,
    'last_fingerprint': lastFingerprint,
  };

  /// The hosted `GET` body shape (D17), times as unix ms. A null [enabled] is
  /// written false.
  Map<String, Object?> toHostedJson() => {
    'enabled': enabled ?? false,
    'keep': keep,
    'in_progress': inProgress,
    'last_attempt_at': lastAttemptAt?.millisecondsSinceEpoch,
    'last_success_at': lastSuccessAt?.millisecondsSinceEpoch,
    'last_result': lastResult,
    'last_error': lastError,
    'last_file': lastFile,
    'last_file_created_at': lastFileCreatedAt?.millisecondsSinceEpoch,
    'last_bytes': lastBytes,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupStatus &&
          other.lastAttemptAt == lastAttemptAt &&
          other.lastSuccessAt == lastSuccessAt &&
          other.lastResult == lastResult &&
          other.lastError == lastError &&
          other.lastFile == lastFile &&
          other.lastFileCreatedAt == lastFileCreatedAt &&
          other.lastBytes == lastBytes &&
          other.lastFingerprint == lastFingerprint &&
          other.enabled == enabled &&
          other.keep == keep &&
          other.inProgress == inProgress;

  @override
  int get hashCode => Object.hash(
    lastAttemptAt,
    lastSuccessAt,
    lastResult,
    lastError,
    lastFile,
    lastFileCreatedAt,
    lastBytes,
    lastFingerprint,
    enabled,
    keep,
    inProgress,
  );

  @override
  String toString() =>
      'BackupStatus(${toStateJson()}, enabled: $enabled, '
      'keep: $keep, inProgress: $inProgress)';
}

/// The outcome of one `memex backup` run (D20).
sealed class BackupRunResult {
  const BackupRunResult();
}

/// Exit 0, `{"result":"created",...}`.
final class BackupCreated extends BackupRunResult {
  const BackupCreated({
    required this.file,
    required this.bytes,
    required this.fingerprint,
    this.removed = const [],
  });

  /// The new backup's absolute path.
  final String file;
  final int bytes;
  final String fingerprint;

  /// Absolute paths retention deleted.
  final List<String> removed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupCreated &&
          other.file == file &&
          other.bytes == bytes &&
          other.fingerprint == fingerprint &&
          _listEquals(other.removed, removed);

  @override
  int get hashCode =>
      Object.hash(file, bytes, fingerprint, Object.hashAll(removed));

  @override
  String toString() => 'BackupCreated($file, $bytes, $fingerprint, $removed)';
}

/// Exit 0, `{"result":"unchanged",...}`: `--if-changed` found nothing new.
final class BackupUnchanged extends BackupRunResult {
  const BackupUnchanged({this.lastFile});

  /// The absolute path of the last backup, or null when there never was one.
  final String? lastFile;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupUnchanged && other.lastFile == lastFile;

  @override
  int get hashCode => Object.hash(BackupUnchanged, lastFile);

  @override
  String toString() => 'BackupUnchanged($lastFile)';
}

/// A C1 failure (exit 1): [code] is the C1 error code, [message] its raw
/// message.
final class BackupFailure extends BackupRunResult {
  const BackupFailure({required this.code, required this.message});

  final String code;
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupFailure && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(BackupFailure, code, message);

  @override
  String toString() => 'BackupFailure($code, $message)';
}

/// Exit 2: this `memex` predates `backup` (whatever stderr says).
final class BackupTooOld extends BackupRunResult {
  const BackupTooOld();

  @override
  bool operator ==(Object other) => other is BackupTooOld;

  @override
  int get hashCode => (BackupTooOld).hashCode;

  @override
  String toString() => 'BackupTooOld()';
}

/// The `memex` binary could not be started (`ProcessException`).
final class BackupBinaryNotFound extends BackupRunResult {
  const BackupBinaryNotFound();

  @override
  bool operator ==(Object other) => other is BackupBinaryNotFound;

  @override
  int get hashCode => (BackupBinaryNotFound).hashCode;

  @override
  String toString() => 'BackupBinaryNotFound()';
}

/// The outcome of one `memex restore` run (D20).
sealed class RestoreRunResult {
  const RestoreRunResult();
}

/// Exit 0, `{"vault_id":…,"path":…,"created_at":…}`.
final class RestoreOk extends RestoreRunResult {
  const RestoreOk({
    required this.vaultId,
    required this.path,
    required this.createdAt,
  });

  final String vaultId;

  /// The restored vault's absolute path.
  final String path;

  /// When the backup was made (UTC).
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RestoreOk &&
          other.vaultId == vaultId &&
          other.path == path &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(vaultId, path, createdAt);

  @override
  String toString() => 'RestoreOk($vaultId, $path, $createdAt)';
}

/// A C1 failure (exit 1): [fields] are the C1 object's keys other than
/// `code` and `message` (`backup_too_new` carries `schema_version` and
/// `supported_schema_version`).
final class RestoreFailure extends RestoreRunResult {
  const RestoreFailure({
    required this.code,
    required this.message,
    this.fields = const {},
  });

  final String code;
  final String message;
  final Map<String, Object?> fields;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RestoreFailure &&
          other.code == code &&
          other.message == message &&
          _mapEquals(other.fields, fields);

  @override
  int get hashCode => Object.hash(
    code,
    message,
    // Order-independent, as map equality is.
    Object.hashAllUnordered(
      fields.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => 'RestoreFailure($code, $message, $fields)';
}

/// Exit 2: this `memex` predates `restore`.
final class RestoreTooOld extends RestoreRunResult {
  const RestoreTooOld();

  @override
  bool operator ==(Object other) => other is RestoreTooOld;

  @override
  int get hashCode => (RestoreTooOld).hashCode;

  @override
  String toString() => 'RestoreTooOld()';
}

/// The `memex` binary could not be started.
final class RestoreBinaryNotFound extends RestoreRunResult {
  const RestoreBinaryNotFound();

  @override
  bool operator ==(Object other) => other is RestoreBinaryNotFound;

  @override
  int get hashCode => (RestoreBinaryNotFound).hashCode;

  @override
  String toString() => 'RestoreBinaryNotFound()';
}

/// Which Backups sheet state a vault is in (req 19-31b, design option B).
/// Combined with [BackupViewState.hosted]: the spec's "hosted backing up" is
/// [backingUp] with `hosted: true`, and a hosted vault that has a result
/// shows [neverBackedUp], [success] or [error] as a local one does.
enum BackupSheetMode {
  /// Backups are off for this vault (local), with a "turn on" action.
  off,

  /// Local: choosing the destination (the provider list plus "Choose
  /// folder…").
  pickingDestination,

  /// Backups are on and nothing was ever written ("Never").
  neverBackedUp,

  /// A backup of this vault is running ("Backing up…").
  backingUp,

  /// The last attempt succeeded and wrote a file (or found nothing new).
  success,

  /// The last attempt failed: the message and a Retry action.
  error,

  /// Local: exit 2, this `memex` is too old to back up.
  memexTooOld,

  /// Local: the `memex` binary was not found.
  binaryNotFound,

  /// Hosted: the server has no `--backup-dir` (or answered 409
  /// `backups_not_configured`).
  hostedNotConfigured,

  /// Hosted: the server cannot be reached.
  hostedUnreachable,

  /// Hosted: the server answered 404 `not_found` for `GET .../backup`.
  hostedServerTooOld,
}

/// Everything the Backups sheet and the sidebar entry show for one vault
/// (D19, D23). The controller builds it; the sheet, the entry and the
/// warning only read it.
class BackupViewState {
  const BackupViewState({
    required this.mode,
    this.hosted = false,
    this.settings,
    this.status,
    this.errorCode,
    this.message,
    this.options = const [],
    this.warning = false,
  });

  final BackupSheetMode mode;

  /// The vault is a hosted vault (settings are the server's, read-only).
  final bool hosted;

  /// A local vault's settings as stored; null for a hosted vault.
  final VaultBackupSettings? settings;

  /// The last known history; null when there is none.
  final BackupStatus? status;

  /// For [BackupSheetMode.error]: the error code (a C1 code, or the code of
  /// an unrecorded failure kept in memory).
  final String? errorCode;

  /// For [BackupSheetMode.error] and the too-old / not-found states: the
  /// plain-language text from `backup_messages.dart` (req 22a).
  final String? message;

  /// For [BackupSheetMode.pickingDestination]: the rows to list.
  final List<BackupDestinationOption> options;

  /// The entry's automatic-failure warning (req 24, 31a): on until a later
  /// backup to the destination succeeds; never on while backups are off.
  final bool warning;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupViewState &&
          other.mode == mode &&
          other.hosted == hosted &&
          other.settings == settings &&
          other.status == status &&
          other.errorCode == errorCode &&
          other.message == message &&
          _listEquals(other.options, options) &&
          other.warning == warning;

  @override
  int get hashCode => Object.hash(
    mode,
    hosted,
    settings,
    status,
    errorCode,
    message,
    Object.hashAll(options),
    warning,
  );

  @override
  String toString() =>
      'BackupViewState($mode, hosted: $hosted, settings: $settings, '
      'status: $status, errorCode: $errorCode, message: $message, '
      'options: $options, warning: $warning)';
}

// JSON readers: a missing or null key is null; any other type is a
// FormatException.

String? _readString(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is String) return v;
  throw FormatException('"$key" must be a string, got ${v.runtimeType}');
}

int? _readInt(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is int) return v;
  throw FormatException('"$key" must be an integer, got ${v.runtimeType}');
}

bool? _readBool(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is bool) return v;
  throw FormatException('"$key" must be a boolean, got ${v.runtimeType}');
}

DateTime? _readInstant(Map<String, Object?> json, String key) {
  final ms = _readInt(json, key);
  return ms == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}
