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
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
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

BackupStatus _hostedStatus({bool inProgress = false}) => BackupStatus(
  lastAttemptAt: _hostedCreated,
  lastSuccessAt: _hostedCreated,
  lastResult: 'created',
  lastFile: _hostedFile,
  lastFileCreatedAt: _hostedCreated,
  lastBytes: _hostedBytes,
  enabled: true,
  keep: 30,
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

  FakeBackupController get controller => harness.controller!;
  FakeCloudFolderProbe get probe => harness.probe;

  void setView(BackupViewState view) => controller.setViewState(vault, view);
}

/// Installs every provider folder (with its `Open Memex Backups` already
/// there, so a pick resolves to the option's own path) and the chosen
/// folders.
void _seedProviders(FakeCloudFolderProbe probe) {
  probe
    ..seedIcloud()
    ..seedGoogleDrive('connor@example.com')
    ..seedGoogleDrive('work@example.com')
    ..seedOneDrive('Personal');
  for (final d in [_icloudDest, _googleDest, _google2Dest, _oneDriveDest]) {
    probe.addDirectory(d);
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

  final probe = FakeCloudFolderProbe();
  if (providers) _seedProviders(probe);
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
/// ellipses (the destination menu label, the hosted command row) are exempt.
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
    if (exempt.contains(p) || text.startsWith('memex serve')) continue;
    expect(p.didExceedMaxLines, isFalse, reason: '$state: "$text" is cut');
    expect(
      p.size.height + 0.5,
      greaterThanOrEqualTo(p.getMinIntrinsicHeight(p.size.width)),
      reason: '$state: "$text" is laid out shorter than its lines',
    );
  }
}

/// Per-provider index of each provider option, as the Keys count them.
List<(BackupDestinationOption, Key)> _keyed(
  List<BackupDestinationOption> options,
) {
  final seen = <BackupProvider, int>{};
  return [
    for (final o in options)
      if (o.provider case final p?)
        (o, backupDestinationKey(p, seen[p] = (seen[p] ?? -1) + 1)),
  ];
}

void _expectZeroRuns(_Wi325Sheet s) {
  expect(s.harness.cli.calls, isEmpty, reason: 'no memex CLI call');
  expect(s.harness.runner.calls, isEmpty, reason: 'no backup run');
  expect(s.controller.backUpNowCalls, isEmpty, reason: 'no backUpNow');
}

void main() {
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
        final s = await _open(tester, view: _offView());
        final expected = await discoverBackupDestinations(s.probe);
        await _tapKey(tester, backupsToggleKey);

        expect(_status(tester), contains(_pickTitle));
        expect(_status(tester), contains(_pickBody));
        final keyed = _keyed(expected);
        var lastTop = double.negativeInfinity;
        for (final (option, key) in keyed) {
          final row = find.byKey(key);
          expect(row, findsOneWidget, reason: '${option.label} as $key');
          expect(_textIn(tester, row), contains(option.label));
          final top = tester.getRect(row).top;
          expect(top, greaterThan(lastTop), reason: '${option.label} in order');
          lastTop = top;
        }
        final choose = find.byKey(backupsDestinationChooseKey);
        expect(choose, findsOneWidget);
        expect(tester.getRect(choose).top, greaterThan(lastTop));
        expect(
          _textIn(tester, choose),
          contains('a nas share, an external disk or any folder'),
        );
        if (keyed.isNotEmpty) {
          expect(_sheetText(tester), contains('found on this mac'));
          expect(_sheetText(tester), contains(_pickNote));
          expect(_sheetText(tester), isNot(contains(_noProviderSub)));
        }
        _expectZeroRuns(s);
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
        final s = await _open(tester, view: _offView());
        final expected = _keyed(await discoverBackupDestinations(s.probe));
        await _tapKey(tester, backupsToggleKey);
        if (expected.isEmpty) {
          // Stub discovery: choose folder is the only row.
          s.picker.directories.add(_chosenDest);
          await _tapKey(tester, backupsDestinationChooseKey);
        } else {
          await _tapKey(tester, expected.first.$2);
        }
        await _tapKey(tester, _turnOnKey);
        expect(s.saves, hasLength(1));
        expect(s.saves.single.settings.enabled, isTrue);
        expect(
          s.saves.single.settings.destination,
          expected.isEmpty ? _chosenDest : expected.first.$1.path,
        );
        _expectZeroRuns(s);
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
        for (final (dest, shown) in [
          (_icloudDest, 'iCloud Drive/Open Memex Backups'),
          (_googleDest, 'My Drive/Open Memex Backups'),
          (_oneDriveDest, 'OneDrive-Personal/Open Memex Backups'),
          (_chosenDest, _chosenDest),
        ]) {
          await _open(
            tester,
            view: _neverView(_on.copyWith(destination: dest)),
          );
          expect(_sheetText(tester), contains(shown), reason: dest);
          expect(_text('destination'), findsOneWidget, reason: dest);
        }
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
        final s = await _open(tester, view: _successView());
        final keyed = _keyed(await discoverBackupDestinations(s.probe));
        await _tapKey(tester, _menuKey);
        expect(find.byKey(backupsDestinationChooseKey), findsOneWidget);
        for (final (option, key) in keyed) {
          expect(find.byKey(key), findsOneWidget, reason: option.label);
        }
        final others = [
          for (final (o, k) in keyed)
            if (o.path != _googleDest) (o, k),
        ];
        for (final (option, key) in others) {
          if (find.byKey(_menuKey).evaluate().isNotEmpty &&
              find.byKey(key).evaluate().isEmpty) {
            await _tapKey(tester, _menuKey);
          }
          await _tap(tester, find.byKey(key));
          expect(s.saves.last.settings.destination, option.path);
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
        await _tapKey(tester, _menuKey);
        expect(_sheetText(tester), contains(_oldFolderNote));
        expect(_sheetText(tester), isNot(contains(_req25)));
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
}
