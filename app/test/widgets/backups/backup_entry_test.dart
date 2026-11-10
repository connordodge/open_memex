// WI #326 (A5, D23, D24): the sidebar "backups" row and the automatic-failure
// warning (Spec #315 reqs 24, 31a, 37; ledger L6, L9; design pack
// design/315-vault-backups/packs/326.md, boards B1 and B4 item 3; lead
// rulings in the WI body: local ok shows the age, hosted ok the server's last
// backup as a local clock time, never backed up "never"; the warning badge is
// the 12x12 amber triangle-alert inside IgnorePointer; every time is local).
//
// The row only shows the controller's view state (`backupControllerProvider`).
// Most tests drive it with the A0 `FakeBackupController`; the warning tests
// that must hold end to end run A3's live controller over the A0 fakes
// (runner, state reader, hosted API) and a FakeClock, so a real automatic
// failure raises the warning and a real later success clears it.
//
// Copy owned by A1 (`backup_messages.dart`: the failure `short` tails) is the
// real function's output; the semantic labels are pack 326's verbatim.
//
// flutter_test draws every font as Ahem (one em per glyph), which is wider
// than the app's fonts: the geometry pin uses the short "off" row.
import 'dart:convert';

import 'package:flutter/gestures.dart';
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
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/backups/backup_entry.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';

import '../../support/backup_fakes.dart';
import '../../support/backup_harness.dart';
import '../../support/fake_clock.dart';
import '../../support/font_fetch_hold.dart';

// ------------------------------------------------------------------ fixtures

const _vaultPath = '/Users/tester/vaults/memex';
const _local = LocalVaultRef(_vaultPath);
const _otherPath = '/Users/tester/vaults/journal';
const _other = LocalVaultRef(_otherPath);
const _hosted = HostedVaultRef('srv-nas', 'work');

const _googleDest =
    '/Users/tester/Library/CloudStorage/GoogleDrive-connor@example.com/'
    'My Drive/Open Memex Backups';
const _on = VaultBackupSettings(enabled: true, destination: _googleDest);
const _file = 'memex-20261109T140312Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip';
const _hostedFile =
    'work-20261109T030004Z-01JB2K7M4N6P8Q0R2S4T6V8W0X.memex.zip';

/// The widget tests' clock: 9 Nov 2026, 16:03 local.
final _now = DateTime(2026, 11, 9, 16, 3);

/// Today 14:03 local: two hours before [_now].
final _lastBackup = DateTime(2026, 11, 9, 14, 3);

/// Today 09:00 local.
final _failedAt = DateTime(2026, 11, 9, 9);

/// Today 03:00 local (the server's nightly run).
final _hostedAt = DateTime(2026, 11, 9, 3);

const _editorKey = Key('wi326-editor-field');

/// The `warnLine` token of packs 325/326 (as backups_sheet_widgets.dart).
final _warnLine = OmColors.warn.withAlpha(77);

BackupStatus _created(DateTime at, {DateTime? fileAt}) => BackupStatus(
  lastAttemptAt: at.toUtc(),
  lastSuccessAt: at.toUtc(),
  lastResult: 'created',
  lastFile: _file,
  lastFileCreatedAt: (fileAt ?? at).toUtc(),
  lastBytes: 41200000,
);

BackupStatus _failedStatus(DateTime at, String code) => BackupStatus(
  lastAttemptAt: at.toUtc(),
  lastSuccessAt: at.subtract(const Duration(days: 1)).toUtc(),
  lastResult: code,
  lastError: 'the folder is gone',
  lastFile: _file,
  lastFileCreatedAt: at.subtract(const Duration(days: 1)).toUtc(),
  lastBytes: 41200000,
);

BackupStatus _hostedOk(DateTime at, {bool inProgress = false}) => BackupStatus(
  enabled: true,
  keep: 30,
  inProgress: inProgress,
  lastAttemptAt: at.toUtc(),
  lastSuccessAt: at.toUtc(),
  lastResult: 'created',
  lastFile: _hostedFile,
  lastFileCreatedAt: at.toUtc(),
  lastBytes: 18600000,
);

BackupStatus _hostedFailed(DateTime at) => BackupStatus(
  enabled: true,
  keep: 30,
  lastAttemptAt: at.toUtc(),
  lastSuccessAt: at.subtract(const Duration(days: 1)).toUtc(),
  lastResult: 'backup_destination_unavailable',
  lastError: 'no such folder',
  lastFile: _hostedFile,
  lastFileCreatedAt: at.subtract(const Duration(days: 1)).toUtc(),
  lastBytes: 18600000,
);

BackupViewState _offView() => const BackupViewState(
  mode: BackupSheetMode.off,
  settings: VaultBackupSettings(),
);

BackupViewState _neverView() =>
    const BackupViewState(mode: BackupSheetMode.neverBackedUp, settings: _on);

BackupViewState _successView({DateTime? at, DateTime? fileAt}) =>
    BackupViewState(
      mode: BackupSheetMode.success,
      settings: _on,
      status: _created(at ?? _lastBackup, fileAt: fileAt),
    );

BackupViewState _backingUpView() => BackupViewState(
  mode: BackupSheetMode.backingUp,
  settings: _on,
  status: _created(_lastBackup),
  startedAt: _now.toUtc(),
);

BackupViewState _localFailedView({
  DateTime? at,
  bool automatic = true,
  String code = 'backup_destination_unavailable',
}) {
  final failedAt = at ?? _failedAt;
  return BackupViewState(
    mode: BackupSheetMode.error,
    settings: _on,
    status: _failedStatus(failedAt, code),
    errorCode: code,
    automatic: automatic,
    failedAt: failedAt.toUtc(),
    message: backupFailureMessage(
      code: code,
      message: 'the folder is gone',
      automatic: automatic,
      failedAt: failedAt.toUtc(),
      now: _now,
      destination: _googleDest,
      provider: BackupProvider.googleDrive,
    ),
    warning: true,
  );
}

/// What the live controller shows while a run is under way with the warning
/// on: the warning flag and the state file's status, but none of the
/// failure's own fields (no failedAt, automatic or message).
BackupViewState _retryingView() => BackupViewState(
  mode: BackupSheetMode.backingUp,
  settings: _on,
  status: _failedStatus(_failedAt, 'backup_destination_unavailable'),
  startedAt: _now.toUtc(),
  warning: true,
);

/// A "Back up now" press that found a backup already running (Spec req 22:
/// not a failure), while the warning from an earlier automatic failure holds.
BackupViewState _busyPressView({DateTime? at}) {
  final pressed = at ?? _now;
  return BackupViewState(
    mode: BackupSheetMode.error,
    settings: _on,
    status: _failedStatus(_failedAt, 'backup_destination_unavailable'),
    errorCode: 'backup_in_progress',
    automatic: false,
    failedAt: pressed.toUtc(),
    message: backupFailureMessage(
      code: 'backup_in_progress',
      message: 'a backup is already running',
      automatic: false,
      failedAt: pressed.toUtc(),
      now: _now,
      destination: _googleDest,
      provider: BackupProvider.googleDrive,
    ),
    warning: true,
  );
}

/// A retry under way with the warning flag on and no failure to state: the
/// state file's last attempt succeeded.
BackupViewState _noTimeWarningView() => BackupViewState(
  mode: BackupSheetMode.backingUp,
  settings: _on,
  status: _created(_lastBackup),
  startedAt: _now.toUtc(),
  warning: true,
);

/// An automatic run that exit 2 answered (unrecorded, kept in memory, D23).
BackupViewState _tooOldWarningView() => BackupViewState(
  mode: BackupSheetMode.memexTooOld,
  settings: _on,
  status: _created(_lastBackup.subtract(const Duration(days: 1))),
  message: backupTooOldMessage(),
  automatic: true,
  failedAt: _failedAt.toUtc(),
  warning: true,
);

BackupViewState _hostedSuccessView() => BackupViewState(
  mode: BackupSheetMode.success,
  hosted: true,
  status: _hostedOk(_hostedAt),
);

BackupViewState _hostedFailedView() => BackupViewState(
  mode: BackupSheetMode.error,
  hosted: true,
  status: _hostedFailed(_hostedAt),
  errorCode: 'backup_destination_unavailable',
  automatic: true,
  failedAt: _hostedAt.toUtc(),
  message: backupFailureMessage(
    code: 'backup_destination_unavailable',
    message: 'no such folder',
    automatic: true,
    failedAt: _hostedAt.toUtc(),
    now: _now,
    serverName: 'nas',
  ),
  warning: true,
);

BackupViewState _hostedNotConfiguredView() => const BackupViewState(
  mode: BackupSheetMode.hostedNotConfigured,
  hosted: true,
  status: BackupStatus(enabled: false),
);

BackupViewState _hostedTooOldView() => const BackupViewState(
  mode: BackupSheetMode.hostedServerTooOld,
  hosted: true,
);

BackupViewState _hostedBackingUpView() => BackupViewState(
  mode: BackupSheetMode.backingUp,
  hosted: true,
  status: _hostedOk(_hostedAt, inProgress: true),
  startedAt: _now.toUtc(),
);

/// The server can't be reached: the last value read stays, no warning.
BackupViewState _hostedUnreachableView() => BackupViewState(
  mode: BackupSheetMode.hostedUnreachable,
  hosted: true,
  status: _hostedOk(_hostedAt),
);

// ------------------------------------------------------------------- the rig

class _Wi326Rig {
  _Wi326Rig(this.harness);

  final BackupHarness harness;

  FakeBackupController get controller => harness.controller!;
  FakeClock get clock => harness.clock;
  ProviderContainer get container => harness.container;
}

