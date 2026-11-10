// WI #325 (A4, D24): the Backups sheet, every local and hosted state (Spec
// #315 reqs 19-22a, 25, 26, 31, 31b, 37; design pack
// design/315-vault-backups/packs/325.md, boards B2, B3, B4; lead rulings in
// the WI body).
//
// The sheet renders the controller's view state (`backupControllerProvider`,
// a `FakeBackupController` here) and calls the controller and the settings
// save. It holds no schedule, CLI or polling logic. Every test opens the sheet
// with `showBackupsSheet` from a launcher button, under a child container of
// the A0 harness container that adds a recording settings save (the harness
// leaves `saveVaultBackupSettingsProvider` to A2).
//
// Copy owned by A1 (`backup_messages.dart`: failure messages, `backupWhen`,
// `backupSize`) is never hard-coded: the expected text is computed by calling
// the message function, so these tests read the real copy once A1 lands.
// Copy owned by this WI (titles, labels, the req 25 and req 26 lines, the
// hosted text) is asserted verbatim from pack 325.
//
// Destination discovery is A2's `discoverBackupDestinations`: the tests that
// list discovered rows compute the expected rows by calling it on the same
// fake probe, so they hold against the stub (no rows but "choose folder…")
// and against A2's real discovery alike.
//
// flutter_test draws every font as Ahem (one em per glyph), so content tests
// use a tall window; the layout tests use the real widths.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, Link;
import 'dart:ui' show CheckedState, PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart'
    show hostedUnreachableMessage;
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';
import 'package:open_memex_app/src/widgets/backups/backups_sheet.dart';

import '../../support/backup_fakes.dart';
import '../../support/backup_harness.dart';
import '../../support/fake_clock.dart';
import '../../support/file_picker_fakes.dart';
import '../../support/font_fetch_hold.dart';

// ------------------------------------------------------------------ fixtures

const _local = LocalVaultRef('/Users/tester/vaults/work');
const _hosted = HostedVaultRef('srv-1', 'work');
const _binary = '/Users/connor/.cargo/bin/memex';

const _home = fakeHome;
const _backupsFolder = 'Open Memex Backups';
const _icloudRoot = '$_home/Library/Mobile Documents/com~apple~CloudDocs';
const _googleRoot =
    '$_home/Library/CloudStorage/GoogleDrive-connor@example.com/My Drive';
const _google2Root =
    '$_home/Library/CloudStorage/GoogleDrive-work@example.com/My Drive';
const _oneDriveRoot = '$_home/Library/CloudStorage/OneDrive-Personal';
const _icloudDest = '$_icloudRoot/$_backupsFolder';
const _googleDest = '$_googleRoot/$_backupsFolder';
const _google2Dest = '$_google2Root/$_backupsFolder';
const _oneDriveDest = '$_oneDriveRoot/$_backupsFolder';
const _chosenDest = '/Volumes/nas/memex-backups';
const _otherChosenDest = '/Volumes/disk/other-backups';

const _icloudOption = BackupDestinationOption(
  provider: BackupProvider.icloud,
  label: 'iCloud Drive',
  path: _icloudDest,
);
const _googleOption = BackupDestinationOption(
  provider: BackupProvider.googleDrive,
  label: 'Google Drive · connor@example.com',
  path: _googleDest,
);
const _google2Option = BackupDestinationOption(
  provider: BackupProvider.googleDrive,
  label: 'Google Drive · work@example.com',
  path: _google2Dest,
);
const _oneDriveOption = BackupDestinationOption(
  provider: BackupProvider.oneDrive,
  label: 'OneDrive · Personal',
  path: _oneDriveDest,
);
const _chooseOption = BackupDestinationOption(label: 'Choose folder…');
const _allOptions = [
  _icloudOption,
  _googleOption,
  _google2Option,
  _oneDriveOption,
  _chooseOption,
];

/// The sheet's clock: 9 Nov 2026, 15:00 local.
final _now = DateTime(2026, 11, 9, 15);

final _created = DateTime.utc(2026, 11, 9, 14, 3, 12);
const _file = 'memex-20261109T140312Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip';
const _bytes = 41200000;
final _yesterdayCreated = DateTime.utc(2026, 11, 8, 9, 2);
const _yesterdayFile =
    'memex-20261108T090200Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip';
const _yesterdayBytes = 41000000;
final _failedAt = DateTime.utc(2026, 11, 9, 9);

const _hostedFile =
    'work-20261109T030004Z-01JB2K7M4N6P8Q0R2S4T6V8W0X.memex.zip';
final _hostedCreated = DateTime.utc(2026, 11, 9, 3, 0, 4);
const _hostedBytes = 18600000;

const _on = VaultBackupSettings(
  enabled: true,
  destination: _googleDest,
  keep: 30,
  automatic: true,
);

// Copy owned by this WI (pack 325), verbatim.
const _offTitle = 'backups are off';
const _offBody =
    'pick a folder in icloud drive, google drive or onedrive and that app '
    'uploads each backup. a nas share or an external disk works too.';
const _offLead =
    'a backup is one .memex.zip file of this vault — notes, block ids, review '
    "state, smart folders, canvases and attachments — made safely while it's "
    'open.';
const _turnOnEllipsis = 'turn on backups…';
const _pickTitle = 'choose where backups go';
const _pickBody =
    'open memex writes each backup there as one finished file; the '
    "provider's own app uploads it.";
const _noProviderSub =
    'no icloud drive, google drive or onedrive folder on this mac. install '
    "the provider's app and sign in, then reopen this sheet — or choose any "
    'folder.';
const _pickNote =
    'a provider gets an Open Memex Backups folder. macOS may ask whether open '
    'memex can use it — choose allow.';
const _neverTitle = 'no backup yet';
const _neverBody = 'the first automatic backup runs within the hour.';
const _backingUpTitle = 'backing up…';
const _backingUpBody =
    "keep writing — the backup reads a snapshot and doesn't block the vault.";
const _backUpNow = 'back up now';
const _req25 =
    "vaults that aren't open in open memex are backed up only by a memex "
    'backup you schedule — see docs/backups.md.';
const _oldFolderNote =
    "the old folder's backups stay where they are. turning backups off "
    'deletes none.';
const _turnOff = 'turn off backups';
const _hostedCommand =
    'memex serve --root <root> --listen <host:port> --backup-dir <dir>';
const _docs = 'docs/backups.md';
const _notConfiguredTitle = 'backups are set on the vault server';
const _notConfiguredBody =
    "nas wasn't started with a backup folder, so it doesn't back up work. add "
    '--backup-dir to memex serve on nas:';
const _unreachableBody = 'its backups show as soon as nas answers.';
const _tooOldTitle = "nas doesn't support backups yet";
const _tooOldBody =
    'update memex on nas and restart memex serve, then reopen this sheet.';

String _providerLine(String provider) =>
    'saved to Open Memex Backups in $provider. the $provider app uploads it; '
    "open memex can't see when that's done.";

// Local-only Keys the design adds (pack 325, "Mismatches").
const _closeKey = Key('backups-close');
const _cancelKey = Key('backups-cancel');
const _turnOnKey = Key('backups-turn-on');
const _menuKey = Key('backups-destination-menu');
const _keepDecKey = Key('backups-keep-dec');
const _keepIncKey = Key('backups-keep-inc');
const _copyCommandKey = Key('backups-copy-command');
const _guideLinkKey = Key('backups-guide-link');
const _closeButtonKey = Key('backups-close-button');
const _launcherKey = Key('325-open-sheet');

/// The Keys of the four provider rows over the harness probe, in the order
/// A2's discovery lists them: iCloud, Google Drive (connor, work), OneDrive.
final _discoveredKeys = [
  backupDestinationKey(BackupProvider.icloud, 0),
  backupDestinationKey(BackupProvider.googleDrive, 0),
  backupDestinationKey(BackupProvider.googleDrive, 1),
  backupDestinationKey(BackupProvider.oneDrive, 0),
];

// Content tests: tall enough for the whole sheet in Ahem.
const _tall = Size(1280, 4000);

final _sheet = find.byKey(backupsSheetKey);

// ------------------------------------------------------------------ states

BackupStatus _successStatus() => BackupStatus(
  lastAttemptAt: DateTime.utc(2026, 11, 9, 14, 50),
  // A later unchanged run: the card's time is still the file's.
  lastSuccessAt: DateTime.utc(2026, 11, 9, 14, 50),
  lastResult: 'unchanged',
  lastFile: _file,
  lastFileCreatedAt: _created,
  lastBytes: _bytes,
);

BackupStatus _failedStatus(String code, {String? raw, bool withGood = true}) =>
    BackupStatus(
      lastAttemptAt: _failedAt,
      lastSuccessAt: withGood ? _yesterdayCreated : null,
      lastResult: code,
      lastError: raw,
      lastFile: withGood ? _yesterdayFile : null,
      lastFileCreatedAt: withGood ? _yesterdayCreated : null,
      lastBytes: withGood ? _yesterdayBytes : null,
    );

BackupMessage _localFailure(
  String code, {
  String? raw,
  bool automatic = true,
  String destination = _googleDest,
  BackupProvider? provider = BackupProvider.googleDrive,
}) => backupFailureMessage(
  code: code,
  message: raw,
  automatic: automatic,
  failedAt: _failedAt,
  now: _now,
  destination: destination,
  provider: provider,
);

BackupMessage _hostedFailure(
  String code, {
  String? raw,
  bool automatic = true,
}) => backupFailureMessage(
  code: code,
  message: raw,
  automatic: automatic,
  failedAt: _failedAt,
  now: _now,
  serverName: 'nas',
);

BackupViewState _offView() => const BackupViewState(
  mode: BackupSheetMode.off,
  settings: VaultBackupSettings(),
);

BackupViewState _pickingView([
  List<BackupDestinationOption> options = _allOptions,
]) => BackupViewState(
  mode: BackupSheetMode.pickingDestination,
  settings: const VaultBackupSettings(),
  options: options,
);

BackupViewState _neverView([VaultBackupSettings settings = _on]) =>
    BackupViewState(mode: BackupSheetMode.neverBackedUp, settings: settings);

BackupViewState _backingUpView([VaultBackupSettings settings = _on]) =>
    BackupViewState(
      mode: BackupSheetMode.backingUp,
      settings: settings,
      status: _successStatus(),
    );

BackupViewState _successView([VaultBackupSettings settings = _on]) =>
    BackupViewState(
      mode: BackupSheetMode.success,
      settings: settings,
      status: _successStatus(),
    );

BackupViewState _errorView(
  String code, {
  String? raw,
  VaultBackupSettings settings = _on,
  bool withGood = true,
  bool automatic = true,
}) => BackupViewState(
  mode: BackupSheetMode.error,
  settings: settings,
  status: _failedStatus(code, raw: raw, withGood: withGood),
  errorCode: code,
  message: _localFailure(
    code,
    raw: raw,
    automatic: automatic,
    destination: settings.destination ?? _googleDest,
  ),
  automatic: automatic,
  failedAt: _failedAt,
  warning: true,
);

BackupViewState _tooOldView() => BackupViewState(
  mode: BackupSheetMode.memexTooOld,
  settings: _on,
  message: backupTooOldMessage(),
  warning: true,
);

BackupViewState _binaryNotFoundView() => BackupViewState(
  mode: BackupSheetMode.binaryNotFound,
  settings: _on,
  message: backupBinaryNotFoundMessage(),
  warning: true,
);

BackupStatus _hostedStatus({bool inProgress = false, int? keep = 30}) =>
    BackupStatus(
      lastAttemptAt: _hostedCreated,
      lastSuccessAt: _hostedCreated,
      lastResult: 'created',
      lastFile: _hostedFile,
      lastFileCreatedAt: _hostedCreated,
      lastBytes: _hostedBytes,
      enabled: true,
      keep: keep,
      inProgress: inProgress,
    );

BackupViewState _hostedSuccessView() => BackupViewState(
  mode: BackupSheetMode.success,
  hosted: true,
  status: _hostedStatus(),
);

BackupViewState _hostedNeverView() => const BackupViewState(
  mode: BackupSheetMode.neverBackedUp,
  hosted: true,
  status: BackupStatus(enabled: true, keep: 30),
);

BackupViewState _hostedBackingUpView() => BackupViewState(
  mode: BackupSheetMode.backingUp,
  hosted: true,
  status: _hostedStatus(inProgress: true),
);

BackupViewState _hostedErrorView() => BackupViewState(
  mode: BackupSheetMode.error,
  hosted: true,
  status: BackupStatus(
    lastAttemptAt: _failedAt,
    lastSuccessAt: _yesterdayCreated,
    lastResult: 'backup_destination_unavailable',
    lastError: 'permission denied',
    lastFile: _hostedFile,
    lastFileCreatedAt: _yesterdayCreated,
    lastBytes: _hostedBytes,
    enabled: true,
    keep: 30,
  ),
  errorCode: 'backup_destination_unavailable',
  message: _hostedFailure(
    'backup_destination_unavailable',
    raw: 'permission denied',
  ),
  automatic: true,
  failedAt: _failedAt,
  warning: true,
);

BackupViewState _hostedNotConfiguredView() => const BackupViewState(
  mode: BackupSheetMode.hostedNotConfigured,
  hosted: true,
  status: BackupStatus(enabled: false),
);

BackupViewState _hostedUnreachableView() => const BackupViewState(
  mode: BackupSheetMode.hostedUnreachable,
  hosted: true,
);

BackupViewState _hostedTooOldView() => const BackupViewState(
  mode: BackupSheetMode.hostedServerTooOld,
  hosted: true,
);

/// A hosted vault the controller has not read yet reads as `off` (A0's
/// contract: "a vault the controller hasn't seen reads as off").
BackupViewState _hostedUnreadView() =>
    const BackupViewState(mode: BackupSheetMode.off, hosted: true);

/// Every state the sheet draws, for the layout sweeps.
List<(String, VaultRef, BackupViewState)> _everyState() => [
  ('off', _local, _offView()),
  ('picking', _local, _pickingView()),
  ('picking none found', _local, _pickingView(const [_chooseOption])),
  ('never', _local, _neverView()),
  ('backing up', _local, _backingUpView()),
  ('success', _local, _successView()),
  ('error', _local, _errorView('backup_destination_unavailable')),
  ('memex too old', _local, _tooOldView()),
  ('binary not found', _local, _binaryNotFoundView()),
  ('hosted success', _hosted, _hostedSuccessView()),
  ('hosted never', _hosted, _hostedNeverView()),
  ('hosted backing up', _hosted, _hostedBackingUpView()),
  ('hosted error', _hosted, _hostedErrorView()),
  ('hosted not configured', _hosted, _hostedNotConfiguredView()),
  ('hosted unreachable', _hosted, _hostedUnreachableView()),
  ('hosted too old', _hosted, _hostedTooOldView()),
  ('hosted not read yet', _hosted, _hostedUnreadView()),
];

// ------------------------------------------------------------------ harness

/// Local settings as the test's save stores them, read back through the
/// overridden `vaultBackupSettingsProvider`.
final _wi325SettingsStore = StateProvider<Map<String, VaultBackupSettings>>(
  (_) => const {},
);

typedef _Wi325Save = ({String path, VaultBackupSettings settings});

/// What a test drives and inspects once the sheet is open.
class _Wi325Sheet {
  _Wi325Sheet(this.harness, this.vault, this.picker);

  final BackupHarness harness;
  final VaultRef vault;
  final FakeFilePicker picker;

  /// Every settings save, in order.
  final List<_Wi325Save> saves = [];

  /// Every text the sheet put on the clipboard.
  final List<String> clipboard = [];

  /// How many times `showBackupsSheet` completed.
  int closed = 0;

  /// While set, every settings save waits on it after being recorded (A2's
  /// real save is async: preferences, then state), so a test can act while a
  /// save is in flight.
  Completer<void>? saveGate;

  /// While set, every settings save throws it (after waiting on the gate).
  Object? saveError;

  /// Holds every save from here until [releaseSaves].
  void holdSaves() => saveGate = Completer<void>();

  void releaseSaves() {
    final gate = saveGate;
    saveGate = null;
    gate?.complete();
  }

  FakeBackupController get controller => harness.controller!;
  FakeCloudFolderProbe get probe => harness.probe;

  /// From now on resolving a picked folder waits for the returned completer.
  Completer<void> holdResolves() {
    final gate = Completer<void>();
    (probe as _Wi325GatedProbe).resolveGate = gate;
    return gate;
  }

  /// How many symlink resolutions the probe has been asked for.
  int get resolveCalls => (probe as _Wi325GatedProbe).resolveRequests;

  void setView(BackupViewState view) => controller.setViewState(vault, view);
}

/// Installs every provider folder (with its `Open Memex Backups` already
/// there, so a pick resolves to the option's own path) and the chosen
/// folders.
void _seedProviders(FakeCloudFolderProbe probe, {bool backupFolders = true}) {
  probe
    ..seedIcloud()
    ..seedGoogleDrive('connor@example.com')
    ..seedGoogleDrive('work@example.com')
    ..seedOneDrive('Personal');
  if (!backupFolders) return;
  for (final d in [_icloudDest, _googleDest, _google2Dest, _oneDriveDest]) {
    probe.addDirectory(d);
  }
}

/// A probe whose first answer waits on [gate] (discovery finishes only when
/// the test lets it), and whose symlink resolution waits on [resolveGate]
/// while one is set (the folder a pick resolves stays pending).
class _Wi325GatedProbe extends FakeCloudFolderProbe {
  _Wi325GatedProbe(this.gate, {super.home});

  final Completer<void>? gate;
  Completer<void>? resolveGate;

  /// Every symlink resolution asked for, answered or still waiting.
  int resolveRequests = 0;

  @override
  Future<String> home() async {
    await gate?.future;
    return super.home();
  }

  @override
  Future<String> resolveSymbolicLinks(String path) async {
    resolveRequests++;
    await resolveGate?.future;
    return super.resolveSymbolicLinks(path);
  }
}

/// Opens the sheet on [vault] showing [view]. [stored] is the local vault's
/// stored settings (default: [view]'s). A save is recorded, stored, and
/// reflected in the fake controller's view state the way A3's controller
/// reflects a settings change (on → keeps the mode, or "never" from off; off
/// → off).
Future<_Wi325Sheet> _open(
  WidgetTester tester, {
  VaultRef vault = _local,
  BackupViewState? view,
  VaultBackupSettings? stored,
  bool providers = true,
  bool backupFolders = true,
  Completer<void>? discoveryGate,
  String? home,
  void Function(FakeCloudFolderProbe probe)? seedProbe,
  Size size = _tall,
  double textScale = 1.0,
  Set<String> inFlight = const {},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  final probe = _Wi325GatedProbe(discoveryGate, home: home ?? fakeHome);
  if (providers) _seedProviders(probe, backupFolders: backupFolders);
  seedProbe?.call(probe);
  probe.addDirectory(_chosenDest);
  probe.addDirectory(_otherChosenDest);
  final controller = FakeBackupController();
  final harness = await createBackupContainer(
    clock: FakeClock(_now),
    probe: probe,
    controller: controller,
    prefs: {
      'memex.binary_path': _binary,
      'memex.vault_servers': <String>[
        jsonEncode({
          'id': 'srv-1',
          'name': 'nas',
          'url': 'http://192.168.1.20:7878',
        }),
      ],
    },
  );
  final picker = installFakeFilePicker();
  final s = _Wi325Sheet(harness, vault, picker);

  final initial = view ?? _offView();
  controller.setViewState(vault, initial);
  final localPath = vault.localPath;

  final container = ProviderContainer(
    parent: harness.container,
    overrides: [
      vaultBackupSettingsProvider.overrideWith(
        (ref, path) =>
            ref.watch(_wi325SettingsStore)[path] ?? const VaultBackupSettings(),
      ),
      saveVaultBackupSettingsProvider.overrideWith(
        (ref) => (path, settings) async {
          s.saves.add((path: path, settings: settings));
          final gate = s.saveGate;
          if (gate != null) await gate.future;
          final error = s.saveError;
          if (error != null) throw error;
          ref
              .read(_wi325SettingsStore.notifier)
              .update((m) => {...m, path: settings});
          final cur = controller.viewStateOf(vault);
          final pickingOrOff =
              cur.mode == BackupSheetMode.off ||
              cur.mode == BackupSheetMode.pickingDestination;
          controller.setViewState(
            vault,
            settings.enabled
                ? BackupViewState(
                    mode: pickingOrOff
                        ? BackupSheetMode.neverBackedUp
                        : cur.mode,
                    settings: settings,
                    status: pickingOrOff ? null : cur.status,
                    errorCode: cur.errorCode,
                    message: cur.message,
                    warning: cur.warning,
                  )
                : BackupViewState(
                    mode: BackupSheetMode.off,
                    settings: settings,
                  ),
          );
        },
      ),
    ],
  );
  addTearDown(container.dispose);
  if (localPath != null) {
    container.read(_wi325SettingsStore.notifier).state = {
      localPath: stored ?? initial.settings ?? const VaultBackupSettings(),
    };
  }
  container.read(backupInFlightProvider.notifier).state = inFlight;

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map<Object?, Object?>;
        s.clipboard.add(args['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        // A fresh app (and navigator) per open, so a test that opens the
        // sheet several times never stacks sheets.
        key: ObjectKey(container),
        theme: buildOmTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.bottomLeft,
              child: TextButton(
                key: _launcherKey,
                onPressed: () async {
                  await showBackupsSheet(context, vault);
                  s.closed++;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_launcherKey));
  await _frames(tester);
  expect(_sheet, findsOneWidget, reason: 'showBackupsSheet opens the panel');
  return s;
}

/// A few frames (never pumpAndSettle: the backing-up spinner may repeat).
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

// ------------------------------------------------------------------ finders

String _plainOf(Iterable<RichText> ws) =>
    ws.map((w) => w.text.toPlainText()).join('\n');

/// All text inside [of].
String _textIn(WidgetTester tester, Finder of) => _plainOf(
  tester.widgetList<RichText>(
    find.descendant(of: of, matching: find.byType(RichText)),
  ),
);

/// The separate lines of text inside [of] (an icon is a line of its own).
List<String> _lines(WidgetTester tester, Finder of) =>
    _textIn(tester, of).split('\n').map((l) => l.trim()).toList();

/// The status column's text (`backups-status`).
String _status(WidgetTester tester) {
  expect(find.byKey(backupsStatusKey), findsOneWidget);
  return _textIn(tester, find.byKey(backupsStatusKey));
}

/// The whole sheet's text.
String _sheetText(WidgetTester tester) => _textIn(tester, _sheet);

/// A Text inside the sheet whose whole plain text is [s].
Finder _text(String s) => find.descendant(
  of: _sheet,
  matching: find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText() == s,
  ),
);

/// The OmButton at [key] (the keyed widget itself or the one inside it).
OmButton _button(WidgetTester tester, Key key) {
  final f = find.byKey(key);
  expect(f, findsOneWidget, reason: '$key');
  final w = tester.widget(f);
  if (w is OmButton) return w;
  final inner = find.descendant(of: f, matching: find.byType(OmButton));
  expect(inner, findsWidgets, reason: 'an OmButton under $key');
  return tester.widget<OmButton>(inner.first);
}

/// The keep field's text (`backups-keep` wraps the TextField).
String _keepText(WidgetTester tester) {
  final f = find.descendant(
    of: find.byKey(backupsKeepKey),
    matching: find.byType(EditableText),
    matchRoot: true,
  );
  expect(f, findsOneWidget, reason: 'an EditableText at backups-keep');
  return tester.widget<EditableText>(f).controller.text;
}

/// The status card: the nearest surface3 box around `backups-status`.
BoxDecoration _card(WidgetTester tester) {
  final f = find.ancestor(
    of: find.byKey(backupsStatusKey),
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == OmColors.surface3,
    ),
  );
  expect(f, findsWidgets, reason: 'a surface3 card around backups-status');
  return tester.widget<DecoratedBox>(f.first).decoration as BoxDecoration;
}

Finder _cardIcon(IconData icon) => find.descendant(
  of: _sheet,
  matching: find.byWidgetPredicate((w) => w is Icon && w.icon == icon),
);

int _rgb(Color c) => c.toARGB32() & 0xFFFFFF;

Future<void> _tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget, reason: '$f');
  await tester.tap(f);
  await _frames(tester);
}