/// Pumps the entry the way the sidebar holds it: in a 268-wide column (the
/// sidebar's fixed width, also its narrowest), under a ProviderScope with
/// every backup seam faked. [view] is the FakeBackupController's state for
/// [vault]; [live] runs A3's controller over the fakes instead. A saved
/// server `srv-nas` is named "nas". [withEditor] puts a text field above the
/// entry (an editor field).
Future<_Wi326Rig> _pump(
  WidgetTester tester, {
  VaultRef? vault = _local,
  BackupViewState? view,
  bool live = false,
  FakeClock? clock,
  FakeBackupRunner? runner,
  FakeBackupStateReader? reader,
  FakeHostedBackupApi? hostedApi,
  Map<String, VaultBackupSettings> settings = const {},
  double textScale = 1.0,
  bool withEditor = false,
}) async {
  final harness = await createBackupContainer(
    clock: clock ?? FakeClock(_now),
    runner: runner,
    reader: reader,
    hostedApi: hostedApi,
    controller: live ? null : FakeBackupController(),
    realController: live,
    vault: vault,
    prefs: {
      'memex.vault_servers': [
        jsonEncode({
          'id': 'srv-nas',
          'name': 'nas',
          'url': 'http://nas.local:9000',
        }),
      ],
      if (settings.isNotEmpty)
        'memex.vault_backups': jsonEncode({
          for (final e in settings.entries) e.key: e.value.toJson(),
        }),
    },
  );
  if (!live && view != null && vault != null) {
    harness.controller!.setViewState(vault, view);
  }
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        // A fresh app (and navigator) per pump, so no sheet carries over.
        key: ObjectKey(harness.container),
        theme: buildOmTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 268,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (withEditor)
                    const TextField(
                      key: _editorKey,
                      decoration: InputDecoration(hintText: 'type here'),
                    ),
                  const BackupEntry(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _frames(tester);
  return _Wi326Rig(harness);
}

/// A few frames (never pumpAndSettle: the backing-up spinner repeats).
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

/// Lets the live controller's async chain (state read, run, re-read) land.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
  await _frames(tester);
}

// ------------------------------------------------------------------ finders

final _entry = find.byKey(backupsEntryKey);
final _badge = find.byKey(backupsEntryWarningKey);
final _sheet = find.byKey(backupsSheetKey);

/// The RichText inside the entry whose whole plain text is [s].
Finder _rowText(String s) => find.descendant(
  of: _entry,
  matching: find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText() == s,
  ),
);

/// All the entry's text, one paragraph per line.
String _entryText(WidgetTester tester) => tester
    .widgetList<RichText>(
      find.descendant(of: _entry, matching: find.byType(RichText)),
    )
    .map((w) => w.text.toPlainText())
    .join('\n');

/// The strings of the entry's Text widgets (label, then status), in order;
/// the icon's glyph is not one.
List<String?> _shownTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(of: _entry, matching: find.byType(Text)))
    .map((w) => w.data)
    .toList();

Color? _textColor(WidgetTester tester, String s) {
  final f = _rowText(s);
  expect(f, findsOneWidget, reason: '"$s" in the row');
  return tester.widget<RichText>(f).text.style?.color;
}

/// The Icon in the entry (the badge's icon while a warning shows).
Icon _icon(WidgetTester tester) {
  final f = find.descendant(of: _entry, matching: find.byType(Icon));
  expect(f, findsOneWidget, reason: 'one icon in the row');
  return tester.widget<Icon>(f);
}

/// The `backups-entry` box's global rect; fails by assertion when the row
/// is missing.
Rect _entryRect(WidgetTester tester) {
  expect(_entry, findsOneWidget, reason: 'backups-entry shows');
  return tester.getRect(_entry);
}

/// The bordered box `backups-entry` wraps: the DecoratedBox under the Key
/// with a border that fills the Key's rect.
BoxDecoration _box(WidgetTester tester) {
  final rect = _entryRect(tester);
  for (final e
      in find
          .descendant(
            of: _entry,
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is! BoxDecoration || d.border == null) continue;
    final r = _globalRect(e);
    if ((r.width - rect.width).abs() <= 0.5 &&
        (r.height - rect.height).abs() <= 0.5) {
      return d;
    }
  }
  fail('no bordered box fills backups-entry');
}