Future<void> _tapKey(WidgetTester tester, Key key) =>
    _tap(tester, find.byKey(key));

/// The semantics nodes that lie inside [key]'s box (global rects, 2 px
/// slack), whichever widget in or around the box owns them. Needs
/// `tester.ensureSemantics()` and a frame after it.
List<SemanticsNode> _semanticsAt(WidgetTester tester, Key key) {
  final box = tester.getRect(find.byKey(key)).inflate(2);
  var root = tester.getSemantics(_sheet);
  while (root.parent != null) {
    root = root.parent!;
  }
  final out = <SemanticsNode>[];
  void walk(SemanticsNode n, Matrix4 parent) {
    final m = n.transform == null ? parent : parent.multiplied(n.transform!);
    final r = MatrixUtils.transformRect(m, n.rect);
    if (!n.isInvisible &&
        r.width > 0 &&
        box.contains(r.topLeft) &&
        box.contains(r.bottomRight)) {
      out.add(n);
    }
    n.visitChildren((c) {
      walk(c, m);
      return true;
    });
  }

  walk(root, Matrix4.identity());
  return out;
}

/// The node at [key] (or under it) whose label contains [label].
SemanticsNode _labelled(WidgetTester tester, Key key, String label) {
  final nodes = _semanticsAt(
    tester,
    key,
  ).where((n) => n.label.toLowerCase().contains(label.toLowerCase())).toList();
  expect(nodes, isNotEmpty, reason: 'a semantics label "$label" at $key');
  return nodes.first;
}

/// Tabs until the focused node is [key]'s box (same place, similar size).
Future<void> _tabTo(WidgetTester tester, Key key) async {
  final target = tester.getRect(find.byKey(key));
  for (var i = 0; i < 80; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) continue;
    final r = focus.rect;
    final a = r.width * r.height;
    final b = target.width * target.height;
    if (r.overlaps(target) && a <= 4 * b && b <= 4 * a) return;
  }
  fail('Tab never reached $key');
}

/// No paragraph in the sheet is cut: none exceeds its max lines, and none is
/// laid out shorter than its text needs (a fixed-height box). The designed
/// ellipsis of the destination menu label is exempt; the hosted command
/// wraps like any other text.
void _expectNothingClipped(WidgetTester tester, String state) {
  expect(tester.takeException(), isNull, reason: '$state: no overflow');
  final menu = find.byKey(_menuKey);
  final exempt = <RenderObject>{
    if (menu.evaluate().isNotEmpty)
      for (final e
          in find
              .descendant(of: menu, matching: find.byType(RichText))
              .evaluate())
        e.renderObject!,
  };
  for (final e
      in find
          .descendant(of: _sheet, matching: find.byType(RichText))
          .evaluate()) {
    final p = e.renderObject! as RenderParagraph;
    final text = p.text.toPlainText();
    if (exempt.contains(p)) continue;
    expect(p.didExceedMaxLines, isFalse, reason: '$state: "$text" is cut');
    expect(
      p.size.height + 0.5,
      greaterThanOrEqualTo(p.getMinIntrinsicHeight(p.size.width)),
      reason: '$state: "$text" is laid out shorter than its lines',
    );
  }
}

void _expectZeroRuns(_Wi325Sheet s) {
  expect(s.harness.cli.calls, isEmpty, reason: 'no memex CLI call');
  expect(s.harness.runner.calls, isEmpty, reason: 'no backup run');
  expect(s.controller.backUpNowCalls, isEmpty, reason: 'no backUpNow');
}

/// [at] (a day in November 2026, local time) as the UTC instant the state
/// carries, so the literal times below hold in any time zone.
DateTime _localAt(int day, int hour, int minute) =>
    DateTime(2026, 11, day, hour, minute).toUtc();

/// The RenderParagraph whose whole text is [text].
RenderParagraph _paragraph(WidgetTester tester, String text) {
  final f = find.descendant(
    of: _sheet,
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == text,
    ),
  );
  expect(f, findsOneWidget, reason: '"$text"');
  return tester.renderObject<RenderParagraph>(f);
}

/// Whether the radio row at [key] reports itself checked (needs
/// `tester.ensureSemantics()` and a frame).
bool _checkedAt(WidgetTester tester, Key key) {
  final nodes = _semanticsAt(tester, key)
      .where(
        (n) =>
            n.getSemanticsData().flagsCollection.isChecked != CheckedState.none,
      )
      .toList();
  expect(nodes, hasLength(1), reason: 'one checkable node at $key');
  return nodes.single.getSemanticsData().flagsCollection.isChecked ==
      CheckedState.isTrue;
}

/// Exactly the rows in [checked] are checked, of every row [keys].
void _expectChecked(
  WidgetTester tester,
  List<Key> keys, {
  Set<Key> checked = const {},
  String? why,
}) {
  for (final key in keys) {
    expect(
      _checkedAt(tester, key),
      checked.contains(key),
      reason: '${why ?? ''} $key',
    );
  }
}

/// The copy the sheet shows when a destination could not be made or used.
String _unavailableDetail(String destination, BackupProvider? provider) =>
    backupFailureMessage(
      code: 'backup_destination_unavailable',
      automatic: false,
      failedAt: _now,
      now: _now,
      destination: destination,
      provider: provider,
    ).detail;

/// Real folders for the symlink tests: the stored destination is A2's
/// symlink-resolved path while discovery's row runs through a symlink.
typedef _Wi325Tree = ({
  String base,
  String home,
  String storage,
  String optionPath,
  String resolved,
});

/// `<home>/Library/CloudStorage/GoogleDrive-connor@example.com` is a link to
/// a real folder holding `My Drive/Open Memex Backups`.
_Wi325Tree _wi325LinkedGoogleDrive() {
  final base = Directory.systemTemp
      .createTempSync('wi325-link-')
      .resolveSymbolicLinksSync();
  addTearDown(() => Directory(base).deleteSync(recursive: true));
  final real = '$base/real-drive';
  Directory('$real/My Drive/$_backupsFolder').createSync(recursive: true);
  final storage = '$base/home/Library/CloudStorage';
  Directory(storage).createSync(recursive: true);
  Link('$storage/GoogleDrive-connor@example.com').createSync(real);
  return (
    base: base,
    home: '$base/home',
    storage: storage,
    optionPath:
        '$storage/GoogleDrive-connor@example.com/My Drive/$_backupsFolder',
    resolved: '$real/My Drive/$_backupsFolder',
  );
}

/// iCloud (missing on disk), the linked Google Drive, a second Google Drive
/// (missing on disk) and choose folder.
List<BackupDestinationOption> _wi325LinkedOptions(_Wi325Tree t) => [
  BackupDestinationOption(
    provider: BackupProvider.icloud,
    label: 'iCloud Drive',
    path:
        '${t.home}/Library/Mobile Documents/com~apple~CloudDocs/$_backupsFolder',
  ),
  BackupDestinationOption(
    provider: BackupProvider.googleDrive,
    label: 'Google Drive · connor@example.com',
    path: t.optionPath,
  ),
  BackupDestinationOption(
    provider: BackupProvider.googleDrive,
    label: 'Google Drive · work@example.com',
    path: '${t.storage}/GoogleDrive-work@example.com/My Drive/$_backupsFolder',
  ),
  _chooseOption,
];