/// [e]'s render box in global coordinates.
Rect _globalRect(Element e) {
  final box = e.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

Color _borderColor(BoxDecoration d) => (d.border! as Border).top.color;

bool _noFill(BoxDecoration d) => d.color == null || d.color!.a == 0;

/// The semantics nodes that lie inside the entry's box (global rects, 2 px
/// slack). Needs `tester.ensureSemantics()`.
List<SemanticsNode> _semanticsInEntry(WidgetTester tester) {
  final box = _entryRect(tester).inflate(2);
  var root = tester.getSemantics(find.byType(Scaffold));
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

/// The node in the entry whose label contains [label] in full.
SemanticsNode _labelled(WidgetTester tester, String label) {
  final nodes = _semanticsInEntry(
    tester,
  ).where((n) => n.label.contains(label)).toList();
  expect(
    nodes,
    isNotEmpty,
    reason:
        'a semantics label "$label" in backups-entry; found '
        '${_semanticsInEntry(tester).map((n) => '"${n.label}"').toList()}',
  );
  return nodes.first;
}

/// Tabs until the focused node is the entry's box (same place, similar size).
Future<void> _tabToEntry(WidgetTester tester) async {
  final target = _entryRect(tester);
  for (var i = 0; i < 20; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (_entryFocused(tester, target)) return;
  }
  fail('Tab never reached backups-entry');
}

bool _entryFocused(WidgetTester tester, [Rect? target]) {
  final rect = target ?? _entryRect(tester);
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || focus.context == null) return false;
  final r = focus.rect;
  final a = r.width * r.height;
  final b = rect.width * rect.height;
  return r.overlaps(rect) && a <= 4 * b && b <= 4 * a;
}

/// The sheet opened exactly once, on [vault].
void _expectSheetOnce(_Wi326Rig s, VaultRef vault, String how) {
  expect(_sheet, findsOneWidget, reason: '$how opens the sheet');
  expect(s.controller.openSheetCalls, [vault], reason: '$how: once');
}

/// No paragraph in the entry is cut: none exceeds its max lines, none is laid
/// out shorter than its text needs, and each lies inside the entry's box.
void _expectNothingClipped(WidgetTester tester, String state) {
  expect(tester.takeException(), isNull, reason: '$state: no overflow');
  final box = _entryRect(tester).inflate(0.5);
  final paragraphs = find
      .descendant(of: _entry, matching: find.byType(RichText))
      .evaluate()
      .toList();
  expect(paragraphs, isNotEmpty, reason: '$state: the row has text');
  for (final e in paragraphs) {
    final p = e.renderObject! as RenderParagraph;
    final text = p.text.toPlainText();
    if (text.trim().isEmpty || text.codeUnits.every((c) => c > 0xE000)) {
      continue; // an icon glyph
    }
    expect(p.didExceedMaxLines, isFalse, reason: '$state: "$text" is cut');
    expect(
      p.size.height + 0.5,
      greaterThanOrEqualTo(p.getMinIntrinsicHeight(p.size.width)),
      reason: '$state: "$text" is laid out shorter than its lines',
    );
    expect(
      p.size.width + 0.5,
      greaterThanOrEqualTo(p.getMinIntrinsicWidth(double.infinity)),
      reason: '$state: "$text" is narrower than its longest word',
    );
    final r = _globalRect(e);
    expect(
      box.contains(r.topLeft) && box.contains(r.bottomRight),
      isTrue,
      reason: '$state: "$text" ($r) lies inside the row ($box)',
    );
  }
}

String _settingsJson(Map<String, VaultBackupSettings> m) =>
    jsonEncode({for (final e in m.entries) e.key: e.value.toJson()});

void main() {
  holdFontFetches();

  // ================================================================ AC 1
  group('AC1 the row reads each state', () {
    testWidgets(
      'the row reads off never the last backup age and backing up for a local vault',
      (tester) async {
        final cases = <(String, BackupViewState, String, String)>[
          ('off', _offView(), 'backups', 'off'),
          ('never backed up', _neverView(), 'backups', 'never'),
          ('last backup 2 h ago', _successView(), 'backups', '2 h ago'),
          ('backing up', _backingUpView(), 'backups', 'backing up…'),
        ];
        for (final (state, view, label, status) in cases) {
          await _pump(tester, view: view);
          expect(_entry, findsOneWidget, reason: '$state: the row shows');
          expect(_rowText(label), findsOneWidget, reason: '$state: "$label"');
          expect(
            _rowText(status),
            findsOneWidget,
            reason: '$state: "$status" in ${_entryText(tester)}',
          );
          expect(_badge, findsNothing, reason: '$state: no warning badge');
        }
      },
    );

    testWidgets(
      'the last backup age counts from the clock provider in minutes hours and days',
      (tester) async {
        // A clock far from wall time: an age read from DateTime.now() fails.
        final now = DateTime(2031, 3, 14, 15);
        final cases = <(String, Duration, String)>[
          ('written now', Duration.zero, 'just now'),
          ('five minutes ago', const Duration(minutes: 5), '5 min ago'),
          ('two hours ago', const Duration(hours: 2), '2 h ago'),
          ('three days ago', const Duration(days: 3), '3 d ago'),
          // The clock went backwards: never a negative age.
          ('a file time after now', const Duration(minutes: -5), 'just now'),
        ];
        for (final (why, ago, expected) in cases) {
          final at = now.subtract(ago);
          await _pump(
            tester,
            clock: FakeClock(now),
            view: _successView(at: at),
          );
          expect(
            _rowText(expected),
            findsOneWidget,
            reason: '$why: "$expected" in ${_entryText(tester)}',
          );
          expect(_entryText(tester), isNot(contains('-')), reason: why);
        }
      },
    );

    testWidgets(
      'the age is the last backup file time not the last unchanged check',
      (tester) async {
        // Req 19: "the last backup" is when its file was written. An
        // unchanged check 10 min ago wrote no file; the file is 2 h old.
        await _pump(
          tester,
          view: _successView(
            at: _now.subtract(const Duration(minutes: 10)),
            fileAt: _lastBackup,
          ),
        );
        expect(_rowText('2 h ago'), findsOneWidget, reason: _entryText(tester));
        expect(_rowText('10 min ago'), findsNothing);
      },
    );

    testWidgets('a hosted row reads backups on the server and its states', (
      tester,
    ) async {
      final cases = <(String, BackupViewState, String)>[
        ('hosted ok', _hostedSuccessView(), '03:00'),
        ('hosted backing up', _hostedBackingUpView(), 'backing up…'),
        ('hosted not configured', _hostedNotConfiguredView(), 'set on nas'),
        ('hosted server too old', _hostedTooOldView(), 'not on nas yet'),
        (
          'hosted unreachable keeps the last value',
          _hostedUnreachableView(),
          '03:00',
        ),
      ];
      for (final (state, view, status) in cases) {
        await _pump(tester, vault: _hosted, view: view);
        expect(
          _rowText('backups on nas'),
          findsOneWidget,
          reason: '$state: "backups on nas" in ${_entryText(tester)}',
        );
        expect(
          _rowText(status),
          findsOneWidget,
          reason: '$state: "$status" in ${_entryText(tester)}',
        );
        expect(_badge, findsNothing, reason: '$state: no warning badge');
      }
    });

    testWidgets('each state shows its icon and colours from the design', (
      tester,
    ) async {
      final cases =
          <
            (
              String,
              VaultRef,
              BackupViewState,
              IconData,
              Color,
              String,
              Color,
              String,
              Color,
            )
          >[
            (
              'off',
              _local,
              _offView(),
              LucideIcons.archive,
              OmColors.fg2,
              'backups',
              OmColors.fg1,
              'off',
              OmColors.fg2,
            ),
            (
              'never',
              _local,
              _neverView(),
              LucideIcons.archive,
              OmColors.fg2,
              'backups',
              OmColors.fg1,
              'never',
              OmColors.fg2,
            ),
            (
              'last backup',
              _local,
              _successView(),
              LucideIcons.check,
              OmColors.accent,
              'backups',
              OmColors.fg1,
              '2 h ago',
              OmColors.fg2,
            ),
            (
              'backing up',
              _local,
              _backingUpView(),
              LucideIcons.loaderCircle,
              OmColors.info,
              'backups',
              OmColors.fg1,
              'backing up…',
              OmColors.fg2,
            ),
            (
              'hosted ok',
              _hosted,
              _hostedSuccessView(),
              LucideIcons.check,
              OmColors.accent,
              'backups on nas',
              OmColors.fg1,
              '03:00',
              OmColors.fg2,
            ),
            (
              'hosted not configured',
              _hosted,
              _hostedNotConfiguredView(),
              LucideIcons.archive,
              OmColors.fg2,
              'backups on nas',
              OmColors.fg1,
              'set on nas',
              OmColors.fg2,
            ),
          ];
      for (final (
            state,
            vault,
            view,
            icon,
            iconColor,
            label,
            labelColor,
            status,
            statusColor,
          )
          in cases) {
        await _pump(tester, vault: vault, view: view);
        final i = _icon(tester);
        expect(i.icon, icon, reason: '$state icon');
        expect(i.color, iconColor, reason: '$state icon colour');
        expect(i.size, 12, reason: '$state icon size');
        expect(_textColor(tester, label), labelColor, reason: '$state label');
        expect(
          _textColor(tester, status),
          statusColor,
          reason: '$state status',
        );
        final box = _box(tester);
        expect(_noFill(box), isTrue, reason: '$state: no fill');
        expect(_borderColor(box), OmColors.line1, reason: '$state border');
        expect(box.borderRadius, BorderRadius.circular(6), reason: state);
      }
    });

    testWidgets(
      'only backing up spins and the spinner stops when the backup ends',
      (tester) async {
        final s = await _pump(tester, view: _backingUpView());
        expect(_icon(tester).icon, LucideIcons.loaderCircle);
        expect(tester.hasRunningAnimations, isTrue, reason: 'the spinner');

        s.controller.setViewState(_local, _successView(at: _now));
        await _frames(tester);
        expect(
          _rowText('just now'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(tester.hasRunningAnimations, isFalse, reason: 'it stopped');
      },
    );

    testWidgets(
      'the row follows the open vault and shows nothing with no vault open',
      (tester) async {
        final s = await _pump(tester, view: _offView());
        s.controller.setViewState(_other, _successView());
        expect(_rowText('off'), findsOneWidget, reason: 'memex is open');

        s.container.read(currentVaultProvider.notifier).state = _other;
        await _frames(tester);
        expect(
          _rowText('2 h ago'),
          findsOneWidget,
          reason: 'journal is open now: ${_entryText(tester)}',
        );
        expect(_rowText('off'), findsNothing);

        s.container.read(currentVaultProvider.notifier).state = null;
        await _frames(tester);
        expect(_entry, findsNothing, reason: 'no vault, no row (B1 item 9)');
      },
    );

    testWidgets(
      'the row reads the controller only and runs no backup read or CLI call itself',
      (tester) async {
        final s = await _pump(tester, view: _localFailedView());
        expect(_badge, findsOneWidget);
        // Its only timer redraws the shown time at local midnight (finding 1
        // of review r1); it reads and runs nothing when it fires.
        expect(s.clock.pendingTimers, 1, reason: 'the one redraw timer');
        s.clock.advance(const Duration(hours: 3));
        await _frames(tester);
        expect(_rowText('09:00'), findsOneWidget, reason: 'not midnight yet');
        expect(s.harness.runner.calls, isEmpty, reason: 'no backup run');
        expect(s.harness.reader.reads, isEmpty, reason: 'no state read');
        expect(s.harness.hostedApi.calls, isEmpty, reason: 'no hosted call');
        expect(s.harness.cli.calls, isEmpty, reason: 'no CLI call');
        expect(s.controller.backUpNowCalls, isEmpty);
        expect(s.controller.openSheetCalls, isEmpty);
      },
    );

    testWidgets(
      'the entry box is 244 by 28 inside the 268 wide sidebar with 12 px margins',
      (tester) async {
        await _pump(tester, view: _offView());
        final r = _entryRect(tester);
        expect(r.width, moreOrLessEquals(244, epsilon: 0.5));
        expect(r.height, moreOrLessEquals(28, epsilon: 0.5));
        expect(r.left, moreOrLessEquals(12, epsilon: 0.5));
        // The status text is pushed to the right edge (padding 10, border 1).
        final status = tester.getRect(_rowText('off'));
        expect(status.right, moreOrLessEquals(r.right - 11, epsilon: 1));
        // 10 px below the row before the hairline.
        final column = tester.getRect(find.byType(BackupEntry));
        expect(column.bottom - r.bottom, moreOrLessEquals(10, epsilon: 0.5));
      },
    );
  });

  // ================================================================ AC 2
  group('AC2 a press opens the sheet once', () {
    testWidgets(
      'a click anywhere in backups-entry including its padding opens the sheet exactly once',
      (tester) async {
        final points = <(String, Offset Function(Rect))>[
          ('centre', (r) => r.center),
          ('top left padding', (r) => r.topLeft + const Offset(2, 2)),
          ('bottom right padding', (r) => r.bottomRight - const Offset(2, 2)),
          ('left padding', (r) => Offset(r.left + 4, r.center.dy)),
        ];
        for (final (where, at) in points) {
          final s = await _pump(tester, view: _successView());
          await tester.tapAt(at(_entryRect(tester)));
          await _frames(tester);
          _expectSheetOnce(s, _local, 'a click at the $where');
          await _frames(tester);
          expect(s.controller.openSheetCalls, hasLength(1), reason: where);
        }
      },
    );

    testWidgets(
      'a click on the badge area opens the sheet and the badge takes no press',
      (tester) async {
        final s = await _pump(tester, view: _localFailedView());
        expect(_badge, findsOneWidget);
        expect(_badge, findsOneWidget);
        final centre = tester.getCenter(_badge);
        expect(_entryRect(tester).contains(centre), isTrue);

        // Nothing in the badge's subtree is hit: the press goes to the entry.
        final hit = tester.hitTestOnBinding(centre);
        final targets = hit.path.map((e) => e.target).toSet();
        final badgeRenders = find
            .descendant(
              of: _badge,
              matching: find.byWidgetPredicate((_) => true),
              matchRoot: true,
            )
            .evaluate()
            .map((e) => e.renderObject)
            .whereType<RenderObject>()
            .toSet();
        expect(badgeRenders, isNotEmpty);
        expect(
          targets.intersection(badgeRenders),
          isEmpty,
          reason: 'the badge itself takes no presses',
        );

        await tester.tapAt(centre);
        await _frames(tester);
        _expectSheetOnce(s, _local, 'a click on the badge');
      },
    );

    testWidgets(
      'Enter and Space with focus on backups-entry open the sheet exactly once',
      (tester) async {
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
        ]) {
          final s = await _pump(tester, view: _offView());
          await _tabToEntry(tester);
          expect(s.controller.openSheetCalls, isEmpty, reason: 'Tab only');
          await tester.sendKeyEvent(key);
          await _frames(tester);
          _expectSheetOnce(s, _local, '${key.keyLabel} with focus');
        }
      },
    );

    testWidgets('other keys with focus on backups-entry open nothing', (
      tester,
    ) async {
      final s = await _pump(tester, view: _offView());
      await _tabToEntry(tester);
      for (final key in [
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.escape,
      ]) {
        await tester.sendKeyEvent(key);
        await _frames(tester);
        expect(_sheet, findsNothing, reason: key.keyLabel);
      }
      expect(s.controller.openSheetCalls, isEmpty);
      // Still the entry's turn: Enter opens it.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);
      _expectSheetOnce(s, _local, 'Enter after the other keys');
    });

    testWidgets('a hosted row opens the sheet on the hosted vault', (
      tester,
    ) async {
      final s = await _pump(tester, vault: _hosted, view: _hostedSuccessView());
      await tester.tapAt(_entryRect(tester).center);
      await _frames(tester);
      _expectSheetOnce(s, _hosted, 'a click on the hosted row');
    });

    testWidgets('the row is a tab stop that is never focused on its own', (
      tester,
    ) async {
      await _pump(tester, view: _localFailedView());
      expect(_entryFocused(tester), isFalse, reason: 'not auto-focused');
      await _tabToEntry(tester);
      expect(_entryFocused(tester), isTrue);
    });

    testWidgets('the row shows a click cursor and the hover fill', (
      tester,
    ) async {
      await _pump(tester, view: _offView());
      expect(_noFill(_box(tester)), isTrue);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(1100, 800));
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(_entry));
      await _frames(tester);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );
      expect(_box(tester).color, OmColors.surface3, reason: 'hover fill');
      await gesture.moveTo(const Offset(1100, 800));
      await _frames(tester);
      expect(_noFill(_box(tester)), isTrue, reason: 'hover ends');
    });

    testWidgets(
      'keyboard focus draws the strong border on a normal row and the warn border on a failed row',
      (tester) async {
        await _pump(tester, view: _offView());
        expect(_borderColor(_box(tester)), OmColors.line1);
        await _tabToEntry(tester);
        expect(_borderColor(_box(tester)), OmColors.lineStrong);

        await _pump(tester, view: _localFailedView());
        expect(_borderColor(_box(tester)), _warnLine);
        await _tabToEntry(tester);
        expect(_borderColor(_box(tester)), OmColors.warn);
      },
    );
  });

  // ================================================================ AC 3
  group('AC3 a local automatic failure warns until a later success', () {
    testWidgets(
      'a local failure shows the amber row with backup failed and the time and the badge',
      (tester) async {
        await _pump(tester, view: _localFailedView());
        expect(
          _rowText('backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
        expect(_textColor(tester, 'backup failed'), OmColors.warn);
        expect(_textColor(tester, '09:00'), OmColors.warn);

        expect(_badge, findsOneWidget);
        expect(tester.getSize(_badge), const Size(12, 12));
        final icon = tester.widget<Icon>(
          find.descendant(
            of: _badge,
            matching: find.byType(Icon),
            matchRoot: true,
          ),
        );
        expect(icon.icon, LucideIcons.triangleAlert);
        expect(icon.color, OmColors.warn);

        final box = _box(tester);
        expect(box.color, OmColors.warnBg, reason: 'warn fill');
        expect(_borderColor(box), _warnLine, reason: 'warnLine border');
      },
    );

    testWidgets('a failure on an earlier day shows the day and month', (
      tester,
    ) async {
      await _pump(tester, view: _localFailedView(at: DateTime(2026, 11, 7, 9)));
      expect(_rowText('backup failed'), findsOneWidget);
      expect(_rowText('7 nov'), findsOneWidget, reason: _entryText(tester));
      expect(_badge, findsOneWidget);
    });

    testWidgets(
      'an automatic run that memex refused as too old warns with the failure time',
      (tester) async {
        await _pump(tester, view: _tooOldWarningView());
        expect(
          _rowText('backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('09:00'), findsOneWidget);
        expect(_badge, findsOneWidget);
      },
    );

    testWidgets(
      'a real automatic failure turns the row amber and a later success clears it',
      (tester) async {
        // Live controller. 08:00: the last success was 23 h ago, not due.
        final clock = FakeClock(DateTime(2026, 11, 9, 8));
        final reader = FakeBackupStateReader()
          ..setEntry(
            _vaultPath,
            _googleDest,
            _created(DateTime(2026, 11, 8, 9)),
          );
        final runner = FakeBackupRunner();
        final s = await _pump(
          tester,
          live: true,
          clock: clock,
          reader: reader,
          runner: runner,
          settings: {_vaultPath: _on},
        );
        await _settle(tester);
        expect(runner.backupCalls, isEmpty, reason: 'not due at 08:00');
        expect(
          _rowText('23 h ago'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_badge, findsNothing);

        // 09:00 tick: due; the automatic run fails and records it.
        runner.scriptBackup(
          const BackupFailure(
            code: 'backup_destination_unavailable',
            message: 'the folder is gone',
          ),
        );
        runner.onCall = (_) {
          reader.setEntry(
            _vaultPath,
            _googleDest,
            _failedStatus(clock.now(), 'backup_destination_unavailable'),
          );
        };
        clock.advance(const Duration(hours: 1));
        await _settle(tester);
        expect(runner.backupCalls, hasLength(1));
        expect(runner.backupCalls.single.ifChanged, isTrue);
        expect(
          _rowText('backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
        expect(_badge, findsOneWidget);
        expect(_box(tester).color, OmColors.warnBg);
        expect(_sheet, findsNothing, reason: 'the warning opens no sheet');

        // 10:00 tick: the retry succeeds; the warning clears.
        runner.onCall = (_) {
          reader.setEntry(_vaultPath, _googleDest, _created(clock.now()));
        };
        clock.advance(const Duration(hours: 1));
        await _settle(tester);
        expect(runner.backupCalls, hasLength(2));
        expect(_badge, findsNothing, reason: 'a later success clears it');
        expect(_rowText('backup failed'), findsNothing);
        expect(
          _rowText('just now'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_noFill(_box(tester)), isTrue);
        expect(s.harness.hostedApi.calls, isEmpty);
      },
    );
  });

  // ================================================================ AC 4
  group('AC4 a hosted server-side failure warns with the server name', () {
    testWidgets(
      'a hosted failure shows the amber row with the server name and the badge',
      (tester) async {
        await _pump(tester, vault: _hosted, view: _hostedFailedView());
        expect(
          _rowText('nas backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('03:00'), findsOneWidget);
        expect(_textColor(tester, 'nas backup failed'), OmColors.warn);
        expect(_textColor(tester, '03:00'), OmColors.warn);
        expect(_badge, findsOneWidget);
        expect(_box(tester).color, OmColors.warnBg);
      },
    );

    testWidgets(
      'a real hosted failure read from the server warns and a later success clears it',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 11, 9, 9));
        final api = FakeHostedBackupApi()
          ..scriptStatus(HostedBackupOk(_hostedFailed(_hostedAt)));
        final s = await _pump(
          tester,
          vault: _hosted,
          live: true,
          clock: clock,
          hostedApi: api,
        );
        await _settle(tester);
        expect(api.statusCalls, 1, reason: 'one GET on open');
        expect(
          _rowText('nas backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('03:00'), findsOneWidget);
        expect(_badge, findsOneWidget);

        // The hourly read: the server's next run succeeded at 09:30.
        api.defaultStatus = HostedBackupOk(
          _hostedOk(DateTime(2026, 11, 9, 9, 30)),
        );
        clock.advance(const Duration(hours: 1));
        await _settle(tester);
        expect(api.statusCalls, 2);
        expect(_badge, findsNothing, reason: 'a later success clears it');
        expect(_rowText('nas backup failed'), findsNothing);
        expect(_rowText('backups on nas'), findsOneWidget);
        expect(_rowText('09:30'), findsOneWidget, reason: _entryText(tester));
        expect(s.harness.runner.calls, isEmpty);
      },
    );
  });

  // ================================================================ AC 5
  group('AC5 no warning while backups are off', () {
    testWidgets(
      'backups off with a failed last result shows off and no warning',
      (tester) async {
        final reader = FakeBackupStateReader()
          ..setEntry(
            _vaultPath,
            _googleDest,
            _failedStatus(_failedAt, 'backup_failed'),
          );
        final runner = FakeBackupRunner();
        await _pump(
          tester,
          live: true,
          reader: reader,
          runner: runner,
          settings: {
            _vaultPath: const VaultBackupSettings(destination: _googleDest),
          },
        );
        await _settle(tester);
        expect(_rowText('off'), findsOneWidget, reason: _entryText(tester));
        expect(_badge, findsNothing);
        expect(_rowText('backup failed'), findsNothing);
        expect(_noFill(_box(tester)), isTrue);
        expect(runner.calls, isEmpty);
      },
    );

    testWidgets(
      'turning backups off while the warning shows clears it at once',
      (tester) async {
        final reader = FakeBackupStateReader()
          ..setEntry(
            _vaultPath,
            _googleDest,
            // Failed at 09:00; the last success 2 h ago, so no run is due.
            BackupStatus(
              lastAttemptAt: _failedAt.toUtc(),
              lastSuccessAt: _lastBackup.toUtc(),
              lastResult: 'backup_failed',
              lastError: 'the folder is gone',
              lastFile: _file,
              lastFileCreatedAt: _lastBackup.toUtc(),
            ),
          );
        final runner = FakeBackupRunner();
        final s = await _pump(
          tester,
          live: true,
          runner: runner,
          reader: reader,
          settings: {_vaultPath: _on},
        );
        await _settle(tester);
        expect(_badge, findsOneWidget, reason: 'the recorded failure warns');
        expect(runner.calls, isEmpty, reason: 'not due');

        await s.container.read(saveVaultBackupSettingsProvider)(
          _vaultPath,
          _on.copyWith(enabled: false),
        );
        await _settle(tester);
        expect(_badge, findsNothing, reason: 'off: no warning');
        expect(_rowText('off'), findsOneWidget, reason: _entryText(tester));
        expect(_noFill(_box(tester)), isTrue);
      },
    );

    testWidgets(
      'a hosted server without backups shows set on the server and no warning',
      (tester) async {
        final api = FakeHostedBackupApi()
          ..defaultStatus = HostedBackupOk(
            BackupStatus(
              enabled: false,
              lastResult: 'backup_failed',
              lastAttemptAt: _hostedAt.toUtc(),
            ),
          );
        await _pump(tester, vault: _hosted, live: true, hostedApi: api);
        await _settle(tester);
        expect(
          _rowText('set on nas'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_badge, findsNothing);
        expect(_rowText('nas backup failed'), findsNothing);
      },
    );
  });

  // ================================================================ AC 6
  group('AC6 the warning never interrupts typing', () {
    testWidgets(
      'the warning appears while focus is in an editor field and typing still lands there',
      (tester) async {
        final clock = FakeClock(DateTime(2026, 11, 9, 8));
        final reader = FakeBackupStateReader()
          ..setEntry(
            _vaultPath,
            _googleDest,
            _created(DateTime(2026, 11, 8, 9)),
          );
        final runner = FakeBackupRunner()
          ..scriptBackup(
            const BackupFailure(
              code: 'backup_destination_unavailable',
              message: 'the folder is gone',
            ),
          );
        runner.onCall = (_) {
          reader.setEntry(
            _vaultPath,
            _googleDest,
            _failedStatus(clock.now(), 'backup_destination_unavailable'),
          );
        };
        final s = await _pump(
          tester,
          live: true,
          clock: clock,
          reader: reader,
          runner: runner,
          settings: {_vaultPath: _on},
          withEditor: true,
        );
        await _settle(tester);
        final editor = find.descendant(
          of: find.byKey(_editorKey),
          matching: find.byType(EditableText),
        );
        await tester.tap(find.byKey(_editorKey));
        await tester.pump();
        tester.testTextInput.enterText('moved the vault');
        await tester.pump();
        final barriers = find.byType(ModalBarrier).evaluate().length;
        expect(_badge, findsNothing);

        // The automatic run fails while the person types.
        clock.advance(const Duration(hours: 1));
        await _settle(tester);
        expect(_badge, findsOneWidget, reason: 'the warning appeared');
        expect(
          s.harness.runner.backupCalls,
          hasLength(1),
          reason: 'one automatic run',
        );

        final field = tester.widget<EditableText>(editor);
        expect(field.focusNode.hasFocus, isTrue, reason: 'focus stays');
        expect(_entryFocused(tester), isFalse, reason: 'never takes focus');
        expect(_sheet, findsNothing, reason: 'no sheet');
        expect(find.byType(Dialog), findsNothing, reason: 'no dialog');
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.byType(ModalBarrier).evaluate().length,
          barriers,
          reason: 'no modal route',
        );

        // Typing goes on in the same field, Space included.
        tester.testTextInput.enterText('moved the vault off the desktop');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await _frames(tester);
        expect(
          field.controller.text,
          startsWith('moved the vault off the desktop'),
        );
        expect(field.focusNode.hasFocus, isTrue);
        expect(
          _sheet,
          findsNothing,
          reason: 'Space in the field opens nothing',
        );
      },
    );
  });

  // ================================================================ AC 7
  group('AC7 the semantic label names the state and the failure', () {
    testWidgets(
      'the semantic label names each state and on a failure names the failure',
      (tester) async {
        final handle = tester.ensureSemantics();
        final cases = <(String, VaultRef, BackupViewState, String)>[
          ('off', _local, _offView(), 'backups for memex: off. open backups'),
          (
            'never',
            _local,
            _neverView(),
            'backups for memex: never backed up. open backups',
          ),
          (
            'last backup',
            _local,
            _successView(),
            'backups for memex: last backup today at 14:03. open backups',
          ),
          (
            'backing up',
            _local,
            _backingUpView(),
            'backups for memex: backing up. open backups',
          ),
          (
            'local automatic failure',
            _local,
            _localFailedView(),
            'backups for memex: the automatic backup failed today at 09:00, '
                "can't write to Google Drive. open backups",
          ),
          (
            'local back up now failure',
            _local,
            _localFailedView(automatic: false),
            'backups for memex: back up now failed today at 09:00, '
                "can't write to Google Drive. open backups",
          ),
          (
            'local failure on an earlier day',
            _local,
            _localFailedView(at: DateTime(2026, 11, 7, 9)),
            'backups for memex: the automatic backup failed 7 nov at 09:00, '
                "can't write to Google Drive. open backups",
          ),
          (
            'automatic too old',
            _local,
            _tooOldWarningView(),
            'backups for memex: the automatic backup failed today at 09:00, '
                'this memex is too old to make backups. open backups',
          ),
          (
            'hosted ok',
            _hosted,
            _hostedSuccessView(),
            "backups for work: nas's last backup today at 03:00. open backups",
          ),
          (
            'hosted failure',
            _hosted,
            _hostedFailedView(),
            "backups for work: nas's backup failed today at 03:00, nas can't "
                'write to its backup folder. open backups',
          ),
          (
            'hosted not configured',
            _hosted,
            _hostedNotConfiguredView(),
            'backups for work: set on nas. open backups',
          ),
          (
            'hosted server too old',
            _hosted,
            _hostedTooOldView(),
            'backups for work: not on nas yet. open backups',
          ),
          (
            'hosted backing up',
            _hosted,
            _hostedBackingUpView(),
            'backups for work: backing up. open backups',
          ),
        ];
        for (final (state, vault, view, label) in cases) {
          await _pump(tester, vault: vault, view: view);
          final node = _labelled(tester, label);
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
            reason: '$state: the labelled node is pressable',
          );
        }
        handle.dispose();
      },
    );

    testWidgets('every state is written as text not only colour', (
      tester,
    ) async {
      final cases = <(String, VaultRef, BackupViewState, List<String>)>[
        ('off', _local, _offView(), ['off']),
        ('never', _local, _neverView(), ['never']),
        (
          'local failure',
          _local,
          _localFailedView(),
          ['backup failed', '09:00'],
        ),
        (
          'hosted failure',
          _hosted,
          _hostedFailedView(),
          ['nas backup failed', '03:00'],
        ),
        (
          'hosted ok',
          _hosted,
          _hostedSuccessView(),
          ['backups on nas', '03:00'],
        ),
      ];
      for (final (state, vault, view, texts) in cases) {
        await _pump(tester, vault: vault, view: view);
        for (final t in texts) {
          expect(_rowText(t), findsOneWidget, reason: '$state: "$t" is text');
        }
      }
      // The failed and ok rows differ in words, not just in colour.
      await _pump(tester, view: _localFailedView());
      final failed = _entryText(tester);
      await _pump(tester, view: _successView());
      expect(_entryText(tester), isNot(failed));
    });
  });

  // ================================================================ AC 10
  group('AC10 large text at the narrowest sidebar width', () {
    testWidgets(
      'at 1.3x text and the 268 wide sidebar the row text wraps without clipping',
      (tester) async {
        final cases = <(String, VaultRef, BackupViewState)>[
          ('off', _local, _offView()),
          ('never', _local, _neverView()),
          ('last backup', _local, _successView()),
          ('backing up', _local, _backingUpView()),
          ('local failure', _local, _localFailedView()),
          (
            'local failure earlier day',
            _local,
            _localFailedView(at: DateTime(2026, 11, 7, 9)),
          ),
          ('hosted ok', _hosted, _hostedSuccessView()),
          ('hosted failure', _hosted, _hostedFailedView()),
          ('hosted not configured', _hosted, _hostedNotConfiguredView()),
          ('hosted server too old', _hosted, _hostedTooOldView()),
        ];
        for (final (state, vault, view) in cases) {
          await _pump(tester, vault: vault, view: view, textScale: 1.3);
          expect(_entry, findsOneWidget, reason: state);
          final r = _entryRect(tester);
          expect(r.width, moreOrLessEquals(244, epsilon: 0.5), reason: state);
          expect(r.height, greaterThanOrEqualTo(28 - 0.5), reason: state);
          _expectNothingClipped(tester, '1.3x $state');
        }
      },
    );

    testWidgets(
      'at 1.3x a row that does not fit one line grows and the status wraps under the label past the icon',
      (tester) async {
        await _pump(
          tester,
          vault: _hosted,
          view: _hostedFailedView(),
          textScale: 1.3,
        );
        final entry = _entryRect(tester);
        final label = tester.getRect(_rowText('nas backup failed'));
        final status = tester.getRect(_rowText('03:00'));
        final icon = tester.getRect(_badge);
        expect(entry.height, greaterThan(28), reason: 'the row grows');
        expect(
          status.top,
          greaterThanOrEqualTo(label.bottom - 0.5),
          reason: 'the status wraps under the label',
        );
        expect(
          status.left,
          greaterThanOrEqualTo(icon.right),
          reason: 'indented past the icon',
        );
        _expectNothingClipped(tester, '1.3x hosted failure');
      },
    );
  });

  // ======================================================= lead rulings Q1-Q3
  group('rulings Q1 to Q3 the warning flag decides the amber row', () {
    testWidgets(
      'a backing up view with the warning flag on keeps the amber row and the badge',
      (tester) async {
        // Q1: the amber row wins over the backing up mode. The controller's
        // backing up view carries the warning flag and the state file's
        // status, but none of the failure's own fields (failedAt, automatic,
        // message): the row goes on stating the failure it last showed.
        final s = await _pump(tester, view: _localFailedView());
        expect(_rowText('09:00'), findsOneWidget);

        s.controller.setViewState(_local, _retryingView());
        await _frames(tester);
        expect(
          _rowText('backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
        expect(_rowText('backing up…'), findsNothing);
        expect(_badge, findsOneWidget, reason: 'local: the badge stays');
        expect(_box(tester).color, OmColors.warnBg);

        final hosted = await _pump(
          tester,
          vault: _hosted,
          view: _hostedFailedView(),
        );
        expect(_rowText('03:00'), findsOneWidget);
        hosted.controller.setViewState(
          _hosted,
          BackupViewState(
            mode: BackupSheetMode.backingUp,
            hosted: true,
            status: _hostedFailed(_hostedAt),
            startedAt: _now.toUtc(),
            warning: true,
          ),
        );
        await _frames(tester);
        expect(
          _rowText('nas backup failed'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('03:00'), findsOneWidget, reason: _entryText(tester));
        expect(_rowText('backing up…'), findsNothing);
        expect(_badge, findsOneWidget, reason: 'hosted: the badge stays');
      },
    );

    testWidgets(
      'an unrecorded manual failure with the warning flag off shows the age or never and no badge',
      (tester) async {
        // Q2: a failure kept in memory (exit 2, binary not found, back up now)
        // raises no warning; the row reads as without it.
        for (final mode in [
          BackupSheetMode.error,
          BackupSheetMode.memexTooOld,
          BackupSheetMode.binaryNotFound,
        ]) {
          await _pump(
            tester,
            view: BackupViewState(
              mode: mode,
              settings: _on,
              status: _created(_lastBackup),
              errorCode: 'backup_failed',
              failedAt: _failedAt.toUtc(),
            ),
          );
          expect(
            _rowText('2 h ago'),
            findsOneWidget,
            reason: '${mode.name}: ${_entryText(tester)}',
          );
          expect(_rowText('backups'), findsOneWidget, reason: mode.name);
          expect(_badge, findsNothing, reason: '${mode.name}: no badge');
          expect(_noFill(_box(tester)), isTrue, reason: '${mode.name}: fill');

          await _pump(
            tester,
            view: BackupViewState(
              mode: mode,
              settings: _on,
              errorCode: 'backup_failed',
              failedAt: _failedAt.toUtc(),
            ),
          );
          expect(
            _rowText('never'),
            findsOneWidget,
            reason: '${mode.name}: ${_entryText(tester)}',
          );
          expect(_badge, findsNothing, reason: '${mode.name}: no badge');
        }
      },
    );

    testWidgets(
      'a hosted vault with no status yet shows the label only and its semantic label',
      (tester) async {
        // Q3: the controller's unseen hosted view (mode off, no status).
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          vault: _hosted,
          view: const BackupViewState(mode: BackupSheetMode.off, hosted: true),
        );
        final texts = tester
            .widgetList<Text>(
              find.descendant(of: _entry, matching: find.byType(Text)),
            )
            .map((w) => w.data)
            .toList();
        expect(texts, ['backups on nas'], reason: 'label only, no status');
        expect(_badge, findsNothing);
        _labelled(tester, 'backups for work: backups on nas. open backups');
        handle.dispose();
      },
    );
  });

  group('pinned contracts from the handoff', () {
    testWidgets(
      'numpad Enter with focus on backups-entry opens the sheet once',
      (tester) async {
        final s = await _pump(tester, view: _offView());
        await _tabToEntry(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
        await _frames(tester);
        _expectSheetOnce(s, _local, 'numpad Enter with focus');
      },
    );

    testWidgets(
      'a hosted last backup from an earlier day reads as an age and a hosted failure from an earlier day as a date',
      (tester) async {
        await _pump(
          tester,
          vault: _hosted,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            hosted: true,
            status: _hostedOk(DateTime(2026, 11, 7, 3)),
          ),
        );
        expect(_rowText('2 d ago'), findsOneWidget, reason: _entryText(tester));
        expect(_rowText('03:00'), findsNothing);

        final earlier = DateTime(2026, 11, 7, 3);
        await _pump(
          tester,
          vault: _hosted,
          view: BackupViewState(
            mode: BackupSheetMode.error,
            hosted: true,
            status: _hostedFailed(earlier),
            errorCode: 'backup_destination_unavailable',
            automatic: true,
            failedAt: earlier.toUtc(),
            warning: true,
          ),
        );
        expect(_rowText('7 nov'), findsOneWidget, reason: _entryText(tester));
        expect(_rowText('nas backup failed'), findsOneWidget);
      },
    );

    testWidgets(
      'a hosted server that has never backed up shows never and the never backed up label',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          vault: _hosted,
          view: const BackupViewState(
            mode: BackupSheetMode.neverBackedUp,
            hosted: true,
            status: BackupStatus(enabled: true, keep: 30),
          ),
        );
        expect(_rowText('backups on nas'), findsOneWidget);
        expect(_rowText('never'), findsOneWidget, reason: _entryText(tester));
        expect(_badge, findsNothing);
        _labelled(tester, 'backups for work: never backed up. open backups');
        handle.dispose();
      },
    );

    testWidgets('keyboard focus draws a two pixel ring around the row', (
      tester,
    ) async {
      bool hasRing() => find
          .descendant(
            of: find.byType(Scaffold),
            matching: find.byWidgetPredicate((w) {
              if (w is! DecoratedBox) return false;
              final d = w.decoration;
              return d is BoxDecoration &&
                  d.border is Border &&
                  (d.border! as Border).top.width == 2;
            }),
          )
          .evaluate()
          .isNotEmpty;
      await _pump(tester, view: _offView());
      expect(hasRing(), isFalse, reason: 'no ring before focus');
      await _tabToEntry(tester);
      expect(hasRing(), isTrue, reason: 'ring with keyboard focus');
    });

    testWidgets('the row pads four pixels above and below only at large text', (
      tester,
    ) async {
      EdgeInsetsGeometry? padding() => tester
          .widget<Container>(
            find.descendant(of: _entry, matching: find.byType(Container)).first,
          )
          .padding;
      await _pump(tester, view: _offView());
      expect(padding(), const EdgeInsets.symmetric(horizontal: 10));
      await _pump(tester, view: _offView(), textScale: 1.3);
      expect(
        padding(),
        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      );
    });
  });

  group('boundaries and fallbacks the mutator would flip', () {
    testWidgets(
      'the age flips to the next unit at exactly one minute one hour and one day',
      (tester) async {
        final now = DateTime(2026, 11, 9, 16, 3, 30);
        final cases = <(Duration, String)>[
          (const Duration(seconds: 59), 'just now'),
          (const Duration(seconds: 60), '1 min ago'),
          (const Duration(minutes: 59, seconds: 59), '59 min ago'),
          (const Duration(minutes: 60), '1 h ago'),
          (const Duration(hours: 23, minutes: 59), '23 h ago'),
          (const Duration(hours: 24), '1 d ago'),
        ];
        for (final (ago, expected) in cases) {
          await _pump(
            tester,
            clock: FakeClock(now),
            view: _successView(at: now.subtract(ago)),
          );
          expect(
            _rowText(expected),
            findsOneWidget,
            reason: '$ago: ${_entryText(tester)}',
          );
        }
      },
    );

    testWidgets('a failure on an earlier day names its month in every month', (
      tester,
    ) async {
      const months = [
        'jan', 'feb', 'mar', 'apr', 'may', 'jun', //
        'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
      ];
      for (var m = 1; m <= 12; m++) {
        await _pump(
          tester,
          clock: FakeClock(DateTime(2027, 6, 20, 12)),
          view: _localFailedView(at: DateTime(2026, m, 5, 9)),
        );
        expect(
          _rowText('5 ${months[m - 1]}'),
          findsOneWidget,
          reason: 'month $m: ${_entryText(tester)}',
        );
      }
    });

    testWidgets('the same day number in another month is not today', (
      tester,
    ) async {
      // 9 Oct 09:00 against now 9 Nov: same day of month, same year.
      await _pump(tester, view: _localFailedView(at: DateTime(2026, 10, 9, 9)));
      expect(_rowText('9 oct'), findsOneWidget, reason: _entryText(tester));
      expect(_rowText('09:00'), findsNothing);
    });

    testWidgets(
      'a warning with no failure time anywhere shows the plain row and no badge',
      (tester) async {
        await _pump(
          tester,
          view: const BackupViewState(
            mode: BackupSheetMode.error,
            settings: _on,
            warning: true,
          ),
        );
        expect(_badge, findsNothing, reason: _entryText(tester));
        expect(_rowText('never'), findsOneWidget);

        await _pump(
          tester,
          vault: _hosted,
          view: const BackupViewState(
            mode: BackupSheetMode.error,
            hosted: true,
            warning: true,
          ),
        );
        expect(_badge, findsNothing, reason: _entryText(tester));
        expect(_rowText('backups on nas'), findsOneWidget);
      },
    );

    testWidgets(
      'a warning without a kept failure time uses the recorded attempt time and with no message names no cause',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.error,
            settings: _on,
            status: _failedStatus(_failedAt, 'backup_failed'),
            errorCode: 'backup_failed',
            automatic: true,
            warning: true,
          ),
        );
        expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
        expect(_badge, findsOneWidget);
        _labelled(
          tester,
          'backups for memex: the automatic backup failed today at 09:00. '
          'open backups',
        );

        await _pump(
          tester,
          vault: _hosted,
          view: BackupViewState(
            mode: BackupSheetMode.error,
            hosted: true,
            status: _hostedFailed(_hostedAt),
            warning: true,
          ),
        );
        expect(_rowText('03:00'), findsOneWidget, reason: _entryText(tester));
        expect(_rowText('nas backup failed'), findsOneWidget);
        _labelled(
          tester,
          "backups for work: nas's backup failed today at 03:00. open backups",
        );
        handle.dispose();
      },
    );

    testWidgets(
      'the age falls back to the last success time when no file time is recorded',
      (tester) async {
        await _pump(
          tester,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            settings: _on,
            status: BackupStatus(
              lastSuccessAt: _lastBackup.toUtc(),
              lastResult: 'created',
            ),
          ),
        );
        expect(_rowText('2 h ago'), findsOneWidget, reason: _entryText(tester));
        await _pump(
          tester,
          vault: _hosted,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            hosted: true,
            status: BackupStatus(
              enabled: true,
              lastSuccessAt: _hostedAt.toUtc(),
              lastResult: 'created',
            ),
          ),
        );
        expect(_rowText('03:00'), findsOneWidget, reason: _entryText(tester));
      },
    );

    testWidgets(
      'an unreachable server keeps what was last read for every kind of last value',
      (tester) async {
        final cases = <(String, BackupStatus?, String?)>[
          ('nothing read yet', null, null),
          (
            'no backups on the server',
            const BackupStatus(enabled: false),
            'set on nas',
          ),
          (
            'never backed up',
            const BackupStatus(enabled: true, keep: 30),
            'never',
          ),
        ];
        for (final (why, status, shown) in cases) {
          await _pump(
            tester,
            vault: _hosted,
            view: BackupViewState(
              mode: BackupSheetMode.hostedUnreachable,
              hosted: true,
              status: status,
            ),
          );
          expect(_rowText('backups on nas'), findsOneWidget);
          if (shown != null) {
            expect(
              _rowText(shown),
              findsOneWidget,
              reason: '$why: ${_entryText(tester)}',
            );
          } else {
            expect(
              _entryText(tester).split('\n').where((l) => l.trim().length > 1),
              ['backups on nas'],
              reason: why,
            );
          }
          expect(_badge, findsNothing, reason: why);
        }
      },
    );

    testWidgets('a failed row keeps its warning fill under the pointer', (
      tester,
    ) async {
      await _pump(tester, view: _localFailedView());
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.addPointer(location: const Offset(1100, 800));
      await gesture.moveTo(tester.getCenter(_entry));
      await _frames(tester);
      expect(_box(tester).color, OmColors.warnBg);
    });

    testWidgets(
      'the focus ring is glow green on a normal row and warn line on a failed row',
      (tester) async {
        Color? ringColor() {
          for (final e
              in find
                  .descendant(
                    of: find.byType(Scaffold),
                    matching: find.byType(DecoratedBox),
                  )
                  .evaluate()) {
            final d = (e.widget as DecoratedBox).decoration;
            if (d is BoxDecoration &&
                d.border is Border &&
                (d.border! as Border).top.width == 2) {
              return (d.border! as Border).top.color;
            }
          }
          return null;
        }

        await _pump(tester, view: _offView());
        await _tabToEntry(tester);
        expect(ringColor(), OmColors.accentGlow);
        await _pump(tester, view: _localFailedView());
        await _tabToEntry(tester);
        expect(ringColor(), _warnLine);
      },
    );

    testWidgets(
      'the backing up icon turns while it shows and a settled row does not',
      (tester) async {
        final turn = find.descendant(
          of: _entry,
          matching: find.byType(RotationTransition),
        );
        await _pump(tester, view: _backingUpView());
        expect(turn, findsOneWidget);
        final before = tester.widget<RotationTransition>(turn).turns.value;
        await tester.pump(const Duration(milliseconds: 400));
        final after = tester.widget<RotationTransition>(turn).turns.value;
        expect(after, isNot(before), reason: 'the icon turns');

        await _pump(tester, view: _successView());
        expect(turn, findsNothing);
      },
    );
  });

  // ===================================================== review r1 fixes
  group('the row redraws as its time text turns (r1 finding 1)', () {
    testWidgets(
      'the age turns at each minute hour and day boundary as the clock advances with no new view',
      (tester) async {
        final s = await _pump(tester, view: _successView(at: _now));
        Future<void> after(Duration d, String text) async {
          s.clock.advanceTo(_now.add(d));
          await _frames(tester);
          expect(
            _rowText(text),
            findsOneWidget,
            reason: 'after $d: ${_entryText(tester)}',
          );
        }

        expect(_rowText('just now'), findsOneWidget);
        await after(const Duration(seconds: 59), 'just now');
        await after(const Duration(minutes: 1), '1 min ago');
        await after(const Duration(minutes: 59, seconds: 59), '59 min ago');
        await after(const Duration(hours: 1), '1 h ago');
        await after(const Duration(hours: 2), '2 h ago');
        await after(
          const Duration(hours: 23, minutes: 59, seconds: 59),
          '23 h ago',
        );
        await after(const Duration(hours: 24), '1 d ago');
        await after(
          const Duration(hours: 47, minutes: 59, seconds: 59),
          '1 d ago',
        );
        await after(const Duration(hours: 48), '2 d ago');
      },
    );

    testWidgets('a jump of several hours at once lands on the right age', (
      tester,
    ) async {
      final s = await _pump(tester, view: _successView(at: _now));
      s.clock.advance(const Duration(hours: 5, minutes: 30));
      await _frames(tester);
      expect(_rowText('5 h ago'), findsOneWidget, reason: _entryText(tester));
      expect(_rowText('just now'), findsNothing);
    });

    testWidgets('a local failure time turns into its date at local midnight', (
      tester,
    ) async {
      final s = await _pump(tester, view: _localFailedView());
      expect(_rowText('09:00'), findsOneWidget);

      s.clock.advanceTo(DateTime(2026, 11, 9, 23, 59, 59));
      await _frames(tester);
      expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));

      s.clock.advanceTo(DateTime(2026, 11, 10));
      await _frames(tester);
      expect(_rowText('9 nov'), findsOneWidget, reason: _entryText(tester));
      expect(_rowText('09:00'), findsNothing);
      expect(_badge, findsOneWidget, reason: 'still a warning');
      expect(_rowText('backup failed'), findsOneWidget);
    });

    testWidgets(
      'a hosted clock time turns into the age at local midnight and then keeps counting',
      (tester) async {
        final s = await _pump(
          tester,
          vault: _hosted,
          view: _hostedSuccessView(),
        );
        expect(_rowText('03:00'), findsOneWidget);

        s.clock.advanceTo(DateTime(2026, 11, 9, 23, 59, 59));
        await _frames(tester);
        expect(_rowText('03:00'), findsOneWidget, reason: _entryText(tester));

        s.clock.advanceTo(DateTime(2026, 11, 10));
        await _frames(tester);
        expect(
          _rowText('21 h ago'),
          findsOneWidget,
          reason: _entryText(tester),
        );
        expect(_rowText('03:00'), findsNothing);

        s.clock.advanceTo(DateTime(2026, 11, 10, 1));
        await _frames(tester);
        expect(
          _rowText('22 h ago'),
          findsOneWidget,
          reason: _entryText(tester),
        );
      },
    );

    testWidgets(
      'the semantic label turns from yesterday to the date at local midnight with the age text unchanged',
      (tester) async {
        // 1 d ago holds for a day, so only local midnight turns the label.
        final handle = tester.ensureSemantics();
        final s = await _pump(
          tester,
          view: _successView(at: _now.subtract(const Duration(days: 1))),
        );
        expect(_rowText('1 d ago'), findsOneWidget);
        _labelled(
          tester,
          'backups for memex: last backup yesterday at 16:03. open backups',
        );
        s.clock.advanceTo(DateTime(2026, 11, 9, 23, 59, 59));
        await _frames(tester);
        _labelled(
          tester,
          'backups for memex: last backup yesterday at 16:03. open backups',
        );
        s.clock.advanceTo(DateTime(2026, 11, 10));
        await _frames(tester);
        expect(_rowText('1 d ago'), findsOneWidget, reason: _entryText(tester));
        _labelled(
          tester,
          'backups for memex: last backup 8 nov at 16:03. open backups',
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a hosted semantic label turns from yesterday to the date at local midnight with the age text unchanged',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pump(
          tester,
          vault: _hosted,
          view: BackupViewState(
            mode: BackupSheetMode.success,
            hosted: true,
            status: _hostedOk(_now.subtract(const Duration(days: 1))),
          ),
        );
        expect(_rowText('1 d ago'), findsOneWidget, reason: _entryText(tester));
        _labelled(
          tester,
          "backups for work: nas's last backup yesterday at 16:03. open backups",
        );
        s.clock.advanceTo(DateTime(2026, 11, 10));
        await _frames(tester);
        expect(_rowText('1 d ago'), findsOneWidget, reason: _entryText(tester));
        _labelled(
          tester,
          "backups for work: nas's last backup 8 nov at 16:03. open backups",
        );
        handle.dispose();
      },
    );

    testWidgets('a row keeps one redraw timer only while it shows a time', (
      tester,
    ) async {
      final cases = <(String, VaultRef, BackupViewState, int)>[
        ('off', _local, _offView(), 0),
        ('never', _local, _neverView(), 0),
        ('local backing up', _local, _backingUpView(), 0),
        ('local success', _local, _successView(), 1),
        ('local failure', _local, _localFailedView(), 1),
        ('warning with no time known', _local, _noTimeWarningView(), 0),
        ('hosted success', _hosted, _hostedSuccessView(), 1),
        ('hosted failure', _hosted, _hostedFailedView(), 1),
        ('hosted not configured', _hosted, _hostedNotConfiguredView(), 0),
        ('hosted server too old', _hosted, _hostedTooOldView(), 0),
        ('hosted backing up', _hosted, _hostedBackingUpView(), 0),
        (
          'hosted not read yet',
          _hosted,
          const BackupViewState(mode: BackupSheetMode.off, hosted: true),
          0,
        ),
      ];
      for (final (name, vault, view, timers) in cases) {
        final s = await _pump(tester, vault: vault, view: view);
        expect(s.clock.pendingTimers, timers, reason: name);
      }
    });

    testWidgets(
      'the redraw timer is replaced not doubled and cancelled when the row stops showing a time',
      (tester) async {
        final s = await _pump(tester, view: _successView(at: _now));
        expect(s.clock.pendingTimers, 1);

        s.clock.advance(const Duration(seconds: 30));
        await _frames(tester);
        expect(_rowText('just now'), findsOneWidget);
        expect(s.clock.pendingTimers, 1, reason: 'no turn yet, still one');

        s.controller.setViewState(
          _local,
          _successView(at: _now.subtract(const Duration(minutes: 5))),
        );
        await _frames(tester);
        expect(_rowText('5 min ago'), findsOneWidget);
        expect(s.clock.pendingTimers, 1, reason: 'replaced, not doubled');

        s.controller.setViewState(_local, _backingUpView());
        await _frames(tester);
        expect(s.clock.pendingTimers, 0, reason: 'backing up shows no time');

        s.controller.setViewState(_local, _offView());
        await _frames(tester);
        expect(s.clock.pendingTimers, 0, reason: 'off shows no time');

        s.controller.setViewState(_local, _localFailedView());
        await _frames(tester);
        expect(s.clock.pendingTimers, 1, reason: 'a failure time');

        s.container.read(currentVaultProvider.notifier).state = null;
        await _frames(tester);
        expect(s.clock.pendingTimers, 0, reason: 'no vault, no row, no timer');

        s.container.read(currentVaultProvider.notifier).state = _local;
        await _frames(tester);
        expect(s.clock.pendingTimers, 1);

        await tester.pumpWidget(const SizedBox());
        expect(s.clock.pendingTimers, 0, reason: 'cancelled when removed');
      },
    );
  });

  group(
    'the warning keeps naming its failure through a retry or a busy press (r1 findings 3 and 4)',
    () {
      testWidgets(
        'a retry keeps the earlier failure in the label and a newer failure replaces it',
        (tester) async {
          final handle = tester.ensureSemantics();
          final s = await _pump(tester, view: _localFailedView());
          const cause = "can't write to Google Drive";
          _labelled(
            tester,
            'backups for memex: the automatic backup failed today at 09:00, '
            '$cause. open backups',
          );

          s.controller.setViewState(_local, _retryingView());
          await _frames(tester);
          _labelled(
            tester,
            'backups for memex: the automatic backup failed today at 09:00, '
            '$cause. open backups',
          );
          expect(_rowText('09:00'), findsOneWidget);

          // The retry fails too: the newer failure is the one stated.
          s.controller.setViewState(
            _local,
            _localFailedView(at: DateTime(2026, 11, 9, 10)),
          );
          await _frames(tester);
          expect(_rowText('10:00'), findsOneWidget, reason: _entryText(tester));
          s.controller.setViewState(_local, _retryingView());
          await _frames(tester);
          expect(_rowText('10:00'), findsOneWidget, reason: _entryText(tester));
          expect(_rowText('09:00'), findsNothing);
          handle.dispose();
        },
      );

      testWidgets(
        'a back up now that finds a backup running keeps the earlier failure and is not stated as one',
        (tester) async {
          final handle = tester.ensureSemantics();
          final s = await _pump(tester, view: _localFailedView());
          s.controller.setViewState(
            _local,
            _busyPressView(at: DateTime(2026, 11, 9, 10, 15)),
          );
          await _frames(tester);
          expect(_rowText('backup failed'), findsOneWidget);
          expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
          expect(
            _rowText('10:15'),
            findsNothing,
            reason: 'the press is no failure',
          );
          expect(_badge, findsOneWidget);
          final labels = _semanticsInEntry(tester).map((n) => n.label).toList();
          expect(
            labels.any(
              (l) =>
                  l.contains('the automatic backup failed today at 09:00') &&
                  l.contains("can't write to Google Drive"),
            ),
            isTrue,
            reason: '$labels',
          );
          expect(
            labels.any(
              (l) =>
                  l.contains('already running') ||
                  l.contains('back up now failed'),
            ),
            isFalse,
            reason: '$labels',
          );
          handle.dispose();
        },
      );

      testWidgets(
        'a busy press before any failure was shown falls back to the failed attempt in the state file',
        (tester) async {
          await _pump(tester, view: _busyPressView());
          expect(_rowText('backup failed'), findsOneWidget);
          expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
          expect(_rowText('16:03'), findsNothing);
        },
      );

      testWidgets(
        'with no failure known a retry or a busy press shows amber with no time and a clearing success forgets the kept failure',
        (tester) async {
          final handle = tester.ensureSemantics();
          final s = await _pump(tester, view: _noTimeWarningView());
          expect(
            _rowText('backup failed'),
            findsOneWidget,
            reason: _entryText(tester),
          );
          expect(_rowText('backing up…'), findsNothing);
          expect(_badge, findsOneWidget);
          expect(_box(tester).color, OmColors.warnBg);
          expect(_shownTexts(tester), [
            'backup failed',
          ], reason: 'no time: a label and no status');
          _labelled(
            tester,
            'backups for memex: the automatic backup failed. open backups',
          );

          // The same with a busy press and no failure known.
          s.controller.setViewState(
            _local,
            BackupViewState(
              mode: BackupSheetMode.error,
              settings: _on,
              status: _created(_lastBackup),
              errorCode: 'backup_in_progress',
              failedAt: _now.toUtc(),
              warning: true,
            ),
          );
          await _frames(tester);
          expect(_shownTexts(tester), ['backup failed']);

          // A failure is shown, then a success clears the warning and the kept
          // failure with it: a later retry with the flag on states no time.
          s.controller.setViewState(_local, _localFailedView());
          await _frames(tester);
          expect(_rowText('09:00'), findsOneWidget);
          s.controller.setViewState(_local, _successView(at: _now));
          await _frames(tester);
          expect(_badge, findsNothing);
          s.controller.setViewState(_local, _noTimeWarningView());
          await _frames(tester);
          expect(_rowText('09:00'), findsNothing, reason: _entryText(tester));
          expect(_shownTexts(tester), ['backup failed']);
          handle.dispose();
        },
      );

      testWidgets('a kept failure is per vault', (tester) async {
        final s = await _pump(tester, view: _localFailedView());
        expect(_rowText('09:00'), findsOneWidget);
        s.controller.setViewState(_other, _noTimeWarningView());
        s.container.read(currentVaultProvider.notifier).state = _other;
        await _frames(tester);
        expect(_shownTexts(tester), [
          'backup failed',
        ], reason: 'memex failure is not journal failure');
      });

      testWidgets(
        'the failed attempt in the state file stands in only when it failed',
        (tester) async {
          // Warning flag on, a retry running, nothing shown before: the
          // recorded failed attempt names the time.
          await _pump(tester, view: _retryingView());
          expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
          expect(_rowText('backup failed'), findsOneWidget);

          // The recorded attempt succeeded: its time is not a failure time.
          await _pump(
            tester,
            view: BackupViewState(
              mode: BackupSheetMode.backingUp,
              settings: _on,
              status: _created(_lastBackup),
              startedAt: _now.toUtc(),
              warning: true,
            ),
          );
          expect(_rowText('14:03'), findsNothing, reason: _entryText(tester));
          expect(_shownTexts(tester), ['backup failed']);
        },
      );

      testWidgets(
        'the warning flag with no failure to state and no run under way shows the plain row',
        (tester) async {
          await _pump(
            tester,
            view: BackupViewState(
              mode: BackupSheetMode.success,
              settings: _on,
              status: _created(_lastBackup),
              warning: true,
            ),
          );
          expect(
            _rowText('2 h ago'),
            findsOneWidget,
            reason: _entryText(tester),
          );
          expect(_badge, findsNothing);
          expect(_noFill(_box(tester)), isTrue);
        },
      );

      testWidgets(
        'a hosted server that cannot be reached keeps stating the failure it showed',
        (tester) async {
          final s = await _pump(
            tester,
            vault: _hosted,
            view: _hostedFailedView(),
          );
          expect(_rowText('03:00'), findsOneWidget);
          s.controller.setViewState(
            _hosted,
            BackupViewState(
              mode: BackupSheetMode.hostedUnreachable,
              hosted: true,
              status: _hostedFailed(_hostedAt),
              warning: true,
            ),
          );
          await _frames(tester);
          expect(
            _rowText('nas backup failed'),
            findsOneWidget,
            reason: _entryText(tester),
          );
          expect(_rowText('03:00'), findsOneWidget);
          expect(_badge, findsOneWidget);
        },
      );

      testWidgets(
        'a real automatic failure then a held retry then a busy press keep the row naming the failure',
        (tester) async {
          // Live controller end to end: the views the controller really
          // produces carry the warning flag but not the failure's fields.
          final handle = tester.ensureSemantics();
          final clock = FakeClock(DateTime(2026, 11, 9, 8));
          final reader = FakeBackupStateReader()
            ..setEntry(
              _vaultPath,
              _googleDest,
              _created(DateTime(2026, 11, 8, 9)),
            );
          final runner = FakeBackupRunner();
          final s = await _pump(
            tester,
            live: true,
            clock: clock,
            reader: reader,
            runner: runner,
            settings: {_vaultPath: _on},
          );
          await _settle(tester);
          expect(runner.backupCalls, isEmpty, reason: 'not due at 08:00');

          runner.scriptBackup(
            const BackupFailure(
              code: 'backup_destination_unavailable',
              message: 'the folder is gone',
            ),
          );
          runner.onCall = (_) {
            reader.setEntry(
              _vaultPath,
              _googleDest,
              _failedStatus(clock.now(), 'backup_destination_unavailable'),
            );
          };
          clock.advance(const Duration(hours: 1));
          await _settle(tester);
          expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
          expect(_badge, findsOneWidget);
          const stated =
              'backups for memex: the automatic backup failed today at 09:00, '
              "can't write to Google Drive. open backups";
          _labelled(tester, stated);

          // 10:00: the hourly retry starts and is held in flight.
          final hold = runner.holdRuns();
          runner.scriptBackup(
            const BackupFailure(
              code: 'backup_destination_unavailable',
              message: 'the folder is gone',
            ),
          );
          clock.advance(const Duration(hours: 1));
          await _settle(tester);
          expect(runner.inFlight, 1, reason: 'the retry is under way');
          expect(
            s.container
                .read(backupControllerProvider.notifier)
                .viewStateOf(_local)
                .mode,
            BackupSheetMode.backingUp,
          );
          expect(_rowText('backing up…'), findsNothing);
          expect(_rowText('backup failed'), findsOneWidget);
          expect(_rowText('09:00'), findsOneWidget, reason: _entryText(tester));
          expect(_badge, findsOneWidget);
          _labelled(tester, stated);

          // The retry fails too: the newer failure is stated.
          hold.complete();
          await _settle(tester);
          expect(_rowText('10:00'), findsOneWidget, reason: _entryText(tester));

          // 10:15: a launchd run holds the lock; Back up now is answered
          // backup_in_progress. Not a failure: the row keeps the 10:00 one.
          clock.advance(const Duration(minutes: 15));
          runner.onCall = null; // the lock holder is a launchd run, not ours
          runner.scriptBackup(
            const BackupFailure(
              code: 'backup_in_progress',
              message: 'a backup is already running',
            ),
          );
          await s.container
              .read(backupControllerProvider.notifier)
              .backUpNow(_local);
          await _settle(tester);
          final view = s.container
              .read(backupControllerProvider.notifier)
              .viewStateOf(_local);
          expect(view.errorCode, 'backup_in_progress');
          expect(_rowText('10:00'), findsOneWidget, reason: _entryText(tester));
          expect(_rowText('10:15'), findsNothing);
          expect(_badge, findsOneWidget);
          _labelled(
            tester,
            'backups for memex: the automatic backup failed today at 10:00, '
            "can't write to Google Drive. open backups",
          );
          handle.dispose();
        },
      );
    },
  );

  group('reduced motion (r1 nit)', () {
    testWidgets(
      'the backing up spinner stands still while the platform asks for reduced motion and turns again when it does not',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final s = await _pump(tester, view: _backingUpView());
        expect(_icon(tester).icon, LucideIcons.loaderCircle);
        expect(
          tester.hasRunningAnimations,
          isFalse,
          reason: 'reduced motion: the spinner does not turn',
        );

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures();
        await _frames(tester);
        expect(
          tester.hasRunningAnimations,
          isTrue,
          reason: 'motion allowed again: it turns',
        );

        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        await _frames(tester);
        expect(tester.hasRunningAnimations, isFalse, reason: 'stops again');
        expect(s.controller.openSheetCalls, isEmpty);
      },
    );
  });

  // A guard for the rig itself: the stored settings decode as the live
  // controller reads them.
  test('the settings prefs the rig writes decode per vault path', () {
    final json =
        jsonDecode(_settingsJson({_vaultPath: _on})) as Map<String, Object?>;
    expect(
      VaultBackupSettings.fromJson(json[_vaultPath]! as Map<String, Object?>),
      _on,
    );
  });
}