void main() {
  holdFontFetches();
  // ================================================================ AC 1
  group('AC1 the panel opens and closes', () {
    testWidgets(
      'showBackupsSheet opens the panel keyed backups-sheet and calls openSheet once',
      (tester) async {
        final s = await _open(tester, view: _successView());
        expect(_sheet, findsOneWidget);
        expect(s.controller.openSheetCalls, [_local]);
        // Later view changes rebuild the sheet without reopening it.
        s.setView(_backingUpView());
        await _frames(tester);
        s.setView(_successView());
        await _frames(tester);
        expect(s.controller.openSheetCalls, [_local]);
        expect(s.controller.closeSheetCalls, isEmpty);
        expect(s.closed, 0);
      },
    );

    testWidgets('the close button closes the sheet and calls closeSheet once', (
      tester,
    ) async {
      final s = await _open(tester, view: _successView());
      await _tapKey(tester, _closeKey);
      expect(_sheet, findsNothing);
      expect(s.closed, 1);
      expect(s.controller.closeSheetCalls, [_local]);
    });

    testWidgets('Escape closes the sheet and calls closeSheet once', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(_sheet, findsNothing);
      expect(s.closed, 1);
      expect(s.controller.closeSheetCalls, [_local]);
    });

    testWidgets('a tap on the barrier closes the sheet', (tester) async {
      final s = await _open(tester, view: _neverView());
      await tester.tapAt(Offset(4, _tall.height - 4));
      await _frames(tester);
      expect(_sheet, findsNothing);
      expect(s.closed, 1);
      expect(s.controller.closeSheetCalls, [_local]);
    });

    testWidgets('a hosted sheet opens and closes on its hosted vault ref', (
      tester,
    ) async {
      final s = await _open(tester, vault: _hosted, view: _hostedSuccessView());
      expect(s.controller.openSheetCalls, [_hosted]);
      await _tapKey(tester, _closeKey);
      expect(_sheet, findsNothing);
      expect(s.controller.closeSheetCalls, [_hosted]);
    });

    testWidgets(
      'the header eyebrow names the vault and for hosted the server',
      (tester) async {
        await _open(tester, view: _offView());
        expect(_text('BACKUPS · WORK'), findsOneWidget);
        final style = tester
            .widget<RichText>(_text('BACKUPS · WORK'))
            .text
            .style;
        final eyebrow = OmType.eyebrow();
        expect(style?.fontFamily, eyebrow.fontFamily);
        expect(style?.fontSize, eyebrow.fontSize);
        expect(style?.color, OmColors.fg2);

        await _open(tester, vault: _hosted, view: _hostedSuccessView());
        expect(_text('BACKUPS · WORK · NAS'), findsOneWidget);
      },
    );
  });

  // ================================================================ AC 2
  group('AC2 off and the destination list', () {
    testWidgets(
      'off shows backups are off and turn on backups under backups-toggle',
      (tester) async {
        await _open(tester, view: _offView());
        final status = _status(tester);
        expect(status, contains(_offTitle));
        expect(status, contains(_offBody));
        expect(_sheetText(tester), contains(_offLead));
        expect(_textIn(tester, find.byKey(backupsToggleKey)), _turnOnEllipsis);
        expect(_button(tester, backupsToggleKey).onPressed, isNotNull);
        // Off has no settings group, no back up now and no req 25 row.
        expect(find.byKey(backupsNowKey), findsNothing);
        expect(find.byKey(backupsKeepKey), findsNothing);
        expect(find.byKey(backupsAutomaticKey), findsNothing);
        expect(_text('SETTINGS'), findsNothing);
        expect(_cardIcon(LucideIcons.archive), findsOneWidget);
      },
    );

    testWidgets(
      'pressing turn on backups lists the discovered destinations in order with their Keys',
      (tester) async {
        // The off view state carries no options: every provider row below
        // comes from the sheet's own discovery over the seeded probe (iCloud,
        // two Google Drive accounts, OneDrive).
        final s = await _open(tester, view: _offView());
        expect(_offView().options, isEmpty);
        await _tapKey(tester, backupsToggleKey);

        expect(_status(tester), contains(_pickTitle));
        expect(_status(tester), contains(_pickBody));
        expect(_discoveredKeys, hasLength(4));
        var lastTop = double.negativeInfinity;
        for (final (key, account) in [
          (_discoveredKeys[0], 'iCloud Drive'),
          (_discoveredKeys[1], 'connor@example.com'),
          (_discoveredKeys[2], 'work@example.com'),
          (_discoveredKeys[3], 'Personal'),
          (backupsDestinationChooseKey, 'choose folder'),
        ]) {
          final row = find.byKey(key);
          expect(row, findsOneWidget, reason: '$account as $key');
          expect(_textIn(tester, row), contains(account), reason: '$key');
          final top = tester.getRect(row).top;
          expect(top, greaterThan(lastTop), reason: '$account in order');
          lastTop = top;
        }
        // No fifth row of any provider.
        expect(
          find.byKey(backupDestinationKey(BackupProvider.googleDrive, 2)),
          findsNothing,
        );
        expect(
          find.byKey(backupDestinationKey(BackupProvider.icloud, 1)),
          findsNothing,
        );
        expect(
          find.byKey(backupDestinationKey(BackupProvider.oneDrive, 1)),
          findsNothing,
        );
        // The rows' path lines, relative to each provider's root.
        for (final (key, line) in [
          (_discoveredKeys[0], 'iCloud Drive/Open Memex Backups'),
          (_discoveredKeys[1], 'My Drive/Open Memex Backups'),
          (_discoveredKeys[2], 'My Drive/Open Memex Backups'),
          (_discoveredKeys[3], 'OneDrive-Personal/Open Memex Backups'),
        ]) {
          expect(_textIn(tester, find.byKey(key)), contains(line));
        }
        expect(
          _textIn(tester, find.byKey(backupsDestinationChooseKey)),
          contains('a nas share, an external disk or any folder'),
        );
        expect(_sheetText(tester), contains('found on this mac'));
        expect(_sheetText(tester), contains(_pickNote));
        expect(_sheetText(tester), isNot(contains(_noProviderSub)));
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'discovered rows read the provider and the account the way the pack draws them',
      (tester) async {
        // A2 hands over bare labels (iCloud Drive, the account, the
        // OneDrive name); the sheet composes "Google Drive · <account>".
        await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        for (final (key, name) in [
          (_discoveredKeys[0], 'iCloud Drive'),
          (_discoveredKeys[1], 'Google Drive · connor@example.com'),
          (_discoveredKeys[2], 'Google Drive · work@example.com'),
          (_discoveredKeys[3], 'OneDrive · Personal'),
        ]) {
          expect(
            _textIn(tester, find.byKey(key)),
            contains(name),
            reason: name,
          );
        }
      },
    );

    testWidgets(
      'providers found after the list opened appear when discovery finishes',
      (tester) async {
        final gate = Completer<void>();
        await _open(tester, view: _offView(), discoveryGate: gate);
        await _tapKey(tester, backupsToggleKey);
        // Discovery has not answered: choose folder is the only row.
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        expect(find.byKey(_discoveredKeys[0]), findsNothing);
        gate.complete();
        await _frames(tester);
        for (final key in _discoveredKeys) {
          expect(find.byKey(key), findsOneWidget, reason: '$key');
        }
        expect(_sheetText(tester), contains('found on this mac'));
      },
    );

    testWidgets(
      'with no provider found pressing turn on backups lists only choose folder',
      (tester) async {
        final s = await _open(tester, view: _offView(), providers: false);
        await _tapKey(tester, backupsToggleKey);
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        for (final p in BackupProvider.values) {
          expect(find.byKey(backupDestinationKey(p, 0)), findsNothing);
        }
        expect(_sheetText(tester), contains(_noProviderSub));
        expect(_sheetText(tester), isNot(contains(_pickNote)));
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'a picking view state lists its options in order with per-provider Keys',
      (tester) async {
        await _open(tester, view: _pickingView());
        final keys = [
          backupDestinationKey(BackupProvider.icloud, 0),
          backupDestinationKey(BackupProvider.googleDrive, 0),
          backupDestinationKey(BackupProvider.googleDrive, 1),
          backupDestinationKey(BackupProvider.oneDrive, 0),
          backupsDestinationChooseKey,
        ];
        const labels = [
          'iCloud Drive',
          'Google Drive · connor@example.com',
          'Google Drive · work@example.com',
          'OneDrive · Personal',
        ];
        var lastTop = double.negativeInfinity;
        for (var i = 0; i < keys.length; i++) {
          final row = find.byKey(keys[i]);
          expect(row, findsOneWidget, reason: '${keys[i]}');
          if (i < labels.length) {
            expect(_textIn(tester, row), contains(labels[i]));
          }
          final top = tester.getRect(row).top;
          expect(top, greaterThan(lastTop), reason: '${keys[i]} in order');
          lastTop = top;
        }
        // The rows' path lines, relative to each provider's root.
        final text = _sheetText(tester);
        expect(text, contains('iCloud Drive/Open Memex Backups'));
        expect(text, contains('My Drive/Open Memex Backups'));
        expect(text, contains('OneDrive-Personal/Open Memex Backups'));
        // No third Google row, no second iCloud row.
        expect(
          find.byKey(backupDestinationKey(BackupProvider.googleDrive, 2)),
          findsNothing,
        );
        expect(
          find.byKey(backupDestinationKey(BackupProvider.icloud, 1)),
          findsNothing,
        );
      },
    );
  });

  // ================================================================ AC 3
  group('AC3 choosing a destination turns backups on', () {
    testWidgets(
      'nothing is preselected and turn on backups is disabled until a choice',
      (tester) async {
        final s = await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        expect(_textIn(tester, find.byKey(_turnOnKey)), 'turn on backups');
        expect(_button(tester, _turnOnKey).onPressed, isNull);
        expect(_textIn(tester, find.byKey(_cancelKey)), 'cancel');
        // A press on the disabled button saves nothing.
        await tester.tap(find.byKey(_turnOnKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.saves, isEmpty);

        await _open(tester, view: _pickingView());
        expect(_button(tester, _turnOnKey).onPressed, isNull);
        await _tapKey(tester, backupDestinationKey(BackupProvider.icloud, 0));
        expect(_button(tester, _turnOnKey).onPressed, isNotNull);
      },
    );

    testWidgets(
      'choosing a provider and pressing turn on backups saves it with backups on and shows it',
      (tester) async {
        final s = await _open(
          tester,
          view: _pickingView(),
          stored: const VaultBackupSettings(keep: 12, automatic: false),
        );
        await _tapKey(
          tester,
          backupDestinationKey(BackupProvider.googleDrive, 1),
        );
        expect(s.saves, isEmpty, reason: 'selecting does not save');
        await _tapKey(tester, _turnOnKey);

        expect(s.saves, hasLength(1));
        expect(s.saves.single.path, _local.path);
        expect(
          s.saves.single.settings,
          const VaultBackupSettings(
            enabled: true,
            destination: _google2Dest,
            keep: 12,
            automatic: false,
          ),
        );
        _expectZeroRuns(s);
        // The sheet now shows the on state with the destination.
        expect(_status(tester), contains(_neverTitle));
        expect(find.byKey(_menuKey), findsOneWidget);
        expect(_sheetText(tester), contains('My Drive/Open Memex Backups'));
        expect(find.byKey(_turnOnKey), findsNothing);
      },
    );

    testWidgets(
      'turning on from the off state saves the selected discovered destination',
      (tester) async {
        for (final (key, path) in [
          (_discoveredKeys[0], _icloudDest),
          (_discoveredKeys[1], _googleDest),
          (_discoveredKeys[2], _google2Dest),
          (_discoveredKeys[3], _oneDriveDest),
        ]) {
          final s = await _open(tester, view: _offView());
          await _tapKey(tester, backupsToggleKey);
          expect(find.byKey(key), findsOneWidget, reason: path);
          await _tapKey(tester, key);
          await _tapKey(tester, _turnOnKey);
          expect(s.saves, hasLength(1), reason: path);
          expect(s.saves.single.settings.enabled, isTrue, reason: path);
          expect(s.saves.single.settings.destination, path);
          _expectZeroRuns(s);
        }
      },
    );

    testWidgets(
      'choose folder asks the folder picker and turn on backups saves the picked folder',
      (tester) async {
        final s = await _open(tester, view: _pickingView());
        s.picker.directories.add(_chosenDest);
        await _tapKey(tester, backupsDestinationChooseKey);
        expect(
          s.picker.calls.where((c) => c.method == 'getDirectoryPath'),
          hasLength(1),
        );
        // The row's path line shows the picked folder.
        expect(
          _textIn(tester, find.byKey(backupsDestinationChooseKey)),
          contains(_chosenDest),
        );
        expect(s.saves, isEmpty);
        await _tapKey(tester, _turnOnKey);
        expect(s.saves, hasLength(1));
        expect(
          s.saves.single.settings,
          const VaultBackupSettings(enabled: true, destination: _chosenDest),
        );
        _expectZeroRuns(s);
      },
    );

    testWidgets('a cancelled folder picker selects nothing and saves nothing', (
      tester,
    ) async {
      final s = await _open(tester, view: _pickingView());
      // The picker queue is empty: the native dialog is cancelled.
      await _tapKey(tester, backupsDestinationChooseKey);
      expect(s.picker.calls, hasLength(1));
      expect(_button(tester, _turnOnKey).onPressed, isNull);
      expect(s.saves, isEmpty);

      // A cancelled pick after a provider was selected keeps that selection.
      await _tapKey(tester, backupDestinationKey(BackupProvider.icloud, 0));
      await _tapKey(tester, backupsDestinationChooseKey);
      await _tapKey(tester, _turnOnKey);
      expect(s.saves.single.settings.destination, _icloudDest);
    });

    testWidgets('cancel leaves backups off and saves nothing', (tester) async {
      final s = await _open(tester, view: _offView());
      await _tapKey(tester, backupsToggleKey);
      expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
      await _tapKey(tester, _cancelKey);
      expect(s.saves, isEmpty);
      _expectZeroRuns(s);
      expect(_status(tester), contains(_offTitle));
      expect(find.byKey(backupsDestinationChooseKey), findsNothing);
      expect(_textIn(tester, find.byKey(backupsToggleKey)), _turnOnEllipsis);
      expect(_sheet, findsOneWidget, reason: 'cancel does not close the sheet');
    });

    testWidgets(
      'the on state shows each destination relative to its provider and a chosen folder in full',
      (tester) async {
        for (final (dest, shown, label, cloud) in [
          (
            _icloudDest,
            'iCloud Drive/Open Memex Backups',
            'iCloud Drive',
            true,
          ),
          (
            _googleDest,
            'My Drive/Open Memex Backups',
            'Google Drive · connor@example.com',
            true,
          ),
          (
            _google2Dest,
            'My Drive/Open Memex Backups',
            'Google Drive · work@example.com',
            true,
          ),
          (
            _oneDriveDest,
            'OneDrive-Personal/Open Memex Backups',
            'OneDrive · Personal',
            true,
          ),
          (_chosenDest, _chosenDest, 'memex-backups', false),
        ]) {
          await _open(
            tester,
            view: _neverView(_on.copyWith(destination: dest)),
          );
          expect(_sheetText(tester), contains(shown), reason: dest);
          expect(_text('destination'), findsOneWidget, reason: dest);
          // The destination button reads the provider and account, or a
          // chosen folder's own name, with a cloud or a folder icon.
          expect(
            _textIn(tester, find.byKey(_menuKey)),
            contains(label),
            reason: dest,
          );
          for (final (icon, expected) in [
            (LucideIcons.cloud, cloud),
            (LucideIcons.folder, !cloud),
          ]) {
            expect(
              find.descendant(
                of: find.byKey(_menuKey),
                matching: find.byWidgetPredicate(
                  (w) => w is Icon && w.icon == icon,
                ),
              ),
              expected ? findsOneWidget : findsNothing,
              reason: '$dest: $icon',
            );
          }
        }
      },
    );

    testWidgets(
      'a folder in a provider tree that is not its Open Memex Backups reads as a chosen folder',
      (tester) async {
        // The same rule as A3's controller, so the card and the failure copy
        // describe one destination one way.
        for (final dest in [
          '$_googleRoot/memex',
          '$_googleRoot/Open Memex Backups/old',
          '$_icloudRoot/Documents/backups',
          '$_icloudRoot/Open Memex Backups/old',
          '$_oneDriveRoot/Open Memex Backups/old',
          '$_oneDriveRoot/Work/Open Memex Backups',
          '$_home/Library/CloudStorage/GoogleDrive-a@b.com/Shared drives/x',
        ]) {
          await _open(
            tester,
            view: _successView(_on.copyWith(destination: dest)),
          );
          final status = _status(tester);
          expect(
            status,
            contains('${backupSize(_bytes)} · $dest'),
            reason: dest,
          );
          expect(status, isNot(contains('app uploads it')), reason: dest);
          expect(status, isNot(contains('saved to')), reason: dest);
          expect(_sheetText(tester), contains(dest), reason: dest);
          expect(
            _textIn(tester, find.byKey(_menuKey)),
            isNot(contains('Drive')),
            reason: dest,
          );
          expect(
            _textIn(tester, find.byKey(_menuKey)),
            isNot(contains('OneDrive')),
            reason: dest,
          );
          expect(
            find.descendant(
              of: find.byKey(_menuKey),
              matching: find.byWidgetPredicate(
                (w) => w is Icon && w.icon == LucideIcons.folder,
              ),
            ),
            findsOneWidget,
            reason: dest,
          );
        }
        // A trailing slash is still the provider's folder.
        await _open(
          tester,
          view: _successView(_on.copyWith(destination: '$_googleDest/')),
        );
        expect(_status(tester), contains(_providerLine('google drive')));
        expect(
          _textIn(tester, find.byKey(_menuKey)),
          contains('Google Drive · connor@example.com'),
        );
      },
    );
  });

  // ================================================================ AC 4
  group('AC4 never and success', () {
    testWidgets('on and never backed up shows no backup yet and back up now', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      final status = _status(tester);
      expect(status, contains(_neverTitle));
      expect(status, contains(_neverBody));
      expect(_textIn(tester, find.byKey(backupsNowKey)), _backUpNow);
      expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      expect(find.byKey(backupsRetryKey), findsNothing);
      expect(_text('SETTINGS'), findsOneWidget);
      expect(find.byKey(backupsKeepKey), findsOneWidget);
      expect(find.byKey(backupsAutomaticKey), findsOneWidget);
      expect(_textIn(tester, find.byKey(backupsToggleKey)), _turnOff);
    });

    testWidgets('success shows the file name size and time from the state', (
      tester,
    ) async {
      await _open(tester, view: _successView());
      final status = _status(tester);
      expect(status, contains(_file));
      expect(status, contains(backupSize(_bytes)));
      final when = backupWhen(_created, _now);
      expect(status, contains('backed up $when'));
      // The time is the file's (last_file_created_at), not the later
      // unchanged run's.
      final later = backupWhen(_successStatus().lastSuccessAt!, _now);
      if (later != when) {
        expect(status, isNot(contains('backed up $later')));
      }
      expect(_textIn(tester, find.byKey(backupsNowKey)), _backUpNow);
      expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      expect(_cardIcon(LucideIcons.check), findsOneWidget);
    });

    testWidgets(
      'success into a provider folder shows the provider upload line',
      (tester) async {
        for (final (dest, provider) in [
          (_googleDest, 'google drive'),
          (_icloudDest, 'icloud drive'),
          (_oneDriveDest, 'onedrive'),
        ]) {
          await _open(
            tester,
            view: _successView(_on.copyWith(destination: dest)),
          );
          final status = _status(tester);
          expect(status, contains(_providerLine(provider)), reason: dest);
          expect(status, contains(backupSize(_bytes)), reason: dest);
          for (final other in ['google drive', 'icloud drive', 'onedrive']) {
            if (other == provider) continue;
            expect(status, isNot(contains('the $other app')), reason: dest);
          }
          // The upload is never claimed finished.
          expect(status, isNot(contains('uploaded')), reason: dest);
        }
      },
    );

    testWidgets(
      'success into a chosen folder shows its path and no upload line',
      (tester) async {
        await _open(
          tester,
          view: _successView(_on.copyWith(destination: _chosenDest)),
        );
        final status = _status(tester);
        expect(status, contains('${backupSize(_bytes)} · $_chosenDest'));
        expect(status, isNot(contains('app uploads it')));
        expect(status, isNot(contains('saved to')));
        expect(status, contains(_file));
      },
    );
  });

  // ================================================================ AC 5
  group('AC5 backing up', () {
    testWidgets('backing up shows the view state start time when it has one', (
      tester,
    ) async {
      final started = DateTime.utc(2026, 11, 9, 14, 3);
      final local = started.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      await _open(
        tester,
        view: BackupViewState(
          mode: BackupSheetMode.backingUp,
          settings: _on,
          status: _successStatus(),
          startedAt: started,
        ),
      );
      expect(
        _status(tester),
        contains('started ${two(local.hour)}:${two(local.minute)}.'),
      );
      await _open(tester, view: _backingUpView());
      expect(_status(tester), isNot(contains('started ')));
    });

    testWidgets('backing up shows backing up and backups-now is disabled', (
      tester,
    ) async {
      final s = await _open(tester, view: _backingUpView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      final status = _status(tester);
      expect(status, contains(_backingUpTitle));
      expect(status, contains(_backingUpBody));
      expect(_textIn(tester, find.byKey(backupsNowKey)), _backingUpTitle);
      expect(_button(tester, backupsNowKey).onPressed, isNull);
      expect(
        _labelled(tester, backupsNowKey, _backingUpTitle),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      expect(_cardIcon(LucideIcons.loaderCircle), findsOneWidget);
      await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
      await _frames(tester);
      expect(s.controller.backUpNowCalls, isEmpty);
      handle.dispose();
    });

    testWidgets(
      'backups-now is disabled while the vault is in the in-flight set',
      (tester) async {
        final s = await _open(
          tester,
          view: _successView(),
          inFlight: {_local.path},
        );
        expect(_button(tester, backupsNowKey).onPressed, isNull);
        await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, isEmpty);

        // Another vault's run does not disable this one.
        await _open(
          tester,
          view: _successView(),
          inFlight: {'/Users/tester/vaults/other'},
        );
        expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      },
    );

    testWidgets('an enabled back up now has enabled button semantics', (
      tester,
    ) async {
      await _open(tester, view: _successView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        _labelled(tester, backupsNowKey, _backUpNow),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });
  });

  // ================================================================ AC 6
  group('AC6 back up now calls the controller once per press', () {
    testWidgets('one press on backups-now calls backUpNow exactly once', (
      tester,
    ) async {
      for (final view in [_neverView(), _successView()]) {
        final s = await _open(tester, view: view);
        await _tapKey(tester, backupsNowKey);
        expect(s.controller.backUpNowCalls, [_local], reason: '${view.mode}');
        expect(s.saves, isEmpty);
        expect(s.harness.cli.calls, isEmpty);
      }
    });

    testWidgets(
      'a second press while the controller reports backing up makes no call',
      (tester) async {
        final s = await _open(tester, view: _successView());
        await _tapKey(tester, backupsNowKey);
        s.setView(_backingUpView());
        await _frames(tester);
        await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, hasLength(1));
      },
    );

    testWidgets(
      'a second press while the first call is pending makes no call',
      (tester) async {
        final s = await _open(tester, view: _successView());
        final hold = s.controller.holdBackUpNow();
        await _tapKey(tester, backupsNowKey);
        // The controller has not flipped to backing up yet.
        await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, hasLength(1));
        expect(_button(tester, backupsNowKey).onPressed, isNull);
        hold.complete();
        await _frames(tester);
      },
    );

    testWidgets('a press after the first call finished calls backUpNow again', (
      tester,
    ) async {
      final s = await _open(tester, view: _successView());
      final hold = s.controller.holdBackUpNow();
      await _tapKey(tester, backupsNowKey);
      s.setView(_backingUpView());
      await _frames(tester);
      hold.complete();
      s.setView(_successView());
      await _frames(tester);
      expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      await _tapKey(tester, backupsNowKey);
      expect(s.controller.backUpNowCalls, [_local, _local]);
    });
  });

  // ================================================================ AC 7
  group('AC7 the error state and retry', () {
    testWidgets('the error state shows the approved message for each outcome', (
      tester,
    ) async {
      for (final (code, raw) in [
        ('backup_destination_unavailable', 'permission denied'),
        ('backup_destination_inside_vault', null),
        ('backup_in_progress', null),
        ('backup_failed', 'disk full'),
        ('network_filesystem', 'smbfs'),
        ('internal', 'boom'),
        ('some_future_code', 'odd'),
      ]) {
        await _open(tester, view: _errorView(code, raw: raw));
        final status = _status(tester);
        final auto = _localFailure(code, raw: raw);
        final manual = _localFailure(code, raw: raw, automatic: false);
        expect(status, contains(auto.detail), reason: code);
        expect(
          status,
          anyOf(contains(auto.title), contains(manual.title)),
          reason: code,
        );
        expect(
          _textIn(tester, find.byKey(backupsRetryKey)),
          contains('retry'),
          reason: code,
        );
        expect(find.byKey(backupsNowKey), findsNothing, reason: code);
        expect(_cardIcon(LucideIcons.triangleAlert), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(backupsRetryKey),
            matching: find.byWidgetPredicate(
              (w) => w is Icon && w.icon == LucideIcons.refreshCw,
            ),
          ),
          findsOneWidget,
          reason: code,
        );
        expect(
          _rgb((_card(tester).border! as Border).top.color),
          _rgb(OmColors.danger),
          reason: code,
        );
      }
    });

    testWidgets('the error card shows the view state message verbatim', (
      tester,
    ) async {
      const seeded = BackupMessage(
        title: 'seeded title from the controller',
        detail: 'seeded detail from the controller',
        short: 'seeded short',
      );
      for (final mode in [
        BackupSheetMode.error,
        BackupSheetMode.memexTooOld,
        BackupSheetMode.binaryNotFound,
      ]) {
        await _open(
          tester,
          view: BackupViewState(
            mode: mode,
            settings: _on,
            status: _failedStatus('backup_failed', raw: 'disk full'),
            errorCode: 'backup_failed',
            message: seeded,
            automatic: false,
            failedAt: _failedAt,
          ),
        );
        final status = _status(tester);
        expect(status, contains(seeded.title), reason: '$mode');
        expect(status, contains(seeded.detail), reason: '$mode');
      }
      await _open(
        tester,
        vault: _hosted,
        view: BackupViewState(
          mode: BackupSheetMode.error,
          hosted: true,
          status: _failedStatus('backup_failed'),
          errorCode: 'backup_failed',
          message: seeded,
        ),
      );
      final status = _status(tester);
      expect(status, contains(seeded.title));
      expect(status, contains(seeded.detail));
    });

    testWidgets(
      'the error state shows the last good backup and when it retries',
      (tester) async {
        await _open(
          tester,
          view: _errorView('backup_failed', raw: 'disk full'),
        );
        expect(
          _status(tester),
          contains(
            'last good backup: ${backupWhen(_yesterdayCreated, _now)} · '
            '${backupSize(_yesterdayBytes)}. tries again hourly.',
          ),
        );

        // Automatic off: no "tries again hourly".
        await _open(
          tester,
          view: _errorView(
            'backup_failed',
            raw: 'disk full',
            settings: _on.copyWith(automatic: false),
          ),
        );
        final off = _status(tester);
        expect(off, contains('last good backup: '));
        expect(off, isNot(contains('tries again hourly')));

        // No good backup yet.
        await _open(
          tester,
          view: _errorView('backup_failed', raw: 'disk full', withGood: false),
        );
        final none = _status(tester);
        expect(none, contains('no good backup yet. tries again hourly.'));
        expect(none, isNot(contains('last good backup: ')));
      },
    );

    testWidgets('one press on backups-retry runs exactly one backup', (
      tester,
    ) async {
      final s = await _open(tester, view: _errorView('backup_failed'));
      await _tapKey(tester, backupsRetryKey);
      expect(s.controller.backUpNowCalls, [_local]);
      expect(s.saves, isEmpty);
    });

    testWidgets(
      'a second retry press while the first is pending makes no call',
      (tester) async {
        final s = await _open(tester, view: _errorView('backup_failed'));
        final hold = s.controller.holdBackUpNow();
        await _tapKey(tester, backupsRetryKey);
        await tester.tap(find.byKey(backupsRetryKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, hasLength(1));
        hold.complete();
        await _frames(tester);
        // Finished and still failing: retry works again.
        await _tapKey(tester, backupsRetryKey);
        expect(s.controller.backUpNowCalls, hasLength(2));
      },
    );
  });

  // ================================================================ AC 8
  group('AC8 keep and back up automatically', () {
    testWidgets('keep accepts 1 and 365 and saves on submit', (tester) async {
      final s = await _open(tester, view: _neverView());
      for (final v in [1, 365, 42]) {
        await tester.enterText(find.byKey(backupsKeepKey), '$v');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _frames(tester);
        expect(s.saves.last.settings, _on.copyWith(keep: v), reason: '$v');
      }
      // One save per accepted value (a repeat of the same value is allowed).
      final keeps = <int>[];
      for (final x in s.saves) {
        if (keeps.isEmpty || keeps.last != x.settings.keep) {
          keeps.add(x.settings.keep);
        }
      }
      expect(keeps, [1, 365, 42]);
      _expectZeroRuns(s);
    });

    testWidgets('keep saves when the field loses focus', (tester) async {
      final s = await _open(tester, view: _neverView());
      await tester.enterText(find.byKey(backupsKeepKey), '45');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _frames(tester);
      expect(s.saves, hasLength(1));
      expect(s.saves.single.settings, _on.copyWith(keep: 45));
    });

    testWidgets(
      'keep clamps typed values to 1 to 365 and ignores non numbers',
      (tester) async {
        final s = await _open(tester, view: _neverView());
        for (final (typed, saved) in [
          ('0', 1),
          ('999', 365),
          ('-3', 1),
          ('366', 365),
        ]) {
          final before = s.saves.length;
          await tester.enterText(find.byKey(backupsKeepKey), typed);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await _frames(tester);
          expect(tester.takeException(), isNull, reason: '"$typed"');
          expect(s.saves, hasLength(before + 1), reason: '"$typed"');
          expect(s.saves.last.settings.keep, saved, reason: '"$typed"');
          expect(_keepText(tester), '$saved', reason: '"$typed"');
        }
        final before = s.saves.length;
        for (final v in ['', 'abc']) {
          await tester.enterText(find.byKey(backupsKeepKey), v);
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await _frames(tester);
          expect(tester.takeException(), isNull, reason: '"$v"');
        }
        expect(s.saves, hasLength(before), reason: 'nothing to save');
      },
    );

    testWidgets('keep plus and minus save one more and one less', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      await _tapKey(tester, _keepIncKey);
      expect(s.saves.last.settings, _on.copyWith(keep: 31));
      await _tapKey(tester, _keepIncKey);
      expect(s.saves.last.settings, _on.copyWith(keep: 32));
      await _tapKey(tester, _keepDecKey);
      expect(s.saves.last.settings, _on.copyWith(keep: 31));
      expect(s.saves, hasLength(3));
      // The field shows the saved value.
      expect(_keepText(tester), '31');
      _expectZeroRuns(s);
    });

    testWidgets('keep plus stops at 365 and minus stops at 1', (tester) async {
      final top = _on.copyWith(keep: 365);
      final s = await _open(tester, view: _neverView(top));
      await tester.tap(find.byKey(_keepIncKey), warnIfMissed: false);
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(s.saves.where((x) => x.settings.keep != 365), isEmpty);
      await _tapKey(tester, _keepDecKey);
      expect(s.saves.last.settings.keep, 364);

      final bottom = _on.copyWith(keep: 1);
      final s2 = await _open(tester, view: _neverView(bottom));
      await tester.tap(find.byKey(_keepDecKey), warnIfMissed: false);
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(s2.saves.where((x) => x.settings.keep != 1), isEmpty);
      await _tapKey(tester, _keepIncKey);
      expect(s2.saves.last.settings.keep, 2);
    });

    testWidgets('back up automatically saves the flipped value', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      await _tapKey(tester, backupsAutomaticKey);
      expect(s.saves.last.settings, _on.copyWith(automatic: false));
      await _tapKey(tester, backupsAutomaticKey);
      expect(s.saves.last.settings, _on.copyWith(automatic: true));
      expect(s.saves, hasLength(2));
      _expectZeroRuns(s);
      expect(_sheetText(tester), contains('back up automatically'));
      expect(
        _sheetText(tester),
        contains("once a day when memex changed, while it's open here"),
      );
      expect(_sheetText(tester), contains('latest backups, 1–365'));
    });

    testWidgets('the automatic switch reports its state in semantics', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        _labelled(tester, backupsAutomaticKey, 'back up automatically'),
        isSemantics(hasToggledState: true, isToggled: true),
      );
      await _tapKey(tester, backupsAutomaticKey);
      expect(
        _labelled(tester, backupsAutomaticKey, 'back up automatically'),
        isSemantics(hasToggledState: true, isToggled: false),
      );
      handle.dispose();
    });
  });

  // ================================================================ AC 9
  group('AC9 turning off and changing the destination run nothing', () {
    testWidgets('turning backups off saves them off with 0 CLI calls', (
      tester,
    ) async {
      final s = await _open(tester, view: _successView());
      await _tapKey(tester, backupsToggleKey);
      expect(s.saves, hasLength(1));
      expect(
        s.saves.single.settings,
        const VaultBackupSettings(
          enabled: false,
          destination: _googleDest,
          keep: 30,
          automatic: true,
        ),
      );
      _expectZeroRuns(s);
      expect(s.probe.createdDirectories, isEmpty);
      expect(_status(tester), contains(_offTitle));
    });

    testWidgets(
      'changing the destination from the menu saves at once with 0 CLI calls',
      (tester) async {
        final s = await _open(tester, view: _successView());
        await _tapKey(tester, _menuKey);
        s.picker.directories.add(_otherChosenDest);
        await _tap(tester, find.byKey(backupsDestinationChooseKey));
        expect(s.saves, hasLength(1));
        expect(
          s.saves.single.settings,
          _on.copyWith(destination: _otherChosenDest),
        );
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'the destination menu lists the discovered destinations and saves a provider at once',
      (tester) async {
        // The success view state carries no options: the menu's provider
        // rows come from the sheet's discovery over the seeded probe.
        final s = await _open(tester, view: _successView());
        expect(_successView().options, isEmpty);
        await _tapKey(tester, _menuKey);
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        var lastTop = double.negativeInfinity;
        for (final key in [..._discoveredKeys, backupsDestinationChooseKey]) {
          final row = find.byKey(key);
          expect(row, findsOneWidget, reason: '$key');
          final top = tester.getRect(row).top;
          expect(top, greaterThan(lastTop), reason: '$key in order');
          lastTop = top;
        }
        // The current destination (the first Google Drive account) is the
        // one marked.
        final marked = find.descendant(
          of: find.byKey(_discoveredKeys[1]),
          matching: find.byWidgetPredicate(
            (w) => w is Icon && w.icon == LucideIcons.check,
          ),
        );
        expect(marked, findsOneWidget);

        final others = [
          (_discoveredKeys[0], _icloudDest),
          (_discoveredKeys[2], _google2Dest),
          (_discoveredKeys[3], _oneDriveDest),
        ];
        for (final (key, path) in others) {
          if (find.byKey(key).evaluate().isEmpty) {
            await _tapKey(tester, _menuKey);
          }
          await _tap(tester, find.byKey(key));
          expect(s.saves.last.settings.destination, path);
          expect(s.saves.last.settings.enabled, isTrue);
        }
        expect(s.saves, hasLength(others.length));
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'while the destination menu is open the old folder note replaces the req 25 line',
      (tester) async {
        await _open(tester, view: _successView());
        expect(_sheetText(tester), contains(_req25));
        expect(_sheetText(tester), isNot(contains(_oldFolderNote)));
        // The full card: file name and the upload line.
        expect(_status(tester), contains(_file));
        expect(_status(tester), contains(_providerLine('google drive')));
        await _tapKey(tester, _menuKey);
        expect(_sheetText(tester), contains(_oldFolderNote));
        expect(_sheetText(tester), isNot(contains(_req25)));
        // B2-9's compact card: the size and where, no file name, no upload
        // line.
        final compact = _status(tester);
        expect(
          compact,
          contains(
            '${backupSize(_bytes)} · Open Memex Backups in google drive',
          ),
        );
        expect(compact, isNot(contains(_file)));
        expect(compact, isNot(contains('saved to')));
        expect(compact, isNot(contains('app uploads it')));
        expect(
          compact,
          contains('backed up ${backupWhen(_created, _now)}'),
          reason: 'the title stays',
        );
        // Closing the menu brings the full card back (the open menu covers
        // the button's lower part: press its top edge).
        await tester.tapAt(
          tester.getRect(find.byKey(_menuKey)).topCenter + const Offset(0, 4),
        );
        await _frames(tester);
        expect(_status(tester), contains(_file));
        expect(_status(tester), contains(_providerLine('google drive')));
      },
    );

    testWidgets('a cancelled folder pick from the menu saves nothing', (
      tester,
    ) async {
      final s = await _open(tester, view: _successView());
      await _tapKey(tester, _menuKey);
      await _tap(tester, find.byKey(backupsDestinationChooseKey));
      expect(s.picker.calls, hasLength(1));
      expect(s.saves, isEmpty);
      _expectZeroRuns(s);
    });
  });

  // ================================================================ AC 10
  group('AC10 the req 25 line and the binary states', () {
    testWidgets('the requirement 25 line shows in every local on state', (
      tester,
    ) async {
      for (final view in [
        _neverView(),
        _backingUpView(),
        _successView(),
        _errorView('backup_failed'),
        _tooOldView(),
        _binaryNotFoundView(),
      ]) {
        await _open(tester, view: view);
        expect(_sheetText(tester), contains(_req25), reason: '${view.mode}');
        expect(
          _textIn(tester, find.byKey(backupsToggleKey)),
          _turnOff,
          reason: '${view.mode}',
        );
      }
      // Not for a hosted vault.
      await _open(tester, vault: _hosted, view: _hostedSuccessView());
      expect(_sheetText(tester), isNot(contains(_req25)));
    });

    testWidgets('memex too old shows its message the binary path and retry', (
      tester,
    ) async {
      final s = await _open(tester, view: _tooOldView());
      final msg = backupTooOldMessage();
      final status = _status(tester);
      expect(status, contains(msg.title));
      expect(status, contains(msg.detail));
      expect(_sheetText(tester), contains(_binary));
      expect(_sheetText(tester), contains('locate memex binary…'));
      expect(find.byKey(backupsNowKey), findsNothing);
      await _tapKey(tester, backupsRetryKey);
      expect(s.controller.backUpNowCalls, [_local]);
    });

    testWidgets(
      'binary not found shows its message the binary path and retry',
      (tester) async {
        final s = await _open(tester, view: _binaryNotFoundView());
        final msg = backupBinaryNotFoundMessage();
        final status = _status(tester);
        expect(status, contains(msg.title));
        expect(status, contains(msg.detail));
        expect(_sheetText(tester), contains(_binary));
        expect(find.byKey(backupsNowKey), findsNothing);
        await _tapKey(tester, backupsRetryKey);
        expect(s.controller.backUpNowCalls, [_local]);
      },
    );

    testWidgets('locate memex binary asks the file picker for the binary', (
      tester,
    ) async {
      for (final view in [_tooOldView(), _binaryNotFoundView()]) {
        final s = await _open(tester, view: view);
        await _tap(tester, _text('locate memex binary…'));
        expect(
          s.picker.calls.where((c) => c.method == 'pickFiles'),
          hasLength(1),
          reason: '${view.mode}',
        );
        expect(s.controller.backUpNowCalls, isEmpty);
      }
    });
  });

  // ================================================================ AC 11
  group('AC11 hosted states', () {
    void expectRows(WidgetTester tester, String state) {
      final text = _sheetText(tester);
      for (final t in [
        'ON NAS',
        'backup folder',
        'set on nas with --backup-dir',
        'keep',
        'latest 30',
        'schedule',
        'once a day when work changed',
      ]) {
        expect(text, contains(t), reason: '$state: $t');
      }
      // Read-only: no destination picker, no switch, no keep field, no
      // turn-off.
      expect(find.byKey(_menuKey), findsNothing, reason: state);
      expect(find.byKey(backupsAutomaticKey), findsNothing, reason: state);
      expect(find.byKey(backupsKeepKey), findsNothing, reason: state);
      expect(find.byKey(backupsToggleKey), findsNothing, reason: state);
    }

    testWidgets(
      'hosted success shows the server state the three rows and back up now',
      (tester) async {
        final s = await _open(
          tester,
          vault: _hosted,
          view: _hostedSuccessView(),
        );
        final status = _status(tester);
        expect(status, contains(_hostedFile));
        expect(status, contains('${backupSize(_hostedBytes)} · on nas'));
        expect(
          status,
          contains('backed up ${backupWhen(_hostedCreated, _now)}'),
        );
        expect(_textIn(tester, find.byKey(backupsNowKey)), _backUpNow);
        expect(_button(tester, backupsNowKey).onPressed, isNotNull);
        expectRows(tester, 'success');
        expect(
          _sheetText(tester),
          contains('to restore a hosted vault, see docs/backups.md.'),
        );
        await _tapKey(tester, backupsNowKey);
        expect(s.controller.backUpNowCalls, [_hosted]);
        expect(s.harness.cli.calls, isEmpty);
      },
    );

    testWidgets('hosted never backed up shows no backup yet and back up now', (
      tester,
    ) async {
      await _open(tester, vault: _hosted, view: _hostedNeverView());
      final status = _status(tester);
      expect(status, contains(_neverTitle));
      expect(status, contains('nas makes the first one within the hour.'));
      expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      expectRows(tester, 'never');
    });

    testWidgets(
      'hosted backing up disables back up now and keeps the three rows',
      (tester) async {
        final s = await _open(
          tester,
          vault: _hosted,
          view: _hostedBackingUpView(),
        );
        final status = _status(tester);
        expect(status, contains('backing up on nas…'));
        expect(
          status,
          contains('you can close this sheet; nas finishes it either way.'),
        );
        expect(
          status,
          contains(
            'last backup: ${backupWhen(_hostedCreated, _now)} · '
            '${backupSize(_hostedBytes)}.',
          ),
        );
        expect(_textIn(tester, find.byKey(backupsNowKey)), _backingUpTitle);
        expect(_button(tester, backupsNowKey).onPressed, isNull);
        expectRows(tester, 'backing up');
        await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, isEmpty);
      },
    );

    testWidgets(
      'hosted failed shows the server message the three rows and retry',
      (tester) async {
        final s = await _open(tester, vault: _hosted, view: _hostedErrorView());
        final status = _status(tester);
        final auto = _hostedFailure(
          'backup_destination_unavailable',
          raw: 'permission denied',
        );
        final manual = _hostedFailure(
          'backup_destination_unavailable',
          raw: 'permission denied',
          automatic: false,
        );
        expect(status, contains(auto.detail));
        expect(status, anyOf(contains(auto.title), contains(manual.title)));
        expect(
          status,
          contains(
            'last good backup: ${backupWhen(_yesterdayCreated, _now)} · '
            '${backupSize(_hostedBytes)}. nas tries again hourly.',
          ),
        );
        expectRows(tester, 'failed');
        expect(find.byKey(backupsNowKey), findsNothing);
        await _tapKey(tester, backupsRetryKey);
        expect(s.controller.backUpNowCalls, [_hosted]);
      },
    );

    testWidgets(
      'hosted not configured shows the server text the command and the docs path with no picker',
      (tester) async {
        await _open(tester, vault: _hosted, view: _hostedNotConfiguredView());
        final status = _status(tester);
        expect(status, contains(_notConfiguredTitle));
        expect(status, contains(_notConfiguredBody));
        expect(_sheetText(tester), contains(_hostedCommand));
        expect(_textIn(tester, find.byKey(_guideLinkKey)), contains(_docs));
        expect(_sheetText(tester), contains('full guide: '));
        expect(_cardIcon(LucideIcons.server), findsOneWidget);
        // No picker, no button, no destination.
        expect(find.byKey(backupsNowKey), findsNothing);
        expect(find.byKey(backupsRetryKey), findsNothing);
        expect(find.byKey(backupsToggleKey), findsNothing);
        expect(find.byKey(backupsDestinationChooseKey), findsNothing);
        expect(find.byKey(_menuKey), findsNothing);
      },
    );

    testWidgets('hosted not configured copies the command and the docs path', (
      tester,
    ) async {
      final s = await _open(
        tester,
        vault: _hosted,
        view: _hostedNotConfiguredView(),
      );
      await _tapKey(tester, _copyCommandKey);
      expect(s.clipboard, [_hostedCommand]);
      // The docs path has its own copy button (setup_sheet pattern).
      final copies = find.descendant(
        of: _sheet,
        matching: find.byWidgetPredicate(
          (w) => w is Icon && w.icon == LucideIcons.copy,
        ),
      );
      expect(copies, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        await tester.tap(copies.at(i));
        await _frames(tester);
      }
      expect(s.clipboard, contains(_docs));
      await _tapKey(tester, _closeButtonKey);
      expect(_sheet, findsNothing);
      expect(s.closed, 1);
    });

    testWidgets(
      'hosted unreachable shows the existing state with back up now disabled',
      (tester) async {
        final s = await _open(
          tester,
          vault: _hosted,
          view: _hostedUnreachableView(),
        );
        final status = _status(tester);
        expect(status, contains(hostedUnreachableMessage('nas')));
        expect(status, contains(_unreachableBody));
        expect(_textIn(tester, find.byKey(backupsNowKey)), _backUpNow);
        expect(_button(tester, backupsNowKey).onPressed, isNull);
        expect(_cardIcon(LucideIcons.wifiOff), findsOneWidget);
        expect(
          _rgb((_card(tester).border! as Border).top.color),
          _rgb(OmColors.warn),
        );
        await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, isEmpty);
      },
    );

    testWidgets('hosted server too old shows its message with no button', (
      tester,
    ) async {
      final s = await _open(tester, vault: _hosted, view: _hostedTooOldView());
      final status = _status(tester);
      expect(status, contains(_tooOldTitle));
      expect(status, contains(_tooOldBody));
      expect(find.byKey(backupsNowKey), findsNothing);
      expect(find.byKey(backupsRetryKey), findsNothing);
      expect(_textIn(tester, find.byKey(_guideLinkKey)), contains(_docs));
      await _tapKey(tester, _closeButtonKey);
      expect(_sheet, findsNothing);
      expect(s.controller.backUpNowCalls, isEmpty);
    });

    testWidgets('hosted states never show a destination picker or the toggle', (
      tester,
    ) async {
      for (final view in [
        _hostedSuccessView(),
        _hostedNeverView(),
        _hostedBackingUpView(),
        _hostedErrorView(),
        _hostedNotConfiguredView(),
        _hostedUnreachableView(),
        _hostedTooOldView(),
        _hostedUnreadView(),
      ]) {
        await _open(tester, vault: _hosted, view: view);
        final why = '${view.mode}';
        expect(find.byKey(backupsToggleKey), findsNothing, reason: why);
        expect(
          find.byKey(backupsDestinationChooseKey),
          findsNothing,
          reason: why,
        );
        expect(find.byKey(_menuKey), findsNothing, reason: why);
        expect(find.byKey(_turnOnKey), findsNothing, reason: why);
        for (final p in BackupProvider.values) {
          expect(find.byKey(backupDestinationKey(p, 0)), findsNothing);
        }
        expect(_sheetText(tester), isNot(contains(_req25)), reason: why);
      }
    });
  });

  // ================================================================ AC 12
  group('AC12 semantics and keyboard', () {
    testWidgets('every control has a semantic label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pump();
      final cases = <(VaultRef, BackupViewState, Key, String)>[
        (_local, _offView(), backupsToggleKey, _turnOnEllipsis),
        (_local, _offView(), _closeKey, 'close'),
        (
          _local,
          _pickingView(),
          backupDestinationKey(BackupProvider.icloud, 0),
          'iCloud Drive',
        ),
        (
          _local,
          _pickingView(),
          backupDestinationKey(BackupProvider.googleDrive, 1),
          'work@example.com',
        ),
        (_local, _pickingView(), backupsDestinationChooseKey, 'choose folder'),
        (_local, _pickingView(), _cancelKey, 'cancel'),
        (_local, _pickingView(), _turnOnKey, 'turn on backups'),
        (_local, _neverView(), backupsNowKey, _backUpNow),
        (_local, _neverView(), backupsAutomaticKey, 'back up automatically'),
        (_local, _neverView(), backupsKeepKey, 'keep'),
        (_local, _neverView(), _keepDecKey, ''),
        (_local, _neverView(), _keepIncKey, ''),
        (_local, _neverView(), _menuKey, ''),
        (_local, _neverView(), backupsToggleKey, _turnOff),
        (_local, _errorView('backup_failed'), backupsRetryKey, 'retry'),
        (_hosted, _hostedNotConfiguredView(), _copyCommandKey, 'copy'),
        (_hosted, _hostedNotConfiguredView(), _closeButtonKey, 'close'),
      ];
      for (final (vault, view, key, label) in cases) {
        await _open(tester, vault: vault, view: view);
        final nodes = _semanticsAt(tester, key);
        final labelled = nodes
            .where(
              (n) =>
                  n.label.trim().isNotEmpty &&
                  n.label.toLowerCase().contains(label.toLowerCase()),
            )
            .toList();
        expect(labelled, isNotEmpty, reason: '$key has a label "$label"');
        final actionable = labelled.where((n) {
          final d = n.getSemanticsData();
          return d.hasAction(SemanticsAction.tap) ||
              d.hasAction(SemanticsAction.focus) ||
              n.getSemanticsData().flagsCollection.isTextField;
        });
        expect(actionable, isNotEmpty, reason: '$key is actionable');
      }
      handle.dispose();
    });

    testWidgets('every control works from the keyboard', (tester) async {
      // off: turn on backups… with Enter and with Space.
      for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
        await _open(tester, view: _offView());
        await _tabTo(tester, backupsToggleKey);
        await tester.sendKeyEvent(key);
        await _frames(tester);
        expect(
          find.byKey(backupsDestinationChooseKey),
          findsOneWidget,
          reason: '$key',
        );
      }

      // picking: Space selects a row, Enter turns on.
      var s = await _open(tester, view: _pickingView());
      await _tabTo(tester, backupDestinationKey(BackupProvider.icloud, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(_button(tester, _turnOnKey).onPressed, isNotNull);
      await _tabTo(tester, _turnOnKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(s.saves.single.settings.destination, _icloudDest);

      // back up now with Enter and with Space.
      for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
        s = await _open(tester, view: _successView());
        await _tabTo(tester, backupsNowKey);
        await tester.sendKeyEvent(key);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, [_local], reason: '$key');
      }

      // retry.
      s = await _open(tester, view: _errorView('backup_failed'));
      await _tabTo(tester, backupsRetryKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(s.controller.backUpNowCalls, [_local]);

      // the settings group.
      s = await _open(tester, view: _neverView());
      await _tabTo(tester, backupsAutomaticKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(s.saves.last.settings, _on.copyWith(automatic: false));

      s = await _open(tester, view: _neverView());
      await _tabTo(tester, _keepIncKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(s.saves.last.settings, _on.copyWith(keep: 31));

      s = await _open(tester, view: _neverView());
      await _tabTo(tester, _keepDecKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(s.saves.last.settings, _on.copyWith(keep: 29));

      s = await _open(tester, view: _neverView());
      await _tabTo(tester, backupsKeepKey);
      tester.testTextInput.enterText('12');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _frames(tester);
      expect(s.saves.last.settings, _on.copyWith(keep: 12));

      s = await _open(tester, view: _neverView());
      await _tabTo(tester, _menuKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);

      s = await _open(tester, view: _neverView());
      await _tabTo(tester, backupsToggleKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(s.saves.last.settings.enabled, isFalse);

      // close.
      s = await _open(tester, view: _successView());
      await _tabTo(tester, _closeKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(_sheet, findsNothing);

      // hosted: copy the command, close.
      s = await _open(tester, vault: _hosted, view: _hostedNotConfiguredView());
      await _tabTo(tester, _copyCommandKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(s.clipboard, [_hostedCommand]);
      await _tabTo(tester, _closeButtonKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await _frames(tester);
      expect(_sheet, findsNothing);
    });

    testWidgets('status and errors are text in the status column', (
      tester,
    ) async {
      for (final (vault, view, title) in [
        (_local, _offView(), _offTitle),
        (_local, _neverView(), _neverTitle),
        (_local, _backingUpView(), _backingUpTitle),
        (_hosted, _hostedNotConfiguredView(), _notConfiguredTitle),
        (_hosted, _hostedUnreachableView(), hostedUnreachableMessage('nas')),
        (_hosted, _hostedTooOldView(), _tooOldTitle),
      ]) {
        await _open(tester, vault: vault, view: view);
        expect(_status(tester), contains(title), reason: '${view.mode}');
        final style = tester.widget<RichText>(
          find.descendant(
            of: find.byKey(backupsStatusKey),
            matching: find.byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText() == title,
            ),
          ),
        );
        final ts = style.text.style;
        expect(ts?.fontSize, 17, reason: '${view.mode} title size');
        expect(ts?.fontWeight, FontWeight.w600, reason: '${view.mode}');
        expect(ts?.color, OmColors.fg0, reason: '${view.mode}');
      }
    });
  });

  // ================================================================ AC 13
  group('AC13 large text and a narrow window', () {
    testWidgets('no text clips or overflows at 1.3x text', (tester) async {
      for (final (name, vault, view) in _everyState()) {
        await _open(tester, vault: vault, view: view, textScale: 1.3);
        _expectNothingClipped(tester, name);
      }
    });

    testWidgets('no text clips or overflows in a 640 px window', (
      tester,
    ) async {
      for (final (name, vault, view) in _everyState()) {
        await _open(
          tester,
          vault: vault,
          view: view,
          size: const Size(640, 4000),
        );
        _expectNothingClipped(tester, name);
        expect(tester.getSize(_sheet).width, 608, reason: name);
      }
      await _open(
        tester,
        view: _errorView('backup_destination_unavailable'),
        size: const Size(640, 4000),
        textScale: 1.3,
      );
      _expectNothingClipped(tester, 'error at 640 px and 1.3x');
    });

    testWidgets('the card button never overlaps the status text at 1.3x', (
      tester,
    ) async {
      for (final (view, key) in [
        (_offView(), backupsToggleKey),
        (_successView(), backupsNowKey),
        (_errorView('backup_destination_unavailable'), backupsRetryKey),
      ]) {
        await _open(
          tester,
          view: view,
          textScale: 1.3,
          size: const Size(720, 4000),
        );
        final text = tester.getRect(find.byKey(backupsStatusKey));
        final button = tester.getRect(find.byKey(key));
        expect(
          text.overlaps(button),
          isFalse,
          reason: '${view.mode}: $button over $text',
        );
      }
    });

    testWidgets('the destination menu opens without overflow at 1.3x', (
      tester,
    ) async {
      await _open(tester, view: _successView(), textScale: 1.3);
      await _tapKey(tester, _menuKey);
      expect(tester.takeException(), isNull);
      expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
    });
  });

  // ================================================================ AC 14
  group('AC14 design values from pack 325', () {
    testWidgets('the panel is 620 wide with the setup sheet decoration', (
      tester,
    ) async {
      await _open(tester, view: _successView());
      expect(tester.getSize(_sheet).width, 620);
      final panel = tester.widget(_sheet);
      expect(panel, isA<DecoratedBox>());
      final d = (panel as DecoratedBox).decoration as BoxDecoration;
      expect(d.color, OmColors.surface2);
      expect(d.border, Border.all(color: OmColors.line2));
      expect(
        d.borderRadius,
        const BorderRadius.vertical(bottom: Radius.circular(10)),
      );
      // Centred at the top of the window.
      final r = tester.getRect(_sheet);
      expect(r.top, 0);
      expect(r.center.dx, _tall.width / 2);
    });

    testWidgets('the status card border and icon follow the state', (
      tester,
    ) async {
      for (final (vault, view, icon, border) in [
        (_local, _offView(), LucideIcons.archive, OmColors.line2),
        (_local, _neverView(), LucideIcons.archive, OmColors.line2),
        (_local, _backingUpView(), LucideIcons.loaderCircle, OmColors.line2),
        (_local, _successView(), LucideIcons.check, OmColors.line2),
        (
          _local,
          _errorView('backup_failed'),
          LucideIcons.triangleAlert,
          OmColors.danger,
        ),
        (_local, _tooOldView(), LucideIcons.triangleAlert, null),
        (_hosted, _hostedSuccessView(), LucideIcons.check, OmColors.line2),
        (
          _hosted,
          _hostedErrorView(),
          LucideIcons.triangleAlert,
          OmColors.danger,
        ),
        (
          _hosted,
          _hostedNotConfiguredView(),
          LucideIcons.server,
          OmColors.line2,
        ),
        (_hosted, _hostedUnreachableView(), LucideIcons.wifiOff, OmColors.warn),
        // Warn disc; the pack draws no card border colour for it.
        (_hosted, _hostedTooOldView(), LucideIcons.server, null),
      ]) {
        await _open(tester, vault: vault, view: view);
        final why = '$vault ${view.mode}';
        expect(_cardIcon(icon), findsWidgets, reason: why);
        final card = _card(tester);
        expect(card.borderRadius, BorderRadius.circular(8), reason: why);
        final c = (card.border! as Border).top.color;
        if (border == OmColors.line2) {
          expect(c, OmColors.line2, reason: why);
        } else if (border != null) {
          expect(_rgb(c), _rgb(border), reason: why);
        }
      }
    });
  });

  // ================================================================ verify
  // Contracts the implementer's doc comments promise, pinned from the view
  // state alone (so they hold before A2's discovery lands).
  group('AC9 and AC12 verify: the destination menu and focus contracts', () {
    BackupViewState withOptions() => BackupViewState(
      mode: BackupSheetMode.success,
      settings: _on,
      status: _successStatus(),
      options: _allOptions,
    );

    Finder checkIn(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byWidgetPredicate(
        (w) => w is Icon && w.icon == LucideIcons.check,
      ),
    );

    final icloudKey = backupDestinationKey(BackupProvider.icloud, 0);
    final googleKey = backupDestinationKey(BackupProvider.googleDrive, 0);
    final google2Key = backupDestinationKey(BackupProvider.googleDrive, 1);
    final oneDriveKey = backupDestinationKey(BackupProvider.oneDrive, 0);

    testWidgets(
      'the destination menu lists the view state options and marks the current one',
      (tester) async {
        await _open(tester, view: withOptions());
        expect(find.byKey(icloudKey), findsNothing, reason: 'closed menu');
        await _tapKey(tester, _menuKey);
        for (final key in [icloudKey, googleKey, google2Key, oneDriveKey]) {
          expect(find.byKey(key), findsOneWidget, reason: '$key');
        }
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        expect(checkIn(googleKey), findsOneWidget, reason: 'current row');
        for (final key in [icloudKey, google2Key, oneDriveKey]) {
          expect(checkIn(key), findsNothing, reason: '$key is not current');
        }
        expect(checkIn(backupsDestinationChooseKey), findsNothing);
      },
    );

    testWidgets(
      'a menu row saves that destination at once and closes the menu',
      (tester) async {
        final s = await _open(tester, view: withOptions());
        await _tapKey(tester, _menuKey);
        await _tapKey(tester, oneDriveKey);
        expect(s.saves, hasLength(1));
        expect(
          s.saves.single.settings,
          _on.copyWith(destination: _oneDriveDest),
        );
        expect(find.byKey(oneDriveKey), findsNothing, reason: 'menu closed');
        expect(_sheetText(tester), contains(_req25));
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'the current destination row closes the menu and saves nothing',
      (tester) async {
        final s = await _open(tester, view: withOptions());
        await _tapKey(tester, _menuKey);
        await _tapKey(tester, googleKey);
        expect(s.saves, isEmpty);
        expect(find.byKey(googleKey), findsNothing, reason: 'menu closed');
        expect(_sheetText(tester), contains(_req25));
      },
    );

    testWidgets('a picked folder from the menu saves it at once', (
      tester,
    ) async {
      final s = await _open(tester, view: withOptions());
      s.picker.directories.add(_otherChosenDest);
      await _tapKey(tester, _menuKey);
      await _tapKey(tester, backupsDestinationChooseKey);
      expect(s.saves, hasLength(1));
      expect(
        s.saves.single.settings,
        _on.copyWith(destination: _otherChosenDest),
      );
      expect(find.byKey(backupsDestinationChooseKey), findsNothing);
    });

    testWidgets('a second press on the destination button closes the menu', (
      tester,
    ) async {
      final s = await _open(tester, view: withOptions());
      await _tapKey(tester, _menuKey);
      expect(find.byKey(googleKey), findsOneWidget);
      // The open menu covers the button's lower part: press its top edge.
      await tester.tapAt(
        tester.getRect(find.byKey(_menuKey)).topCenter + const Offset(0, 4),
      );
      await _frames(tester);
      expect(find.byKey(googleKey), findsNothing);
      expect(_sheetText(tester), contains(_req25));
      expect(_sheet, findsOneWidget);
      expect(s.saves, isEmpty);
    });

    testWidgets('Escape closes the open menu first and the sheet second', (
      tester,
    ) async {
      final s = await _open(tester, view: withOptions());
      await _tabTo(tester, _menuKey);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      expect(find.byKey(googleKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(find.byKey(googleKey), findsNothing, reason: 'menu closed');
      expect(_sheet, findsOneWidget, reason: 'the sheet stays open');
      expect(s.controller.closeSheetCalls, isEmpty);
      expect(_sheetText(tester), contains(_req25));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);
      expect(_sheet, findsNothing);
      expect(s.controller.closeSheetCalls, [_local]);
    });

    testWidgets('a tap outside the menu closes it and keeps the sheet', (
      tester,
    ) async {
      final s = await _open(tester, view: withOptions());
      await _tapKey(tester, _menuKey);
      expect(find.byKey(googleKey), findsOneWidget);
      final card = tester.getTopLeft(find.byKey(backupsStatusKey));
      await tester.tapAt(card + const Offset(2, 2));
      await _frames(tester);
      expect(find.byKey(googleKey), findsNothing, reason: 'menu closed');
      expect(_sheet, findsOneWidget);
      expect(s.saves, isEmpty);
      expect(_sheetText(tester), contains(_req25));
    });

    testWidgets('the vault going off under an open menu closes the menu', (
      tester,
    ) async {
      final s = await _open(tester, view: withOptions());
      await _tapKey(tester, _menuKey);
      expect(find.byKey(googleKey), findsOneWidget);
      s.setView(_offView());
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(_status(tester), contains(_offTitle));
      expect(find.byKey(googleKey), findsNothing);
      // Back on: the menu is closed, not stuck open.
      s.setView(withOptions());
      await _frames(tester);
      expect(find.byKey(googleKey), findsNothing);
      expect(_sheetText(tester), contains(_req25));
      expect(_sheetText(tester), isNot(contains(_oldFolderNote)));
      await _tapKey(tester, _menuKey);
      expect(find.byKey(googleKey), findsOneWidget);
    });
  });

  group('AC3 verify: the picking selection', () {
    testWidgets('choose folder then a provider saves the provider', (
      tester,
    ) async {
      final s = await _open(tester, view: _pickingView());
      s.picker.directories.add(_chosenDest);
      await _tapKey(tester, backupsDestinationChooseKey);
      await _tapKey(tester, backupDestinationKey(BackupProvider.oneDrive, 0));
      await _tapKey(tester, _turnOnKey);
      expect(s.saves, hasLength(1));
      expect(s.saves.single.settings.destination, _oneDriveDest);
    });

    testWidgets('a provider then a picked folder saves the folder', (
      tester,
    ) async {
      final s = await _open(tester, view: _pickingView());
      await _tapKey(tester, backupDestinationKey(BackupProvider.icloud, 0));
      s.picker.directories.add(_chosenDest);
      await _tapKey(tester, backupsDestinationChooseKey);
      await _tapKey(tester, _turnOnKey);
      expect(s.saves.single.settings.destination, _chosenDest);
    });

    testWidgets(
      'a reported picking state cancels to off and picks again clean',
      (tester) async {
        final s = await _open(tester, view: _pickingView());
        await _tapKey(tester, backupDestinationKey(BackupProvider.icloud, 0));
        expect(_button(tester, _turnOnKey).onPressed, isNotNull);
        await _tapKey(tester, _cancelKey);
        expect(_status(tester), contains(_offTitle));
        expect(find.byKey(_turnOnKey), findsNothing);
        expect(s.saves, isEmpty);

        await _tapKey(tester, backupsToggleKey);
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        expect(
          _button(tester, _turnOnKey).onPressed,
          isNull,
          reason: 'the earlier choice is forgotten',
        );
      },
    );

    testWidgets('a picked folder is forgotten when picking starts again', (
      tester,
    ) async {
      final s = await _open(tester, view: _offView());
      await _tapKey(tester, backupsToggleKey);
      s.picker.directories.add(_chosenDest);
      await _tapKey(tester, backupsDestinationChooseKey);
      expect(_button(tester, _turnOnKey).onPressed, isNotNull);
      await _tapKey(tester, _cancelKey);
      await _tapKey(tester, backupsToggleKey);
      expect(_button(tester, _turnOnKey).onPressed, isNull);
      expect(
        _textIn(tester, find.byKey(backupsDestinationChooseKey)),
        isNot(contains(_chosenDest)),
      );
      expect(s.saves, isEmpty);
    });
  });

  group('AC8 verify: keep field and stepper', () {
    testWidgets('keep normalises what was typed and skips an unchanged save', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      await tester.enterText(find.byKey(backupsKeepKey), '042');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _frames(tester);
      expect(s.saves, hasLength(1));
      expect(s.saves.single.settings.keep, 42);
      expect(_keepText(tester), '42');

      // The stored value again, typed with a leading zero: no save.
      await tester.enterText(find.byKey(backupsKeepKey), '042');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _frames(tester);
      expect(s.saves, hasLength(1), reason: 'unchanged keep saves nothing');
      expect(_keepText(tester), '42');

      // Not a number: the field shows the stored value again.
      for (final junk in ['abc', '', ' ']) {
        await tester.enterText(find.byKey(backupsKeepKey), junk);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _frames(tester);
        expect(_keepText(tester), '42', reason: '"$junk"');
      }
      expect(s.saves, hasLength(1));

      // Spaces around a number are ignored.
      await tester.enterText(find.byKey(backupsKeepKey), ' 7 ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _frames(tester);
      expect(s.saves.last.settings.keep, 7);
    });

    testWidgets('keep plus and minus are disabled at their bounds', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final (keep, incOn, decOn) in [
        (30, true, true),
        (365, false, true),
        (364, true, true),
        (1, true, false),
        (2, true, true),
      ]) {
        await _open(tester, view: _neverView(_on.copyWith(keep: keep)));
        await tester.pump();
        expect(
          _labelled(tester, _keepIncKey, 'keep one more'),
          isSemantics(hasEnabledState: true, isEnabled: incOn),
          reason: 'plus at $keep',
        );
        expect(
          _labelled(tester, _keepDecKey, 'keep one fewer'),
          isSemantics(hasEnabledState: true, isEnabled: decOn),
          reason: 'minus at $keep',
        );
      }
      handle.dispose();
    });
  });

  group('AC5 and AC12 verify: disabled controls and the spinner', () {
    testWidgets(
      'a disabled control is focusable but Enter and Space do nothing',
      (tester) async {
        // back up now while backing up.
        var s = await _open(tester, view: _backingUpView());
        await _tabTo(tester, backupsNowKey);
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
        ]) {
          await tester.sendKeyEvent(key);
          await _frames(tester);
        }
        expect(s.controller.backUpNowCalls, isEmpty);

        // turn on backups until a choice.
        s = await _open(tester, view: _pickingView());
        await _tabTo(tester, _turnOnKey);
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
        ]) {
          await tester.sendKeyEvent(key);
          await _frames(tester);
        }
        expect(s.saves, isEmpty);
        expect(find.byKey(_turnOnKey), findsOneWidget, reason: 'still picking');

        // keep plus at 365.
        s = await _open(tester, view: _neverView(_on.copyWith(keep: 365)));
        await _tabTo(tester, _keepIncKey);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);
        expect(s.saves, isEmpty);

        // back up now on an unreachable hosted vault.
        s = await _open(tester, vault: _hosted, view: _hostedUnreachableView());
        await _tabTo(tester, backupsNowKey);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);
        expect(s.controller.backUpNowCalls, isEmpty);
      },
    );

    testWidgets(
      'the running spinner turns and stands still with animations off',
      (tester) async {
        await _open(tester, view: _backingUpView());
        expect(_cardIcon(LucideIcons.loaderCircle), findsOneWidget);
        expect(
          tester.binding.transientCallbackCount,
          greaterThan(0),
          reason: 'the spinner is animating',
        );

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await _open(tester, view: _backingUpView());
        expect(_cardIcon(LucideIcons.loaderCircle), findsOneWidget);
        expect(
          tester.binding.transientCallbackCount,
          0,
          reason: 'no animation with disableAnimations',
        );
      },
    );
  });

  group('AC11 verify: the hosted note', () {
    const note = 'to restore a hosted vault, see docs/backups.md.';

    testWidgets(
      'the hosted note shows with a result and not while running or failed',
      (tester) async {
        for (final (view, shown) in [
          (_hostedSuccessView(), true),
          (_hostedNeverView(), true),
          (_hostedBackingUpView(), false),
          (_hostedErrorView(), false),
        ]) {
          await _open(tester, vault: _hosted, view: view);
          expect(
            _sheetText(tester),
            shown ? contains(note) : isNot(contains(note)),
            reason: '${view.mode}',
          );
        }
      },
    );
  });

  // ================================================================ fix round 1
  // Test gaps of review r1 (findings 1, 7, 8, 9) and the contracts of the
  // production fixes (findings 2 to 6).
  group('AC3 verify: the radio list reports the selection', () {
    final choose = backupsDestinationChooseKey;

    testWidgets(
      'nothing is checked until a row is chosen and one row at a time',
      (tester) async {
        final s = await _open(tester, view: _offView());
        final handle = tester.ensureSemantics();
        await _tapKey(tester, backupsToggleKey);
        await tester.pump();
        final rows = [..._discoveredKeys, choose];
        _expectChecked(tester, rows, why: 'on entry');

        await _tapKey(tester, _discoveredKeys[0]);
        _expectChecked(
          tester,
          rows,
          checked: {_discoveredKeys[0]},
          why: 'icloud',
        );
        await _tapKey(tester, _discoveredKeys[2]);
        _expectChecked(
          tester,
          rows,
          checked: {_discoveredKeys[2]},
          why: 'second google account',
        );

        // choose folder: the picked folder takes the check from the provider.
        s.picker.directories.add(_chosenDest);
        await _tapKey(tester, choose);
        _expectChecked(tester, rows, checked: {choose}, why: 'picked folder');
        await _tapKey(tester, _discoveredKeys[3]);
        _expectChecked(
          tester,
          rows,
          checked: {_discoveredKeys[3]},
          why: 'a provider after a picked folder',
        );

        // A cancelled picker changes nothing.
        await _tapKey(tester, choose);
        _expectChecked(
          tester,
          rows,
          checked: {_discoveredKeys[3]},
          why: 'cancelled picker',
        );

        // Cancel and ask again: nothing is checked again.
        await _tapKey(tester, _cancelKey);
        await _tapKey(tester, backupsToggleKey);
        await tester.pump();
        _expectChecked(tester, rows, why: 'picking again');
        handle.dispose();
      },
    );

    testWidgets('a reported picking state starts with nothing checked', (
      tester,
    ) async {
      await _open(tester, view: _pickingView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      final rows = [..._discoveredKeys, choose];
      _expectChecked(tester, rows, why: 'on entry');
      await _tapKey(tester, _discoveredKeys[1]);
      _expectChecked(
        tester,
        rows,
        checked: {_discoveredKeys[1]},
        why: 'first google account',
      );
      handle.dispose();
    });
  });

  group('AC3 and AC9 verify: A2 creates and resolves the picked folder', () {
    testWidgets(
      'turning on a provider whose backup folder is missing creates it and saves its path',
      (tester) async {
        final s = await _open(tester, view: _offView(), backupFolders: false);
        await _tapKey(tester, backupsToggleKey);
        expect(
          s.probe.createdDirectories,
          isEmpty,
          reason: 'picking creates nothing',
        );
        await _tapKey(tester, _discoveredKeys[0]);
        expect(
          s.probe.createdDirectories,
          isEmpty,
          reason: 'selecting creates nothing',
        );
        await _tapKey(tester, _turnOnKey);
        expect(s.probe.createdDirectories, [_icloudDest]);
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.destination, _icloudDest);
        expect(s.saves.single.settings.enabled, isTrue);
        _expectZeroRuns(s);
      },
    );

    testWidgets('turning on saves the symlink resolved path of the folder', (
      tester,
    ) async {
      final s = await _open(tester, view: _offView(), backupFolders: false);
      s.probe
        ..addDirectory('/Volumes/real/gdrive-backups')
        ..addSymlink(_googleDest, '/Volumes/real/gdrive-backups');
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, _discoveredKeys[1]);
      await _tapKey(tester, _turnOnKey);
      expect(
        s.probe.createdDirectories,
        isEmpty,
        reason: 'it was already there',
      );
      expect(
        s.saves.single.settings.destination,
        '/Volumes/real/gdrive-backups',
      );
    });

    testWidgets(
      'a provider folder that cannot be made saves nothing and says why in the list',
      (tester) async {
        final s = await _open(tester, view: _offView(), backupFolders: false);
        s.probe.denyCreate(_icloudDest);
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        await _tapKey(tester, _turnOnKey);

        expect(s.saves, isEmpty);
        expect(tester.takeException(), isNull);
        final detail = _unavailableDetail(_icloudDest, BackupProvider.icloud);
        expect(_status(tester), contains(detail));
        expect(_cardIcon(LucideIcons.triangleAlert), findsOneWidget);
        // Still picking, and the button works again.
        expect(find.byKey(_turnOnKey), findsOneWidget);
        expect(_button(tester, _turnOnKey).onPressed, isNotNull);

        // Another provider works, and the failure line goes.
        await _tapKey(tester, _discoveredKeys[3]);
        await _tapKey(tester, _turnOnKey);
        expect(s.saves.single.settings.destination, _oneDriveDest);
        expect(s.probe.createdDirectories, [_oneDriveDest]);
        expect(_sheetText(tester), isNot(contains(detail)));
      },
    );

    testWidgets(
      'the destination menu creates a missing provider folder and says why when it cannot',
      (tester) async {
        final s = await _open(
          tester,
          view: _successView(),
          backupFolders: false,
        );
        s.probe.denyCreate(_icloudDest);
        await _tapKey(tester, _menuKey);
        await _tap(tester, find.byKey(_discoveredKeys[0]));
        expect(s.saves, isEmpty);
        final detail = _unavailableDetail(_icloudDest, BackupProvider.icloud);
        expect(_sheetText(tester), contains(detail));

        await _tapKey(tester, _menuKey);
        await _tap(tester, find.byKey(_discoveredKeys[3]));
        expect(s.probe.createdDirectories, [_oneDriveDest]);
        expect(s.saves.single.settings.destination, _oneDriveDest);
        expect(_sheetText(tester), isNot(contains(detail)));
      },
    );
  });

  group('AC2 and AC3 verify round 2: provider row names', () {
    /// A Text whose whole plain text is [name], inside the row at [key].
    Finder named(Key key, String name) => find.descendant(
      of: find.byKey(key),
      matching: find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == name,
      ),
    );

    const names = [
      'iCloud Drive',
      'Google Drive · connor@example.com',
      'Google Drive · work@example.com',
      'OneDrive · Personal',
    ];

    testWidgets(
      'a label that already has its provider prefix is not given it twice',
      (tester) async {
        // The view state's options carry composed labels.
        await _open(tester, view: _pickingView());
        for (final (i, name) in names.indexed) {
          expect(named(_discoveredKeys[i], name), findsOneWidget, reason: name);
        }
      },
    );

    testWidgets(
      'composed labels in a menu are not given the provider prefix twice',
      (tester) async {
        final composed = BackupViewState(
          mode: BackupSheetMode.success,
          settings: _on,
          status: _successStatus(),
          options: _allOptions,
        );
        await _open(tester, view: composed);
        await _tapKey(tester, _menuKey);
        for (final (i, name) in names.indexed) {
          expect(named(_discoveredKeys[i], name), findsOneWidget, reason: name);
        }
      },
    );

    testWidgets(
      'bare labels from discovery are given their provider prefix once in the list',
      (tester) async {
        await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        for (final (i, name) in names.indexed) {
          expect(named(_discoveredKeys[i], name), findsOneWidget, reason: name);
        }
      },
    );

    testWidgets(
      'bare labels from discovery are given their provider prefix once in the menu',
      (tester) async {
        await _open(tester, view: _successView());
        await _tapKey(tester, _menuKey);
        for (final (i, name) in names.indexed) {
          expect(named(_discoveredKeys[i], name), findsOneWidget, reason: name);
        }
      },
    );
  });

  group('AC3 and AC9 verify round 2: the picked folder is resolved first', () {
    const link = '/Volumes/nas/link-to-backups';
    const target = '/Volumes/real/nas-backups';
    const missing = '/Volumes/missing/backups';

    testWidgets('turning on a chosen folder saves its symlink resolved path', (
      tester,
    ) async {
      final s = await _open(tester, view: _offView());
      s.probe
        ..addDirectory(target)
        ..addSymlink(link, target);
      s.picker.directories.add(link);
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, backupsDestinationChooseKey);
      await _tapKey(tester, _turnOnKey);
      expect(s.saves, hasLength(1));
      expect(s.saves.single.settings.destination, target);
      expect(s.saves.single.settings.enabled, isTrue);
      expect(
        s.probe.createdDirectories,
        isEmpty,
        reason: 'a chosen folder is never made',
      );
    });

    testWidgets('a chosen folder from the menu is saved symlink resolved', (
      tester,
    ) async {
      final s = await _open(tester, view: _successView());
      s.probe
        ..addDirectory(target)
        ..addSymlink(link, target);
      s.picker.directories.add(link);
      await _tapKey(tester, _menuKey);
      await _tapKey(tester, backupsDestinationChooseKey);
      expect(s.saves, hasLength(1));
      expect(s.saves.single.settings, _on.copyWith(destination: target));
      expect(s.probe.createdDirectories, isEmpty);
    });

    testWidgets(
      'a chosen folder that cannot be resolved saves nothing and names the picked folder',
      (tester) async {
        final s = await _open(tester, view: _offView());
        s.picker.directories.add(missing);
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, backupsDestinationChooseKey);
        await _tapKey(tester, _turnOnKey);

        expect(s.saves, isEmpty);
        expect(tester.takeException(), isNull);
        final detail = _unavailableDetail(missing, null);
        expect(detail, startsWith("can't write to $missing."));
        expect(_status(tester), contains(detail));
        expect(_cardIcon(LucideIcons.triangleAlert), findsOneWidget);
        // Still picking, with the button working again for another folder.
        expect(find.byKey(_turnOnKey), findsOneWidget);
        expect(_button(tester, _turnOnKey).onPressed, isNotNull);
        s.picker.directories.add(_otherChosenDest);
        await _tapKey(tester, backupsDestinationChooseKey);
        await _tapKey(tester, _turnOnKey);
        expect(s.saves.single.settings.destination, _otherChosenDest);
        expect(_sheetText(tester), isNot(contains(detail)));
      },
    );

    testWidgets(
      'a chosen folder from the menu that cannot be resolved saves nothing and says why',
      (tester) async {
        final s = await _open(tester, view: _successView());
        s.picker.directories.add(missing);
        await _tapKey(tester, _menuKey);
        await _tapKey(tester, backupsDestinationChooseKey);

        expect(s.saves, isEmpty);
        expect(tester.takeException(), isNull);
        final detail = _unavailableDetail(missing, null);
        expect(_sheetText(tester), contains(detail));
        expect(_status(tester), isNot(contains(detail)));
        expect(_sheetText(tester), contains('My Drive/Open Memex Backups'));
        // The next pick clears the line and saves.
        s.picker.directories.add(_otherChosenDest);
        await _tapKey(tester, _menuKey);
        await _tapKey(tester, backupsDestinationChooseKey);
        expect(s.saves.single.settings.destination, _otherChosenDest);
        expect(_sheetText(tester), isNot(contains(detail)));
      },
    );

    testWidgets(
      'turn on backups stays disabled while the folder is being resolved',
      (tester) async {
        final s = await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        final before = s.resolveCalls;
        final gate = s.holdResolves();
        await tester.tap(find.byKey(_turnOnKey));
        await _frames(tester);

        // Mid resolve: still the list, the button off, nothing saved.
        expect(s.resolveCalls, before + 1);
        expect(s.saves, isEmpty);
        expect(find.byKey(_discoveredKeys[0]), findsOneWidget);
        expect(_button(tester, _turnOnKey).onPressed, isNull);
        await tester.tap(find.byKey(_turnOnKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.resolveCalls, before + 1, reason: 'no second resolve');
        expect(s.saves, isEmpty);

        gate.complete();
        await _frames(tester);
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.destination, _icloudDest);
        expect(find.byKey(_turnOnKey), findsNothing);
      },
    );

    testWidgets(
      'a destination menu pick saves only once the folder is resolved',
      (tester) async {
        final s = await _open(tester, view: _successView());
        await _tapKey(tester, _menuKey);
        final gate = s.holdResolves();
        await _tap(tester, find.byKey(_discoveredKeys[3]));
        expect(s.saves, isEmpty);
        expect(find.byKey(_discoveredKeys[3]), findsNothing, reason: 'closed');
        gate.complete();
        await _frames(tester);
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.destination, _oneDriveDest);
      },
    );

    testWidgets('closing the sheet while turn on resolves saves nothing', (
      tester,
    ) async {
      final s = await _open(tester, view: _offView());
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, _discoveredKeys[0]);
      final gate = s.holdResolves();
      await _tapKey(tester, _turnOnKey);
      await _tapKey(tester, _closeKey);
      expect(_sheet, findsNothing);
      gate.complete();
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(s.saves, isEmpty);
    });

    testWidgets(
      'closing the sheet while an unusable folder resolves raises nothing',
      (tester) async {
        for (final fromMenu in [false, true]) {
          final s = await _open(
            tester,
            view: fromMenu ? _successView() : _offView(),
          );
          s.picker.directories.add(missing);
          if (fromMenu) {
            await _tapKey(tester, _menuKey);
          } else {
            await _tapKey(tester, backupsToggleKey);
          }
          final gate = s.holdResolves();
          await _tapKey(tester, backupsDestinationChooseKey);
          if (!fromMenu) await _tapKey(tester, _turnOnKey);
          await _tapKey(tester, _closeKey);
          expect(_sheet, findsNothing, reason: 'fromMenu $fromMenu');
          gate.complete();
          await _frames(tester);
          expect(tester.takeException(), isNull, reason: 'fromMenu $fromMenu');
          expect(s.saves, isEmpty, reason: 'fromMenu $fromMenu');
        }
      },
    );

    testWidgets('closing the sheet while a menu pick resolves saves nothing', (
      tester,
    ) async {
      final s = await _open(tester, view: _successView());
      await _tapKey(tester, _menuKey);
      final gate = s.holdResolves();
      await _tap(tester, find.byKey(_discoveredKeys[0]));
      await _tapKey(tester, _closeKey);
      expect(_sheet, findsNothing);
      gate.complete();
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(s.saves, isEmpty);
    });
  });

  group('AC3 verify round 3: cancel is disabled while turn on is pending', () {
    const missing = '/Volumes/missing/backups';

    testWidgets(
      'cancel is disabled while the folder resolves and a tap on it keeps the list',
      (tester) async {
        final s = await _open(tester, view: _offView());
        final handle = tester.ensureSemantics();
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        expect(_button(tester, _cancelKey).onPressed, isNotNull);
        final gate = s.holdResolves();
        await _tapKey(tester, _turnOnKey);

        expect(_button(tester, _cancelKey).onPressed, isNull);
        expect(
          _labelled(tester, _cancelKey, 'cancel'),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
        await tester.tap(find.byKey(_cancelKey), warnIfMissed: false);
        await _frames(tester);
        // Still the list, not the off view, and nothing saved yet.
        expect(find.byKey(_turnOnKey), findsOneWidget);
        expect(find.byKey(_discoveredKeys[0]), findsOneWidget);
        expect(_status(tester), contains(_pickTitle));
        expect(_status(tester), isNot(contains(_offTitle)));
        expect(s.saves, isEmpty);

        // The pending turn on still lands, exactly once, and shows the on view.
        gate.complete();
        await _frames(tester);
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.enabled, isTrue);
        expect(s.saves.single.settings.destination, _icloudDest);
        expect(find.byKey(_turnOnKey), findsNothing);
        expect(find.byKey(_cancelKey), findsNothing);
        expect(_status(tester), isNot(contains(_offTitle)));
        handle.dispose();
      },
    );

    testWidgets('cancel is disabled while the save is in flight', (
      tester,
    ) async {
      final s = await _open(tester, view: _offView());
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, _discoveredKeys[0]);
      s.holdSaves();
      await _tapKey(tester, _turnOnKey);
      expect(s.saves, hasLength(1));

      expect(_button(tester, _cancelKey).onPressed, isNull);
      await tester.tap(find.byKey(_cancelKey), warnIfMissed: false);
      await _frames(tester);
      expect(find.byKey(_turnOnKey), findsOneWidget);
      expect(_status(tester), contains(_pickTitle));

      s.releaseSaves();
      await _frames(tester);
      expect(s.saves, hasLength(1));
      expect(s.saves.single.settings.enabled, isTrue);
      expect(find.byKey(_cancelKey), findsNothing);
    });

    testWidgets(
      'cancel works again after a folder that cannot be resolved and leaves backups off',
      (tester) async {
        final s = await _open(tester, view: _offView());
        s.picker.directories.add(missing);
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, backupsDestinationChooseKey);
        final gate = s.holdResolves();
        await _tapKey(tester, _turnOnKey);
        expect(_button(tester, _cancelKey).onPressed, isNull);

        gate.complete();
        await _frames(tester);
        expect(_sheetText(tester), contains(_unavailableDetail(missing, null)));
        expect(_button(tester, _cancelKey).onPressed, isNotNull);

        await _tapKey(tester, _cancelKey);
        expect(_status(tester), contains(_offTitle));
        expect(find.byKey(_turnOnKey), findsNothing);
        expect(s.saves, isEmpty);
      },
    );

    testWidgets(
      'cancel works again after a failed save and leaves backups off',
      (tester) async {
        final s = await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        s.saveError = Exception('could not create the folder');
        await _tapKey(tester, _turnOnKey);
        expect(tester.takeException(), isNull);
        expect(_button(tester, _cancelKey).onPressed, isNotNull);

        await _tapKey(tester, _cancelKey);
        expect(_status(tester), contains(_offTitle));
        expect(find.byKey(_turnOnKey), findsNothing);
        // The one attempted save was the failed turn on; cancel saved nothing.
        expect(s.saves, hasLength(1));
      },
    );
  });

  group('AC3 and AC8 verify: settings saves are awaited and serialised', () {
    testWidgets(
      'two quick keep presses step twice while the first save is in flight',
      (tester) async {
        final s = await _open(tester, view: _neverView());
        s.holdSaves();
        await tester.tap(find.byKey(_keepIncKey));
        await tester.pump();
        await tester.tap(find.byKey(_keepIncKey));
        await tester.pump();
        // The second save waits for the first to land.
        expect(s.saves.map((x) => x.settings.keep), [31]);
        s.releaseSaves();
        await _frames(tester);
        expect(s.saves.map((x) => x.settings.keep), [31, 32]);
        expect(_keepText(tester), '32');
      },
    );

    testWidgets('a keep press and a switch press in flight both land', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      s.holdSaves();
      await tester.tap(find.byKey(backupsAutomaticKey));
      await tester.pump();
      await tester.tap(find.byKey(_keepDecKey));
      await tester.pump();
      expect(s.saves, hasLength(1));
      s.releaseSaves();
      await _frames(tester);
      expect(s.saves, hasLength(2));
      // The second change was made on top of the first.
      expect(s.saves.last.settings, _on.copyWith(automatic: false, keep: 29));
    });

    testWidgets('a failed save does not stop the next one', (tester) async {
      final s = await _open(tester, view: _neverView());
      s.saveError = StateError('disk full');
      await _tapKey(tester, _keepIncKey);
      expect(tester.takeException(), isA<StateError>());
      s.saveError = null;
      await _tapKey(tester, _keepIncKey);
      expect(tester.takeException(), isNull);
      expect(s.saves.map((x) => x.settings.keep), [31, 31]);
      expect(_keepText(tester), '31');
    });

    testWidgets(
      'turn on backups keeps the list with its button disabled until the save lands',
      (tester) async {
        final s = await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        s.holdSaves();
        await _tapKey(tester, _turnOnKey);

        // Mid save: still the list, not the off view; no second save.
        expect(s.saves, hasLength(1));
        expect(find.byKey(_turnOnKey), findsOneWidget);
        expect(_button(tester, _turnOnKey).onPressed, isNull);
        expect(find.byKey(_discoveredKeys[0]), findsOneWidget);
        expect(_status(tester), contains(_pickTitle));
        await tester.tap(find.byKey(_turnOnKey), warnIfMissed: false);
        await _frames(tester);
        expect(s.saves, hasLength(1));

        s.releaseSaves();
        await _frames(tester);
        expect(find.byKey(_turnOnKey), findsNothing);
        expect(_status(tester), contains(_neverTitle));
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.destination, _icloudDest);
      },
    );

    testWidgets(
      'a failed turn on shows the destination unavailable detail in the list and can be tried again',
      (tester) async {
        final s = await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        s.saveError = Exception('could not create the folder');
        await _tapKey(tester, _turnOnKey);

        expect(
          tester.takeException(),
          isNull,
          reason: 'handled, not unhandled',
        );
        final detail = _unavailableDetail(_icloudDest, BackupProvider.icloud);
        expect(
          detail,
          startsWith("can't write to Open Memex Backups in icloud drive."),
        );
        expect(_status(tester), contains(detail));
        expect(_status(tester), isNot(contains(_pickBody)));
        expect(_cardIcon(LucideIcons.triangleAlert), findsOneWidget);
        expect(
          _rgb((_card(tester).border! as Border).top.color),
          _rgb(OmColors.danger),
        );
        expect(find.byKey(_turnOnKey), findsOneWidget);
        expect(_button(tester, _turnOnKey).onPressed, isNotNull);
        expect(find.byKey(_discoveredKeys[0]), findsOneWidget);

        // Try again and it lands: the failure line is gone.
        s.saveError = null;
        await _tapKey(tester, _turnOnKey);
        expect(find.byKey(_turnOnKey), findsNothing);
        expect(_sheetText(tester), isNot(contains(detail)));
        expect(_status(tester), contains(_neverTitle));
      },
    );

    testWidgets('a failed turn on of a chosen folder names the folder', (
      tester,
    ) async {
      final s = await _open(tester, view: _pickingView());
      s.picker.directories.add(_chosenDest);
      await _tapKey(tester, backupsDestinationChooseKey);
      s.saveError = Exception('read-only volume');
      await _tapKey(tester, _turnOnKey);
      expect(tester.takeException(), isNull);
      final detail = _unavailableDetail(_chosenDest, null);
      expect(detail, startsWith("can't write to $_chosenDest."));
      expect(_status(tester), contains(detail));

      // "cancel" forgets the failure.
      await _tapKey(tester, _cancelKey);
      expect(_sheetText(tester), isNot(contains(detail)));
      await _tapKey(tester, backupsToggleKey);
      expect(_sheetText(tester), isNot(contains(detail)));
      expect(_status(tester), contains(_pickBody));
    });

    testWidgets(
      'a failed destination change from the menu shows why under the settings and clears on the next pick',
      (tester) async {
        final s = await _open(tester, view: _successView());
        s.saveError = Exception('denied');
        await _tapKey(tester, _menuKey);
        await _tap(tester, find.byKey(_discoveredKeys[3]));

        expect(tester.takeException(), isNull);
        final detail = _unavailableDetail(
          _oneDriveDest,
          BackupProvider.oneDrive,
        );
        expect(_sheetText(tester), contains(detail));
        // The line is danger-coloured and sits under the settings group, not
        // in the status card.
        expect(_status(tester), isNot(contains(detail)));
        final line = tester.widget<RichText>(_text(detail));
        expect(line.text.style?.color, OmColors.danger);
        expect(
          tester.getRect(_text(detail)).top,
          greaterThan(tester.getRect(find.byKey(backupsAutomaticKey)).bottom),
        );
        // The destination did not change.
        expect(_sheetText(tester), contains('My Drive/Open Memex Backups'));
        expect(_sheetText(tester), contains(_req25));

        // The current row saves nothing and clears the line.
        s.saveError = null;
        await _tapKey(tester, _menuKey);
        await _tap(tester, find.byKey(_discoveredKeys[1]));
        expect(_sheetText(tester), isNot(contains(detail)));
        expect(s.saves, hasLength(1), reason: 'only the failed one was tried');
      },
    );

    testWidgets(
      'a failed keep automatic or off save is reported, not dropped',
      (tester) async {
        for (final (name, act)
            in <(String, Future<void> Function(WidgetTester))>[
              ('keep plus', (t) => _tapKey(t, _keepIncKey)),
              (
                'keep typed',
                (t) async {
                  await t.enterText(find.byKey(backupsKeepKey), '12');
                  await t.testTextInput.receiveAction(TextInputAction.done);
                  await _frames(t);
                },
              ),
              ('automatic', (t) => _tapKey(t, backupsAutomaticKey)),
              ('turn off', (t) => _tapKey(t, backupsToggleKey)),
            ]) {
          final s = await _open(tester, view: _neverView());
          s.saveError = StateError('disk full: $name');
          await act(tester);
          final reported = tester.takeException();
          expect(reported, isNotNull, reason: name);
          // Submitting a typed value and then leaving the field each try the
          // save, so a typed keep may report twice.
          if (name != 'keep typed') {
            expect(reported, isA<StateError>(), reason: name);
            expect('$reported', contains(name));
            expect(s.saves, hasLength(1), reason: name);
          }
        }
      },
    );
  });

  group('AC9 verify: Escape after a clicked menu', () {
    testWidgets(
      'Escape closes only the menu when a click opened it and the sheet next',
      (tester) async {
        final s = await _open(tester, view: _successView());
        // A tap opens the menu without giving anything focus (the way a
        // mouse click does).
        await _tapKey(tester, _menuKey);
        expect(find.byKey(_discoveredKeys[1]), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(
          find.byKey(_discoveredKeys[1]),
          findsNothing,
          reason: 'menu closed',
        );
        expect(_sheet, findsOneWidget, reason: 'the sheet stays open');
        expect(s.controller.closeSheetCalls, isEmpty);
        expect(s.closed, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(_sheet, findsNothing);
        expect(s.controller.closeSheetCalls, [_local]);
      },
    );
  });

  group('AC11 verify: a hosted vault that is not read yet', () {
    testWidgets(
      'shows a neutral checking card with back up now disabled and no claims',
      (tester) async {
        for (final view in [
          _hostedUnreadView(),
          const BackupViewState(
            mode: BackupSheetMode.pickingDestination,
            hosted: true,
          ),
        ]) {
          final s = await _open(tester, vault: _hosted, view: view);
          final handle = tester.ensureSemantics();
          await tester.pump();
          final why = '${view.mode}';
          final status = _status(tester);
          expect(status, contains('checking backups on nas…'), reason: why);
          expect(status, contains(_unreachableBody), reason: why);
          expect(status, isNot(contains(_neverTitle)), reason: why);
          expect(status, isNot(contains('makes the first one')), reason: why);
          expect(_cardIcon(LucideIcons.server), findsOneWidget, reason: why);
          expect(
            (_card(tester).border! as Border).top.color,
            OmColors.line2,
            reason: why,
          );

          expect(_textIn(tester, find.byKey(backupsNowKey)), _backUpNow);
          expect(_button(tester, backupsNowKey).onPressed, isNull, reason: why);
          expect(
            _labelled(tester, backupsNowKey, _backUpNow),
            isSemantics(
              isButton: true,
              hasEnabledState: true,
              isEnabled: false,
            ),
            reason: why,
          );
          await tester.tap(find.byKey(backupsNowKey), warnIfMissed: false);
          await _frames(tester);
          expect(s.controller.backUpNowCalls, isEmpty, reason: why);

          // No server claims: no rows, no keep, no note, no retry.
          final text = _sheetText(tester);
          for (final claim in [
            'ON NAS',
            'backup folder',
            'set on nas',
            'latest ',
            'schedule',
            'once a day',
            'to restore a hosted vault',
            'backed up',
            'last backup',
          ]) {
            expect(text, isNot(contains(claim)), reason: '$why: $claim');
          }
          expect(find.byKey(backupsRetryKey), findsNothing, reason: why);
          handle.dispose();
        }
      },
    );

    testWidgets('becomes the server state once the controller has read it', (
      tester,
    ) async {
      final s = await _open(tester, vault: _hosted, view: _hostedUnreadView());
      expect(_button(tester, backupsNowKey).onPressed, isNull);
      s.setView(_hostedNeverView());
      await _frames(tester);
      expect(_status(tester), contains(_neverTitle));
      expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      expect(_sheetText(tester), contains('set on nas with --backup-dir'));
      s.setView(_hostedUnreadView());
      await _frames(tester);
      expect(_button(tester, backupsNowKey).onPressed, isNull);
      expect(_sheetText(tester), isNot(contains('set on nas')));
    });

    testWidgets('the keep row shows the keep the server reports', (
      tester,
    ) async {
      await _open(
        tester,
        vault: _hosted,
        view: BackupViewState(
          mode: BackupSheetMode.success,
          hosted: true,
          status: _hostedStatus(keep: 90),
        ),
      );
      expect(_sheetText(tester), contains('latest 90'));
      expect(_sheetText(tester), isNot(contains('latest 30')));

      await _open(
        tester,
        vault: _hosted,
        view: BackupViewState(
          mode: BackupSheetMode.success,
          hosted: true,
          status: _hostedStatus(keep: null),
        ),
      );
      expect(_sheetText(tester), contains('latest 30'));
    });
  });

  group('AC13 verify: the hosted command wraps', () {
    testWidgets('the whole command shows at 1.3x text and in a 640 px window', (
      tester,
    ) async {
      for (final (size, scale) in [
        (_tall, 1.0),
        (_tall, 1.3),
        (const Size(640, 4000), 1.0),
        (const Size(640, 4000), 1.3),
      ]) {
        await _open(
          tester,
          vault: _hosted,
          view: _hostedNotConfiguredView(),
          size: size,
          textScale: scale,
        );
        final why = '${size.width.toInt()} px at ${scale}x';
        final p = _paragraph(tester, _hostedCommand);
        expect(p.maxLines, isNull, reason: why);
        expect(p.overflow, TextOverflow.clip, reason: why);
        expect(p.didExceedMaxLines, isFalse, reason: why);
        // Wider than its row in any font: it wraps to more than one line.
        expect(
          p.size.height,
          greaterThan(p.preferredLineHeight * 1.5),
          reason: '$why: wraps',
        );
        _expectNothingClipped(tester, why);
        // The copy button stays inside the panel.
        expect(
          tester.getRect(find.byKey(_copyCommandKey)).right,
          lessThanOrEqualTo(tester.getRect(_sheet).right),
          reason: why,
        );
      }
    });
  });

  group('AC4 AC7 AC10 AC11 verify: the copy as literal text', () {
    final localCreated = _localAt(9, 14, 3);

    BackupViewState success({
      DateTime? at,
      int bytes = 41200000,
      String? destination,
    }) => BackupViewState(
      mode: BackupSheetMode.success,
      settings: _on.copyWith(destination: destination ?? _googleDest),
      status: BackupStatus(
        lastAttemptAt: at ?? localCreated,
        lastSuccessAt: at ?? localCreated,
        lastResult: 'created',
        lastFile: _file,
        lastFileCreatedAt: at ?? localCreated,
        lastBytes: bytes,
      ),
    );

    testWidgets('success shows the time and the size as written', (
      tester,
    ) async {
      for (final (at, bytes, wording, size) in [
        (localCreated, 41200000, 'today at 14:03', '41.2 MB'),
        (_localAt(8, 9, 2), 812345, 'yesterday at 09:02', '812 KB'),
        (_localAt(3, 8, 15), 1300000000, '3 nov at 08:15', '1.3 GB'),
        (_localAt(9, 0, 5), 999, 'today at 00:05', '999 B'),
      ]) {
        await _open(
          tester,
          view: success(at: at, bytes: bytes),
        );
        final status = _status(tester);
        expect(status, contains('backed up $wording'), reason: wording);
        expect(
          status,
          contains('$size · saved to Open Memex Backups'),
          reason: size,
        );
      }
      await _open(tester, view: success(destination: _chosenDest));
      expect(_status(tester), contains('41.2 MB · $_chosenDest'));
      await _open(tester, view: success());
      expect(
        _status(tester),
        contains(
          '41.2 MB · saved to Open Memex Backups in google drive. the google '
          "drive app uploads it; open memex can't see when that's done.",
        ),
      );
    });

    BackupViewState failed(
      String code, {
      String? raw,
      bool automatic = true,
      BackupProvider? provider = BackupProvider.googleDrive,
      String destination = _googleDest,
    }) => BackupViewState(
      mode: BackupSheetMode.error,
      settings: _on.copyWith(destination: destination),
      status: BackupStatus(
        lastAttemptAt: _localAt(9, 9, 0),
        lastSuccessAt: _localAt(8, 9, 2),
        lastResult: code,
        lastError: raw,
        lastFile: _yesterdayFile,
        lastFileCreatedAt: _localAt(8, 9, 2),
        lastBytes: _yesterdayBytes,
      ),
      errorCode: code,
      message: backupFailureMessage(
        code: code,
        message: raw,
        automatic: automatic,
        failedAt: _localAt(9, 9, 0),
        now: _now,
        destination: destination,
        provider: provider,
      ),
      automatic: automatic,
      failedAt: _localAt(9, 9, 0),
      warning: true,
    );

    testWidgets(
      'the error card shows the message and the last good backup as written',
      (tester) async {
        await _open(tester, view: failed('backup_destination_unavailable'));
        var status = _status(tester);
        expect(status, contains('the automatic backup failed at 09:00'));
        expect(
          status,
          contains(
            "can't write to Open Memex Backups in google drive. check that "
            "it's still there and connected",
          ),
        );
        expect(
          status,
          contains(
            'last good backup: yesterday at 09:02 · 41.0 MB. tries again '
            'hourly.',
          ),
        );

        await _open(
          tester,
          view: failed('backup_failed', raw: 'disk full', automatic: false),
        );
        status = _status(tester);
        expect(status, contains('back up now failed at 09:00'));
        expect(status, contains("the backup couldn't be made: disk full."));

        await _open(
          tester,
          view: failed(
            'backup_destination_unavailable',
            provider: null,
            destination: _chosenDest,
          ),
        );
        expect(_status(tester), contains("can't write to $_chosenDest."));
      },
    );

    testWidgets('the last good backup line leaves out a size the state lacks', (
      tester,
    ) async {
      final base = failed('backup_failed', raw: 'disk full');
      await _open(
        tester,
        view: BackupViewState(
          mode: base.mode,
          settings: base.settings,
          status: BackupStatus(
            lastAttemptAt: _localAt(9, 9, 0),
            lastSuccessAt: _localAt(8, 9, 2),
            lastResult: 'backup_failed',
            lastFile: _yesterdayFile,
            lastFileCreatedAt: _localAt(8, 9, 2),
          ),
          errorCode: base.errorCode,
          message: base.message,
          warning: true,
        ),
      );
      expect(
        _status(tester),
        contains('last good backup: yesterday at 09:02. tries again hourly.'),
      );
    });

    testWidgets('the binary states show the message as written', (
      tester,
    ) async {
      await _open(tester, view: _tooOldView());
      var status = _status(tester);
      expect(status, contains('this memex is too old to make backups'));
      expect(status, contains('update memex, then try again.'));
      await _open(tester, view: _binaryNotFoundView());
      status = _status(tester);
      expect(status, contains('memex binary not found'));
      expect(status, contains('install memex, or locate it, then try again.'));
    });

    testWidgets('hosted states show the time size and message as written', (
      tester,
    ) async {
      final created = _localAt(9, 3, 0);
      BackupStatus hostedStatus({bool inProgress = false}) => BackupStatus(
        lastAttemptAt: created,
        lastSuccessAt: created,
        lastResult: 'created',
        lastFile: _hostedFile,
        lastFileCreatedAt: created,
        lastBytes: _hostedBytes,
        enabled: true,
        keep: 30,
        inProgress: inProgress,
      );
      await _open(
        tester,
        vault: _hosted,
        view: BackupViewState(
          mode: BackupSheetMode.success,
          hosted: true,
          status: hostedStatus(),
        ),
      );
      var status = _status(tester);
      expect(status, contains('backed up today at 03:00'));
      expect(status, contains('18.6 MB · on nas'));

      await _open(
        tester,
        vault: _hosted,
        view: BackupViewState(
          mode: BackupSheetMode.backingUp,
          hosted: true,
          status: hostedStatus(inProgress: true),
        ),
      );
      expect(
        _status(tester),
        contains('last backup: today at 03:00 · 18.6 MB.'),
      );

      await _open(
        tester,
        vault: _hosted,
        view: BackupViewState(
          mode: BackupSheetMode.error,
          hosted: true,
          status: BackupStatus(
            lastAttemptAt: _localAt(9, 9, 0),
            lastSuccessAt: _localAt(8, 9, 2),
            lastResult: 'backup_destination_unavailable',
            lastFile: _hostedFile,
            lastFileCreatedAt: _localAt(8, 9, 2),
            lastBytes: _hostedBytes,
            enabled: true,
            keep: 30,
          ),
          errorCode: 'backup_destination_unavailable',
          message: backupFailureMessage(
            code: 'backup_destination_unavailable',
            automatic: true,
            failedAt: _localAt(9, 9, 0),
            now: _now,
            serverName: 'nas',
          ),
          warning: true,
        ),
      );
      status = _status(tester);
      expect(status, contains("nas's backup failed at 09:00"));
      expect(
        status,
        contains(
          "nas can't write to its backup folder. check that the folder given "
          'to --backup-dir exists on nas and is writable.',
        ),
      );
      expect(
        status,
        contains(
          'last good backup: yesterday at 09:02 · 18.6 MB. nas tries again '
          'hourly.',
        ),
      );
    });
  });

  // ================================================================ round 4
  // A stored destination is A2's symlink-resolved path, while discovery's
  // rows run through the symlink. The sheet compares the two through the real
  // file system (`resolveSymbolicLinksSync`), so these tests build real
  // folders under a temp dir.
  group('AC9 verify round 4: a provider folder reached through a symlink', () {
    Finder checkIn(Key key) => find.descendant(
      of: find.byKey(key),
      matching: find.byWidgetPredicate(
        (w) => w is Icon && w.icon == LucideIcons.check,
      ),
    );

    final googleKey = backupDestinationKey(BackupProvider.googleDrive, 0);
    final google2Key = backupDestinationKey(BackupProvider.googleDrive, 1);
    final icloudKey = backupDestinationKey(BackupProvider.icloud, 0);

    VaultBackupSettings storedAt(String destination) =>
        _on.copyWith(destination: destination);

    BackupViewState successAt(_Wi325Tree t, List<BackupDestinationOption> o) =>
        BackupViewState(
          mode: BackupSheetMode.success,
          settings: storedAt(t.resolved),
          status: _successStatus(),
          options: o,
        );

    testWidgets(
      'the menu marks the provider row whose folder the stored resolved path is',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        expect(t.resolved, isNot(t.optionPath), reason: 'a real symlink');
        await _open(
          tester,
          view: successAt(t, _wi325LinkedOptions(t)),
          home: t.home,
        );
        await _tapKey(tester, _menuKey);
        for (final key in [googleKey, google2Key, icloudKey]) {
          expect(find.byKey(key), findsOneWidget, reason: '$key');
        }
        // The first Google Drive row is the symlinked folder; the missing
        // folders before and after it are compared by their plain paths and
        // are not marked.
        expect(checkIn(googleKey), findsOneWidget, reason: 'the linked row');
        expect(checkIn(icloudKey), findsNothing);
        expect(checkIn(google2Key), findsNothing);
        expect(checkIn(backupsDestinationChooseKey), findsNothing);
      },
    );

    testWidgets(
      'the card the destination row and the success line name the provider',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        await _open(
          tester,
          view: successAt(t, _wi325LinkedOptions(t)),
          home: t.home,
        );
        expect(
          _textIn(tester, find.byKey(_menuKey)),
          contains('Google Drive · connor@example.com'),
        );
        expect(_sheetText(tester), contains('My Drive/Open Memex Backups'));
        expect(_status(tester), contains(_providerLine('google drive')));
        expect(_sheetText(tester), isNot(contains(t.resolved)));

        // B2-9's compact card names it too, while the menu is open.
        await _tapKey(tester, _menuKey);
        expect(
          _status(tester),
          contains(
            '${backupSize(_bytes)} · Open Memex Backups in google drive',
          ),
        );
        expect(_status(tester), isNot(contains(t.resolved)));
      },
    );

    testWidgets(
      'the sheet discovers the providers on open to name a symlinked folder',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        // The view state carries no options: only the sheet's own discovery
        // (over a probe seeded under the real home) can name the folder.
        final s = await _open(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: storedAt(t.resolved),
            status: _successStatus(),
          ),
          home: t.home,
          providers: false,
          seedProbe: (probe) => probe.seedGoogleDrive('connor@example.com'),
        );
        expect(s.probe.calls, contains('home'), reason: 'discovery ran');
        expect(
          _textIn(tester, find.byKey(_menuKey)),
          contains('Google Drive · connor@example.com'),
        );
        expect(_status(tester), contains(_providerLine('google drive')));
        await _tapKey(tester, _menuKey);
        expect(checkIn(googleKey), findsOneWidget);
        expect(_sheetText(tester), isNot(contains(t.resolved)));
      },
    );

    testWidgets(
      'a stored provider folder opens without discovery and a chosen folder with it',
      (tester) async {
        final plain = await _open(tester, view: _successView());
        expect(plain.probe.calls, isEmpty, reason: 'it reads as google drive');

        final chosen = await _open(
          tester,
          view: _successView(_on.copyWith(destination: _chosenDest)),
        );
        expect(chosen.probe.calls, contains('home'), reason: 'discovery ran');
        // Not a provider folder: it stays a chosen folder.
        expect(_lines(tester, find.byKey(_menuKey)), contains('memex-backups'));
        expect(_sheetText(tester), contains(_chosenDest));
      },
    );

    testWidgets(
      'a stored path that reads as a provider folder by itself keeps its own provider',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        // The stored path reads as a Google Drive folder, but it is a link to
        // the iCloud row's folder: the stored path's own reading wins.
        final icloudFolder =
            '${t.home}/Library/Mobile Documents/com~apple~CloudDocs/$_backupsFolder';
        Directory(icloudFolder).createSync(recursive: true);
        // A google-looking path that is the Open Memex Backups link itself.
        final googleLooking =
            '${t.storage}/GoogleDrive-other@example.com/My Drive';
        Directory(googleLooking).createSync(recursive: true);
        final link = '$googleLooking/$_backupsFolder';
        Link(link).createSync(icloudFolder);
        await _open(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: storedAt(link),
            status: _successStatus(),
            options: [
              BackupDestinationOption(
                provider: BackupProvider.icloud,
                label: 'iCloud Drive',
                path: icloudFolder,
              ),
              _chooseOption,
            ],
          ),
          home: t.home,
        );
        expect(
          _lines(tester, find.byKey(_menuKey)),
          contains('Google Drive · other@example.com'),
        );
        expect(_status(tester), contains(_providerLine('google drive')));
        expect(_status(tester), isNot(contains('icloud')));
      },
    );

    testWidgets(
      'a symlinked row that is not a provider folder is named by the stored path',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        final real = '${t.base}/plain/dest';
        Directory(real).createSync(recursive: true);
        final link = '${t.base}/link-to-dest';
        Link(link).createSync(real);
        await _open(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: storedAt(real),
            status: _successStatus(),
            options: [
              BackupDestinationOption(
                provider: BackupProvider.googleDrive,
                label: 'Google Drive · connor@example.com',
                path: link,
              ),
              _chooseOption,
            ],
          ),
          home: t.home,
        );
        // A chosen folder: its own name and full path, not the row's.
        expect(_lines(tester, find.byKey(_menuKey)), contains('dest'));
        expect(_sheetText(tester), contains(real));
        expect(_sheetText(tester), isNot(contains(link)));
        expect(_status(tester), isNot(contains('google drive')));
        expect(_status(tester), contains(real));
        // The row is still the folder: it carries the mark.
        await _tapKey(tester, _menuKey);
        expect(checkIn(googleKey), findsOneWidget);
      },
    );

    testWidgets(
      'a provider folder that is missing still compares equal by its plain path',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        // Nothing exists at the stored path, so there is nothing to resolve.
        final gone =
            '${t.storage}/GoogleDrive-work@example.com/My Drive/'
            '$_backupsFolder';
        await _open(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: storedAt(gone),
            status: _successStatus(),
            options: _wi325LinkedOptions(t),
          ),
          home: t.home,
        );
        expect(
          _textIn(tester, find.byKey(_menuKey)),
          contains('Google Drive · work@example.com'),
        );
        expect(_status(tester), contains(_providerLine('google drive')));
        await _tapKey(tester, _menuKey);
        expect(checkIn(google2Key), findsOneWidget, reason: 'the missing row');
        expect(checkIn(googleKey), findsNothing);
        expect(checkIn(icloudKey), findsNothing);
      },
    );

    testWidgets(
      'a stored path that runs through a symlink marks the row with the resolved path',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        // The stored destination is the link path and discovery's row is the
        // folder it leads to: both are compared resolved.
        await _open(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: storedAt(t.optionPath),
            status: _successStatus(),
            options: [
              BackupDestinationOption(
                provider: BackupProvider.googleDrive,
                label: 'Google Drive · connor@example.com',
                path: t.resolved,
              ),
              _chooseOption,
            ],
          ),
          home: t.home,
        );
        await _tapKey(tester, _menuKey);
        expect(checkIn(googleKey), findsOneWidget);
      },
    );

    testWidgets(
      'the success line names the provider folder and not the name of the link target',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        // The Open Memex Backups folder is itself a link to a folder with
        // another name; the stored destination is that other name.
        final drive = '${t.storage}/GoogleDrive-other@example.com/My Drive';
        Directory(drive).createSync(recursive: true);
        final store = '${t.base}/elsewhere/memex-store';
        Directory(store).createSync(recursive: true);
        final link = '$drive/$_backupsFolder';
        Link(link).createSync(store);
        await _open(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: storedAt(store),
            status: _successStatus(),
            options: [
              BackupDestinationOption(
                provider: BackupProvider.googleDrive,
                label: 'Google Drive · other@example.com',
                path: link,
              ),
              _chooseOption,
            ],
          ),
          home: t.home,
        );
        expect(_status(tester), contains(_providerLine('google drive')));
        expect(_status(tester), isNot(contains('memex-store')));
        await _tapKey(tester, _menuKey);
        expect(
          _status(tester),
          contains(
            '${backupSize(_bytes)} · Open Memex Backups in google drive',
          ),
        );
        expect(_status(tester), isNot(contains('memex-store')));
      },
    );

    testWidgets(
      'picking the symlinked row again resolves it to the stored path and saves nothing',
      (tester) async {
        final t = _wi325LinkedGoogleDrive();
        final s = await _open(
          tester,
          view: successAt(t, _wi325LinkedOptions(t)),
          home: t.home,
        );
        // A2's resolver follows the same link.
        s.probe
          ..addDirectory(t.resolved)
          ..addSymlink(t.optionPath, t.resolved);
        final before = s.resolveCalls;
        await _tapKey(tester, _menuKey);
        await _tap(tester, find.byKey(googleKey));
        expect(s.resolveCalls, before + 1);
        expect(s.saves, isEmpty, reason: 'it is the current destination');
      },
    );
  });

  // ================================================================ counts
  group('AC3 and AC9 verify round 4: resolve and save call counts', () {
    const link = '/Volumes/real/gdrive-backups';
    const missing = '/Volumes/missing/backups';

    testWidgets(
      'one turn on press resolves the provider folder once and saves the resolved path',
      (tester) async {
        final s = await _open(tester, view: _offView(), backupFolders: false);
        s.probe
          ..addDirectory(link)
          ..addSymlink(_googleDest, link);
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[1]);
        final before = s.resolveCalls;
        await _tapKey(tester, _turnOnKey);
        await _frames(tester);
        expect(s.resolveCalls, before + 1, reason: 'one resolve per press');
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.destination, link);
        expect(s.saves.single.settings.destination, isNot(_googleDest));
        expect(s.saves.single.settings.enabled, isTrue);
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'one menu pick resolves the provider folder once and saves the resolved path',
      (tester) async {
        final s = await _open(tester, view: _successView());
        s.probe
          ..addDirectory(link)
          ..addSymlink(_oneDriveDest, link);
        await _tapKey(tester, _menuKey);
        final before = s.resolveCalls;
        await _tap(tester, find.byKey(_discoveredKeys[3]));
        await _frames(tester);
        expect(s.resolveCalls, before + 1, reason: 'one resolve per pick');
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings, _on.copyWith(destination: link));
        expect(s.saves.single.settings.destination, isNot(_oneDriveDest));
        _expectZeroRuns(s);
      },
    );

    testWidgets(
      'a second turn on press while the folder resolves adds no resolve',
      (tester) async {
        final s = await _open(tester, view: _offView());
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, _discoveredKeys[0]);
        final before = s.resolveCalls;
        final gate = s.holdResolves();
        await tester.tap(find.byKey(_turnOnKey));
        await _frames(tester);
        expect(_button(tester, _turnOnKey).onPressed, isNull);
        await tester.tap(find.byKey(_turnOnKey), warnIfMissed: false);
        await _frames(tester);
        gate.complete();
        await _frames(tester);
        expect(s.resolveCalls, before + 1, reason: 'one resolve in all');
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.destination, _icloudDest);
      },
    );

    testWidgets(
      'a folder that cannot be resolved is tried once saves nothing and shows the text',
      (tester) async {
        final s = await _open(tester, view: _offView());
        s.picker.directories.add(missing);
        await _tapKey(tester, backupsToggleKey);
        await _tapKey(tester, backupsDestinationChooseKey);
        final before = s.resolveCalls;
        await _tapKey(tester, _turnOnKey);
        expect(s.resolveCalls, before + 1);
        expect(s.saves, isEmpty);
        expect(_status(tester), contains(_unavailableDetail(missing, null)));

        // From the menu: one resolve, no save, the text under the settings.
        final m = await _open(tester, view: _successView());
        m.picker.directories.add(missing);
        await _tapKey(tester, _menuKey);
        final beforeMenu = m.resolveCalls;
        await _tapKey(tester, backupsDestinationChooseKey);
        expect(m.resolveCalls, beforeMenu + 1);
        expect(m.saves, isEmpty);
        expect(_sheetText(tester), contains(_unavailableDetail(missing, null)));
      },
    );

    testWidgets('cancel resolves nothing and saves nothing', (tester) async {
      final s = await _open(tester, view: _offView());
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, _discoveredKeys[0]);
      final before = s.resolveCalls;
      await _tapKey(tester, _cancelKey);
      expect(s.resolveCalls, before);
      expect(s.saves, isEmpty);
      expect(_status(tester), contains(_offTitle));
    });

    testWidgets('a cancelled folder pick resolves nothing and saves nothing', (
      tester,
    ) async {
      // Turn on: the picker's queue is empty, so the dialog is cancelled.
      final s = await _open(tester, view: _offView());
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, _discoveredKeys[0]);
      final before = s.resolveCalls;
      await _tapKey(tester, backupsDestinationChooseKey);
      expect(s.picker.calls, hasLength(1));
      expect(s.resolveCalls, before);
      expect(s.saves, isEmpty);

      // From the menu.
      final m = await _open(tester, view: _successView());
      await _tapKey(tester, _menuKey);
      final beforeMenu = m.resolveCalls;
      await _tap(tester, find.byKey(backupsDestinationChooseKey));
      expect(m.picker.calls, hasLength(1));
      expect(m.resolveCalls, beforeMenu);
      expect(m.saves, isEmpty);
    });
  });

  // Hand mutants of review r4 (finding 1): the semantics flags, the focus
  // ring, the hover fill, the initial state fields, the error-flag clears
  // and the keep field's focus guards of backups_sheet*.dart.
  group('AC12 verify round 5: semantics flags of the press targets', () {
    final icloudKey = backupDestinationKey(BackupProvider.icloud, 0);

    /// The node inside [key]'s box that takes a tap.
    SemanticsNode pressNode(WidgetTester tester, Key key) {
      final nodes = _semanticsAt(
        tester,
        key,
      ).where((n) => n.getSemanticsData().hasAction(SemanticsAction.tap));
      expect(nodes, isNotEmpty, reason: 'a tap node inside $key');
      return nodes.first;
    }

    testWidgets('buttons report button and nothing of a switch or a radio', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      for (final (key, label) in [
        (backupsNowKey, _backUpNow),
        (backupsToggleKey, _turnOff),
        (_closeKey, 'close'),
        (_keepIncKey, 'keep one more backup'),
        (_keepDecKey, 'keep one fewer backup'),
      ]) {
        expect(
          pressNode(tester, key),
          isSemantics(
            label: label,
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
            hasToggledState: false,
            hasCheckedState: false,
            isInMutuallyExclusiveGroup: false,
          ),
          reason: '$key',
        );
      }
      handle.dispose();
    });

    testWidgets('the switch is a toggle and not a button', (tester) async {
      await _open(tester, view: _neverView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        pressNode(tester, backupsAutomaticKey),
        isSemantics(
          label: 'back up automatically',
          isButton: false,
          hasToggledState: true,
          isToggled: true,
          hasCheckedState: false,
          isInMutuallyExclusiveGroup: false,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a picking row is a radio of one group and not a button', (
      tester,
    ) async {
      await _open(tester, view: _pickingView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      for (final key in [icloudKey, backupsDestinationChooseKey]) {
        expect(
          pressNode(tester, key),
          isSemantics(
            isButton: false,
            hasCheckedState: true,
            isChecked: false,
            isInMutuallyExclusiveGroup: true,
            hasToggledState: false,
            hasTapAction: true,
          ),
          reason: '$key',
        );
      }
      handle.dispose();
    });

    testWidgets('a press target is one node that names itself once', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      for (final (key, label) in [
        (backupsNowKey, _backUpNow),
        (backupsToggleKey, _turnOff),
        (_closeKey, 'close'),
        (backupsAutomaticKey, 'back up automatically'),
        (_menuKey, 'destination: Google Drive · connor@example.com'),
      ]) {
        final labelled = _semanticsAt(
          tester,
          key,
        ).where((n) => n.label.trim().isNotEmpty).toList();
        expect(labelled, hasLength(1), reason: 'one labelled node at $key');
        expect(labelled.single.label, label, reason: '$key says it once');
        // The overlay portal around the destination button keeps its own
        // anchor node (the one with a traversal parent); the button's
        // label and tap are not merged into it.
        expect(
          labelled.single.getSemanticsData().traversalParentIdentifier,
          isNull,
          reason: '$key is not the portal anchor node',
        );
      }
      await _open(tester, view: _pickingView());
      await tester.pump();
      final row = _semanticsAt(
        tester,
        icloudKey,
      ).where((n) => n.label.trim().isNotEmpty).toList();
      expect(row, hasLength(1));
      expect('Open Memex Backups'.allMatches(row.single.label), hasLength(1));
      expect(row.single.label, startsWith('iCloud Drive, '));
      handle.dispose();
    });

    testWidgets('the keep field is one text field node labelled keep', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      final nodes = _semanticsAt(
        tester,
        backupsKeepKey,
      ).where((n) => n.label.trim().isNotEmpty || n.value.trim().isNotEmpty);
      expect(nodes, hasLength(1), reason: 'label and value are one node');
      expect(
        nodes.single,
        isSemantics(isTextField: true, label: 'keep', value: '30'),
      );
      handle.dispose();
    });

    testWidgets('a disabled button reports disabled and still a button', (
      tester,
    ) async {
      await _open(tester, view: _pickingView());
      final handle = tester.ensureSemantics();
      await tester.pump();
      expect(
        pressNode(tester, _cancelKey),
        isSemantics(
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          label: 'cancel',
        ),
      );
      final turnOn = _semanticsAt(
        tester,
        _turnOnKey,
      ).firstWhere((n) => n.label.toLowerCase().contains('turn on backups'));
      expect(
        turnOn,
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
      );
      handle.dispose();
    });

    testWidgets('the status column is one live region holding its text', (
      tester,
    ) async {
      for (final (vault, view, title, other) in [
        (_local, _neverView(), _neverTitle, _backUpNow),
        (_local, _offView(), _offTitle, _turnOnEllipsis),
        (_hosted, _hostedNotConfiguredView(), _notConfiguredTitle, 'copy'),
      ]) {
        await _open(tester, vault: vault, view: view);
        final handle = tester.ensureSemantics();
        await tester.pump();
        final status = _semanticsAt(
          tester,
          backupsStatusKey,
        ).where((n) => n.label.toLowerCase().contains(title)).toList();
        expect(status, hasLength(1), reason: '${view.mode}: one status node');
        expect(status.single, isSemantics(isLiveRegion: true));
        expect(
          status.single.label.toLowerCase(),
          isNot(contains(other.toLowerCase())),
          reason: '${view.mode}: the card action is a node of its own',
        );
        // No other node in the sheet is a live region.
        final live = _semanticsAt(tester, backupsSheetKey)
            .where((n) => n.getSemanticsData().flagsCollection.isLiveRegion)
            .toList();
        expect(live, hasLength(1), reason: '${view.mode}: one live region');
        handle.dispose();
      }
    });
  });

  group('AC12 verify round 5: focus ring and hover fill', () {
    Finder rings([Key? within]) => find.descendant(
      of: within == null ? _sheet : find.byKey(within),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.position == DecorationPosition.foreground &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    );

    testWidgets('only the press target with the keyboard focus draws a ring', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      expect(rings(), findsNothing, reason: 'nothing is focused on open');

      await _tabTo(tester, backupsToggleKey);
      expect(rings(backupsToggleKey), findsOneWidget);
      expect(rings(), findsOneWidget, reason: 'one ring in the sheet');
      final ring =
          tester.widget<DecoratedBox>(rings(backupsToggleKey)).decoration
              as BoxDecoration;
      expect(ring.border, Border.all(color: OmColors.accent));

      await _tabTo(tester, backupsAutomaticKey);
      expect(rings(backupsAutomaticKey), findsOneWidget);
      expect(rings(backupsToggleKey), findsNothing, reason: 'it moved on');
      expect(rings(), findsOneWidget);

      await _tabTo(tester, _closeKey);
      expect(rings(_closeKey), findsOneWidget);
      expect(rings(backupsAutomaticKey), findsNothing);
      expect(rings(), findsOneWidget);
    });

    testWidgets('a press target loses its ring when the focus leaves it', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      await _tabTo(tester, backupsNowKey);
      expect(rings(backupsNowKey), findsOneWidget);
      // Into the keep field, which has no ring of its own.
      await _tabTo(tester, backupsKeepKey);
      expect(rings(), findsNothing);
    });

    testWidgets(
      'a self-handled target shows the click cursor only when enabled',
      (tester) async {
        // keep 1: the minus cell is disabled, the plus cell is not.
        await _open(tester, view: _neverView(_on.copyWith(keep: 1)));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: const Offset(2, 2));
        await tester.pump();
        MouseCursor cursor() =>
            RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

        await mouse.moveTo(tester.getCenter(find.byKey(_keepIncKey)));
        await tester.pump();
        expect(cursor(), SystemMouseCursors.click, reason: 'plus');

        await mouse.moveTo(tester.getCenter(find.byKey(_keepDecKey)));
        await tester.pump();
        expect(
          cursor(),
          isNot(SystemMouseCursors.click),
          reason: 'minus is disabled at 1',
        );

        await mouse.moveTo(tester.getCenter(find.byKey(_closeKey)));
        await tester.pump();
        expect(cursor(), SystemMouseCursors.click, reason: 'close');
      },
    );

    testWidgets('the icon button fills on hover and clears on leaving', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      Color? fill() {
        final f = find.descendant(
          of: find.byKey(_closeKey),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color != null,
          ),
        );
        expect(f, findsOneWidget);
        return (tester.widget<DecoratedBox>(f).decoration as BoxDecoration)
            .color;
      }

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(2, 2));
      await tester.pump();
      expect(fill(), Colors.transparent, reason: 'the pointer is elsewhere');

      await mouse.moveTo(tester.getCenter(find.byKey(_closeKey)));
      await tester.pump();
      expect(fill(), OmColors.surface3, reason: 'hovered');

      await mouse.moveTo(const Offset(2, 2));
      await tester.pump();
      expect(fill(), Colors.transparent, reason: 'left');
    });
  });

  group('AC3 AC8 AC9 verify round 5: initial state of a fresh sheet', () {
    Finder dangerText() => find.descendant(
      of: _sheet,
      matching: find.byWidgetPredicate(
        (w) => w is RichText && w.text.style?.color == OmColors.danger,
      ),
    );

    testWidgets('an off sheet starts on the off card and not on the list', (
      tester,
    ) async {
      await _open(tester, view: _offView());
      expect(_status(tester), contains(_offTitle));
      expect(find.byKey(backupsDestinationChooseKey), findsNothing);
      expect(_button(tester, backupsToggleKey).onPressed, isNotNull);
      expect(dangerText(), findsNothing);
    });

    testWidgets('a reported picking sheet starts on the list, nothing chosen', (
      tester,
    ) async {
      await _open(tester, view: _pickingView());
      expect(_status(tester), contains(_pickTitle));
      expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
      expect(_button(tester, _cancelKey).onPressed, isNotNull);
      expect(_button(tester, _turnOnKey).onPressed, isNull);
      expect(dangerText(), findsNothing);
      expect(_cardIcon(LucideIcons.triangleAlert), findsNothing);
      expect(_sheetText(tester), contains(_pickBody));

      // The choose row alone, with no folder picked, turns nothing on.
      await _open(tester, view: _pickingView(const [_chooseOption]));
      expect(_button(tester, _turnOnKey).onPressed, isNull);
    });

    testWidgets('an on sheet starts idle with the menu closed and no error', (
      tester,
    ) async {
      await _open(tester, view: _successView());
      expect(_button(tester, backupsNowKey).onPressed, isNotNull);
      expect(_sheetText(tester), contains(_req25));
      expect(_sheetText(tester), isNot(contains(_oldFolderNote)));
      expect(find.byKey(backupsDestinationChooseKey), findsNothing);
      expect(dangerText(), findsNothing);
      expect(_button(tester, backupsToggleKey).onPressed, isNotNull);
    });
  });

  group('AC3 and AC9 verify round 5: a destination failure line clears', () {
    String detail() => _unavailableDetail(_icloudDest, BackupProvider.icloud);

    /// A failed turn on of iCloud from the list.
    Future<_Wi325Sheet> failedTurnOn(WidgetTester tester) async {
      final s = await _open(tester, view: _offView(), backupFolders: false);
      s.probe.denyCreate(_icloudDest);
      await _tapKey(tester, backupsToggleKey);
      await _tapKey(tester, _discoveredKeys[0]);
      await _tapKey(tester, _turnOnKey);
      expect(_status(tester), contains(detail()));
      return s;
    }

    /// A failed menu pick of iCloud in the on state.
    Future<_Wi325Sheet> failedMenuPick(WidgetTester tester) async {
      final s = await _open(tester, view: _successView(), backupFolders: false);
      s.probe.denyCreate(_icloudDest);
      await _tapKey(tester, _menuKey);
      await _tap(tester, find.byKey(_discoveredKeys[0]));
      expect(_sheetText(tester), contains(detail()));
      return s;
    }

    testWidgets('cancel clears the failure for the next time backups show', (
      tester,
    ) async {
      final s = await failedTurnOn(tester);
      await _tapKey(tester, _cancelKey);
      expect(_status(tester), contains(_offTitle));
      // The controller then reports backups on (from elsewhere): the old
      // failure is not shown.
      s.setView(_neverView());
      await _frames(tester);
      expect(find.byKey(_menuKey), findsOneWidget, reason: 'the on state');
      expect(_sheetText(tester), isNot(contains(detail())));
    });

    testWidgets('turn on backups clears a failure left from the on state', (
      tester,
    ) async {
      final s = await failedMenuPick(tester);
      // The controller reports backups off (from elsewhere), then the user
      // presses turn on: the list opens without the old failure.
      s.setView(_offView());
      await _frames(tester);
      await _tapKey(tester, backupsToggleKey);
      expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
      expect(_sheetText(tester), isNot(contains(detail())));
      expect(_status(tester), contains(_pickBody));
      expect(_cardIcon(LucideIcons.triangleAlert), findsNothing);
    });

    testWidgets('turn off backups clears a failure left from the menu', (
      tester,
    ) async {
      final s = await failedMenuPick(tester);
      await _tapKey(tester, backupsToggleKey);
      expect(_status(tester), contains(_offTitle));
      s.setView(_neverView());
      await _frames(tester);
      expect(find.byKey(_menuKey), findsOneWidget, reason: 'the on state');
      expect(_sheetText(tester), isNot(contains(detail())));
    });

    testWidgets('a good turn on after a failed one clears the failure', (
      tester,
    ) async {
      final s = await failedTurnOn(tester);
      await _tapKey(tester, _discoveredKeys[3]);
      s.holdSaves();
      await _tapKey(tester, _turnOnKey);
      expect(
        _status(tester),
        isNot(contains(detail())),
        reason: 'gone as soon as the next turn on starts',
      );
      s.releaseSaves();
      await _frames(tester);
      expect(s.saves.single.settings.destination, _oneDriveDest);
      expect(_sheetText(tester), isNot(contains(detail())));
    });

    testWidgets('a good menu pick after a failed one clears the failure', (
      tester,
    ) async {
      final s = await failedMenuPick(tester);
      await _tapKey(tester, _menuKey);
      s.holdResolves();
      await _tap(tester, find.byKey(_discoveredKeys[3]));
      expect(
        _sheetText(tester),
        isNot(contains(detail())),
        reason: 'gone as soon as the next pick starts',
      );
    });
  });

  group('AC8 verify round 5: the keep field and the settings it mirrors', () {
    ProviderContainer container(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byKey(_launcherKey)));

    void storeKeep(WidgetTester tester, int keep) => container(tester)
        .read(_wi325SettingsStore.notifier)
        .update((m) => {...m, _local.path: _on.copyWith(keep: keep)});

    testWidgets('a stored change shows in the field while it is not focused', (
      tester,
    ) async {
      await _open(tester, view: _neverView());
      expect(_keepText(tester), '30');
      storeKeep(tester, 40);
      await _frames(tester);
      expect(_keepText(tester), '40');
    });

    testWidgets('a stored change does not overwrite what is being typed', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      await _tabTo(tester, backupsKeepKey);
      tester.testTextInput.enterText('12');
      await tester.pump();
      storeKeep(tester, 40);
      await _frames(tester);
      expect(_keepText(tester), '12', reason: 'still being typed');
      expect(s.saves, isEmpty, reason: 'nothing saved before the blur');
    });

    testWidgets('leaving the field saves what was typed', (tester) async {
      final s = await _open(tester, view: _neverView());
      await _tabTo(tester, backupsKeepKey);
      expect(s.saves, isEmpty, reason: 'focusing saves nothing');
      tester.testTextInput.enterText('12');
      await tester.pump();
      expect(s.saves, isEmpty, reason: 'typing saves nothing');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _frames(tester);
      expect(s.saves.single.settings, _on.copyWith(keep: 12));
      expect(_keepText(tester), '12');
    });

    testWidgets(
      'focusing the field saves nothing even when the text is ahead',
      (tester) async {
        // A failed step leaves the field showing 31 over a stored 30.
        final s = await _open(tester, view: _neverView());
        s.saveError = Exception('disk full');
        await _tapKey(tester, _keepIncKey);
        expect(s.saves, hasLength(1), reason: 'the step tried to save');
        expect(tester.takeException(), isNotNull, reason: 'the failure shows');
        expect(_keepText(tester), '31');
        await _tabTo(tester, backupsKeepKey);
        expect(s.saves, hasLength(1), reason: 'only losing focus commits');
      },
    );

    testWidgets('leaving the field on text that is not a number restores it', (
      tester,
    ) async {
      final s = await _open(tester, view: _neverView());
      await _tabTo(tester, backupsKeepKey);
      tester.testTextInput.enterText('abc');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _frames(tester);
      expect(s.saves, isEmpty);
      expect(_keepText(tester), '30');
    });
  });

  group('AC13 verify round 5: a short window scrolls the sheet body', () {
    testWidgets('the body scrolls so the last row can be reached', (
      tester,
    ) async {
      const window = Size(900, 420);
      for (final view in [_neverView(), _pickingView()]) {
        final lastKey = view.mode == BackupSheetMode.pickingDestination
            ? _turnOnKey
            : backupsToggleKey;
        await _open(tester, view: view, size: window);
        expect(tester.takeException(), isNull, reason: '${view.mode}');
        final scroll = find.descendant(
          of: _sheet,
          matching: find.byType(SingleChildScrollView),
        );
        expect(scroll, findsOneWidget, reason: '${view.mode}: it scrolls');
        expect(
          tester.getRect(_sheet).height,
          lessThanOrEqualTo(window.height),
          reason: '${view.mode}: the panel fits the window',
        );
        expect(
          tester.getRect(find.byKey(lastKey)).bottom,
          greaterThan(window.height),
          reason: '${view.mode}: the last row starts below the window',
        );
        await tester.drag(scroll, const Offset(0, -2000));
        await _frames(tester);
        expect(
          tester.getRect(find.byKey(lastKey)).bottom,
          lessThanOrEqualTo(window.height),
          reason: '${view.mode}: scrolled to the last row',
        );
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('AC9 verify round 5: Escape reaches the opened menu', () {
    testWidgets(
      'Escape right after a click on the destination closes the menu and keeps the sheet',
      (tester) async {
        await _open(tester, view: _successView());
        await _tapKey(tester, _menuKey);
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(find.byKey(backupsDestinationChooseKey), findsNothing);
        expect(_sheet, findsOneWidget, reason: 'the first Escape keeps it');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(_sheet, findsNothing, reason: 'the second Escape closes it');
      },
    );
  });
}
