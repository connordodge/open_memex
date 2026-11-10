// WI #327 (A6, D24, Spec req 35 and 37, L7, L9): "restore from backup…" in
// the vault picker and the Restore dialog. Driven through the real
// VaultPickerScreen over the A0 harness: FakeBackupRunner behind
// `backupRunnerProvider` (call counts, scripted results, a held run), the
// FakeFilePicker for the native pickers, and a recording open controller.
// The backup file is a real temp file (sparse, so its size is real without
// writing 41 MB): `FakeFilePicker.pickFiles` reports size 0, so the dialog
// reads the size from the file itself. Copy and layout are the design pack's
// (`design/315-vault-backups/packs/327.md`); the design wins over the WI.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';
import 'package:path/path.dart' as p;

import '../../support/backup_fakes.dart';
import '../../support/backup_harness.dart';
import '../../support/file_picker_fakes.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_picker_harness.dart';

// ------------------------------------------------------------------ fixtures

/// Requirement 4's file name from board R2.
const _req4Name = 'memex-20261109T140312Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip';

/// Its timestamp (UTC).
final _req4Stamp = DateTime.utc(2026, 11, 9, 14, 3, 12);

/// 41.2 MB, as board R2 draws it.
const _req4Bytes = 41234567;

/// A req 4 name whose timestamp (2027-01-01 03:30:12 UTC) falls on another
/// day, month and year in every zone west of UTC-3:30 (the Americas), so a
/// meta line that shows the UTC date, or drops the year, cannot match there.
const _lateName = 'memex-20270101T033012Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip';
final _lateStamp = DateTime.utc(2027, 1, 1, 3, 30, 12);

/// A name that does not match requirement 4.
const _oldCopyName = 'old copy.zip';
const _oldCopyBytes = 812345;

const _restoreCancelKey = Key('restore-cancel');
const _restoreFileKey = Key('restore-file');
const _restoreMetaKey = Key('restore-meta');
const _restoreTargetKey = Key('restore-target');

const _hint = 'a new vault folder. nothing that exists is changed.';
const _rowHint = 'makes a new vault from a .memex.zip; never writes over one';

const _months = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

// ------------------------------------------------------------------- harness

/// The open controller with every `openVault` recorded; it opens nothing.
class _RecordingOpener extends VaultOpenController {
  _RecordingOpener(super.ref, [this.outcomeFor]);

  /// What an open gives; null opens the vault.
  final VaultOpenOutcome Function(VaultRef)? outcomeFor;

  final List<VaultRef> opened = [];

  @override
  Future<VaultOpenOutcome> openVault(VaultRef vault) async {
    opened.add(vault);
    return outcomeFor?.call(vault) ?? VaultOpened(vault);
  }
}

class _Picker {
  _Picker(this.harness, this.picker, this.file, this.dir, this.opener);

  final BackupHarness harness;
  final FakeFilePicker picker;

  /// The backup file the native picker answers with.
  final String file;

  /// A temp folder for this test (the file's folder; parents go under it).
  final Directory dir;
  final _RecordingOpener Function() opener;

  FakeBackupRunner get runner => harness.runner;
  List<FakeRestoreCall> get restoreCalls => runner.restoreCalls;
  List<VaultRef> get opened => opener().opened;

  /// A real folder under [dir] named [name] (spaces allowed).
  String parent(String name) {
    final d = Directory(p.join(dir.path, name))..createSync(recursive: true);
    return d.path;
  }
}

/// A sparse file of [bytes] at [path].
void _sparseFile(String path, int bytes) {
  final f = File(path).openSync(mode: FileMode.write);
  f.truncateSync(bytes);
  f.closeSync();
}

/// The vault picker under the backup harness, with a backup file
/// [fileName] of [bytes] on disk and the fake native pickers installed.
Future<_Picker> _pumpPicker(
  WidgetTester tester, {
  String fileName = _req4Name,
  int bytes = _req4Bytes,
  double textScale = 1.0,
  Size surfaceSize = const Size(1280, 1100),
  FakeBackupRunner? runner,
  FakeFilePicker? nativePicker,
  VaultOpenOutcome Function(VaultRef)? openOutcome,
}) async {
  final dir = Directory.systemTemp.createTempSync('om327_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = p.join(dir.path, fileName);
  _sparseFile(file, bytes);
  final picker = nativePicker ?? FakeFilePicker();
  FilePicker.platform = picker;
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  _RecordingOpener? opener;
  final harness = await pumpBackupWidget(
    tester,
    const VaultPickerScreen(),
    runner: runner,
    surfaceSize: surfaceSize,
    overrides: [
      vaultOpenControllerProvider.overrideWith(
        (ref) => opener ??= _RecordingOpener(ref, openOutcome),
      ),
    ],
  );
  await _frames(tester);
  return _Picker(harness, picker, file, dir, () {
    // Built on first read; reading it here builds it if the picker has not.
    harness.read(vaultOpenControllerProvider);
    return opener!;
  });
}

/// Lets real I/O (a file stat) and fake-async work land, then draws. Never
/// `pumpAndSettle`: the restoring spinner may repeat.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget, reason: 'the control to press');
  await tester.ensureVisible(f);
  await tester.tap(f, warnIfMissed: false);
  await _frames(tester);
}

/// Picks [s.file] in the native picker and opens the Restore dialog.
Future<void> _openDialog(WidgetTester tester, _Picker s) async {
  s.picker.files.add(s.file);
  await _tap(tester, find.byKey(vaultPickerRestoreKey));
  expect(find.byKey(restoreDialogKey), findsOneWidget);
}

/// Chooses [parent] with the dialog's "choose…".
Future<void> _chooseParent(
  WidgetTester tester,
  _Picker s,
  String parent,
) async {
  s.picker.directories.add(parent);
  await _tap(tester, find.byKey(restoreFolderKey));
}

Future<void> _enterName(WidgetTester tester, String name) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(restoreNameKey),
      matching: find.byType(EditableText),
      matchRoot: true,
    ),
    name,
  );
  await _frames(tester);
}

/// Every text under [of] (itself included).
String _textIn(Finder of) => [
  for (final e
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate())
    (e.widget as RichText).text.toPlainText(),
  for (final e
      in find
          .descendant(
            of: of,
            matching: find.byType(EditableText),
            matchRoot: true,
          )
          .evaluate())
    (e.widget as EditableText).controller.text,
].join(' ');

String _nameValue(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(restoreNameKey),
        matching: find.byType(EditableText),
        matchRoot: true,
      ),
    )
    .controller
    .text;

String _target(WidgetTester tester) =>
    _textIn(find.byKey(_restoreTargetKey)).trim();

String _error() => _textIn(find.byKey(restoreErrorKey)).trim();

/// The border colour of the vault-name field's box.
Color _nameBorder(WidgetTester tester) {
  final box = tester.widget<Container>(
    find
        .ancestor(
          of: find.byKey(restoreNameKey),
          matching: find.byType(Container),
        )
        .first,
  );
  return ((box.decoration! as BoxDecoration).border! as Border).top.color;
}

/// The decoration of the vault-name field's box.
BoxDecoration _nameDecoration(WidgetTester tester) {
  final box = tester.widget<Container>(
    find
        .ancestor(
          of: find.byKey(restoreNameKey),
          matching: find.byType(Container),
        )
        .first,
  );
  return box.decoration! as BoxDecoration;
}

/// The focus ring [key]'s button draws over itself, or null when it draws
/// none.
Border? _buttonRing(WidgetTester tester, Key key) {
  final boxes = find
      .descendant(of: find.byKey(key), matching: find.byType(DecoratedBox))
      .evaluate()
      .map((e) => e.widget as DecoratedBox)
      .where((b) => b.position == DecorationPosition.foreground)
      .toList();
  expect(boxes, hasLength(1), reason: '$key draws one foreground decoration');
  return (boxes.single.decoration as BoxDecoration).border as Border?;
}

/// The semantics node of [key]'s widget.
SemanticsNode _node(WidgetTester tester, Key key) =>
    tester.getSemantics(find.byKey(key));

/// Whether the focus is inside the vault-name field.
bool _nameHasFocus() {
  final focus = FocusManager.instance.primaryFocus;
  final context = focus?.context;
  if (context == null) return false;
  return find
      .descendant(
        of: find.byKey(restoreNameKey),
        matching: find.byWidget(context.widget),
        matchRoot: true,
      )
      .evaluate()
      .isNotEmpty;
}

/// Whether the focus sits on [key]'s box (same place, similar size).
bool _focusIsAt(Key key) {
  final focus = FocusManager.instance.primaryFocus;
  if (focus == null || focus.context == null) return false;
  final target = find.byKey(key).evaluate().single.renderObject! as RenderBox;
  final box = target.localToGlobal(Offset.zero) & target.size;
  final r = focus.rect;
  final a = r.width * r.height;
  final b = box.width * box.height;
  return r.overlaps(box) && a <= 4 * b && b <= 4 * a;
}

/// The OmButton at or under [key].
OmButton _button(WidgetTester tester, Key key) {
  final w = tester.widget(find.byKey(key));
  if (w is OmButton) return w;
  return tester.widget<OmButton>(
    find.descendant(of: find.byKey(key), matching: find.byType(OmButton)).first,
  );
}

/// The exact meta line for [bytes] and [stamp] (lead ruling Q1): "41.2 MB ·
/// made 9 nov 2026 at 07:03", the year always shown, the date and time of the
/// stamp in local time. Built here from [DateTime.toLocal], never from the
/// production formatter.
RegExp _metaPattern(int bytes, DateTime stamp) {
  final local = stamp.toLocal();
  final hhmm =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  return RegExp(
    '^${RegExp.escape(backupSize(bytes))} · made ${local.day} '
    '${_months[local.month - 1]} ${local.year} at $hhmm\$',
  );
}

/// A [FakeFilePicker] that also records the filter `pickFiles` was asked for,
/// reports [reportedSize] as the picked file's size (the real picker reports
/// the file's size; the base fake reports 0), and can hold either picker open.
class _RecordingPicker extends FakeFilePicker {
  final List<(FileType, List<String>?)> filters = [];
  int reportedSize = 0;
  Completer<void>? holdPick;
  Completer<void>? holdDirectory;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    filters.add((type, allowedExtensions));
    final hold = holdPick;
    if (hold != null) await hold.future;
    final result = await super.pickFiles(dialogTitle: dialogTitle);
    final f = result?.files.single;
    if (f == null) return null;
    return FilePickerResult([
      PlatformFile(path: f.path, name: f.name, size: reportedSize),
    ]);
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    final hold = holdDirectory;
    if (hold != null) await hold.future;
    return super.getDirectoryPath(dialogTitle: dialogTitle);
  }
}

/// A runner whose `restore` throws, the way a bug in the runner would.
class _ThrowingRunner extends FakeBackupRunner {
  @override
  Future<RestoreRunResult> restore({
    required String from,
    required String to,
  }) async {
    calls.add(FakeRestoreCall(from: from, to: to));
    throw StateError('the runner blew up');
  }
}

// ----------------------------------------------------------------- semantics

/// The semantics nodes inside [key]'s box (global rects, 2 px slack).
List<SemanticsNode> _semanticsAt(WidgetTester tester, Key key) {
  final box = tester.getRect(find.byKey(key)).inflate(2);
  var root = tester.getSemantics(find.byKey(restoreDialogKey));
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

/// Tabs until the focused node is [key]'s box (same place, similar size).
Future<void> _tabTo(WidgetTester tester, Key key) async {
  final target = tester.getRect(find.byKey(key));
  for (var i = 0; i < 40; i++) {
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

/// No paragraph under [scope] is cut: none exceeds its max lines and none is
/// laid out shorter than its text needs. [exempt] texts are the designed
/// one-line ellipses (the file name, the parent path).
void _expectNothingClipped(
  WidgetTester tester,
  Finder scope,
  String state, {
  Set<String> exempt = const {},
}) {
  expect(tester.takeException(), isNull, reason: '$state: no overflow');
  final paragraphs = find
      .descendant(of: scope, matching: find.byType(RichText))
      .evaluate();
  expect(paragraphs, isNotEmpty, reason: '$state: text to check');
  for (final e in paragraphs) {
    final para = e.renderObject! as RenderParagraph;
    final text = para.text.toPlainText();
    if (exempt.contains(text.trim())) continue;
    expect(para.didExceedMaxLines, isFalse, reason: '$state: "$text" is cut');
    expect(
      para.size.height + 0.5,
      greaterThanOrEqualTo(para.getMinIntrinsicHeight(para.size.width)),
      reason: '$state: "$text" is laid out shorter than its lines',
    );
  }
}

// --------------------------------------------------------------------- tests

void main() {
  holdFontFetches();

  // ==================================================================== AC1
  group('AC1 the picker row', () {
    testWidgets(
      'the picker shows vault-picker-restore in a BACKUP row under the create action',
      (tester) async {
        await _pumpPicker(tester);

        final restore = find.byKey(vaultPickerRestoreKey);
        expect(restore, findsOneWidget);
        expect(
          find.descendant(
            of: restore,
            matching: find.text('restore from backup…'),
          ),
          findsOneWidget,
        );
        expect(find.text('BACKUP'), findsOneWidget);
        expect(find.text(_rowHint), findsOneWidget);
        // Its own row, after the VAULT SERVER row, in the create column.
        final create = tester.getRect(
          find.byKey(const Key('vault-picker-create')),
        );
        final server = tester.getRect(
          find.byKey(const Key('vault-picker-open-on-server')),
        );
        final r = tester.getRect(restore);
        expect(r.left, moreOrLessEquals(create.left, epsilon: 0.5));
        expect(r.width, moreOrLessEquals(create.width, epsilon: 0.5));
        expect(r.top, greaterThanOrEqualTo(server.bottom));
        expect(
          tester.getRect(find.text('BACKUP')).left,
          moreOrLessEquals(tester.getRect(find.text('THIS MAC')).left),
        );
        // The right cell is text, not a button.
        expect(
          find.ancestor(
            of: find.text(_rowHint),
            matching: find.byType(OmButton),
          ),
          findsNothing,
        );
        expect(_button(tester, vaultPickerRestoreKey).onPressed, isNotNull);
      },
    );

    testWidgets(
      'restore from backup is disabled with the other local actions when the binary is not found',
      (tester) async {
        await pumpVaultPicker(tester, savedServers: const [], binary: false);

        expect(find.byKey(vaultPickerRestoreKey), findsOneWidget);
        expect(wi97ButtonIn(tester, 'vault-picker-restore').onPressed, isNull);
        expect(wi97ButtonIn(tester, 'vault-picker-create').onPressed, isNull);
      },
    );
  });

  // ==================================================================== AC2
  group('AC2 cancel the file picker', () {
    testWidgets(
      'cancelling the file picker makes 0 restore calls and opens no dialog',
      (tester) async {
        final s = await _pumpPicker(tester);

        await _tap(tester, find.byKey(vaultPickerRestoreKey));

        expect(s.picker.calls.map((c) => c.method), ['pickFiles']);
        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.restoreCalls, isEmpty);
        expect(s.opened, isEmpty);
      },
    );
  });

  // ==================================================================== AC3
  group('AC3 the dialog shows the backup', () {
    testWidgets(
      'picking a requirement 4 backup opens the dialog prefilled from its label with its name size and date',
      (tester) async {
        final s = await _pumpPicker(tester);

        await _openDialog(tester, s);

        expect(
          find.descendant(
            of: find.byKey(restoreDialogKey),
            matching: find.text('RESTORE FROM BACKUP'),
          ),
          findsOneWidget,
        );
        expect(_nameValue(tester), 'memex');
        expect(_textIn(find.byKey(_restoreFileKey)), contains(_req4Name));
        expect(
          _textIn(find.byKey(_restoreMetaKey)).trim(),
          matches(_metaPattern(_req4Bytes, _req4Stamp)),
        );
        expect(find.text(_hint), findsOneWidget);
        expect(find.byKey(restoreErrorKey), findsNothing);
        expect(s.restoreCalls, isEmpty);
      },
    );

    testWidgets(
      'the meta date is the file name timestamp in local time not the file time',
      (tester) async {
        final s = await _pumpPicker(tester, fileName: _lateName);
        // A file time far from the name's timestamp.
        File(s.file).setLastModifiedSync(DateTime(2020, 1, 2, 3, 4));

        await _openDialog(tester, s);

        final meta = _textIn(find.byKey(_restoreMetaKey)).trim();
        expect(meta, matches(_metaPattern(_req4Bytes, _lateStamp)));
        expect(meta, isNot(contains('2 jan')));
        // Always an absolute date with its year.
        expect(meta, matches(RegExp(r' made \d{1,2} [a-z]{3} \d{4} at ')));
      },
    );

    testWidgets(
      'a non matching old copy.zip prefills old copy and the meta line shows the size only',
      (tester) async {
        final s = await _pumpPicker(
          tester,
          fileName: _oldCopyName,
          bytes: _oldCopyBytes,
        );

        await _openDialog(tester, s);

        expect(_nameValue(tester), 'old copy');
        expect(_textIn(find.byKey(_restoreFileKey)), contains(_oldCopyName));
        expect(
          _textIn(find.byKey(_restoreMetaKey)).trim(),
          backupSize(_oldCopyBytes),
        );
      },
    );
  });

  // ==================================================================== AC4
  group('AC4 the parent folder', () {
    testWidgets(
      'choosing a parent folder updates will be restored to parent and name',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final home = Platform.environment['HOME']!;
        expect(_target(tester), p.join(home, 'Documents', 'memex'));

        final parent = s.parent('restored vaults');
        await _chooseParent(tester, s, parent);

        expect(s.picker.calls.map((c) => c.method), [
          'pickFiles',
          'getDirectoryPath',
        ]);
        expect(_target(tester), p.join(parent, 'memex'));
        expect(find.text(parent), findsOneWidget);

        // The name feeds the same line, trimmed.
        await _enterName(tester, '  work  ');
        expect(_target(tester), p.join(parent, 'work'));

        // A cancelled folder picker keeps the parent.
        await _tap(tester, find.byKey(restoreFolderKey));
        expect(_target(tester), p.join(parent, 'work'));
        expect(s.restoreCalls, isEmpty);
      },
    );
  });

  // ==================================================================== AC5
  group('AC5 cancel the dialog', () {
    testWidgets('cancelling the dialog makes 0 restore calls', (tester) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      await _chooseParent(tester, s, s.parent('parent'));

      await _tap(tester, find.byKey(_restoreCancelKey));

      expect(find.byKey(restoreDialogKey), findsNothing);
      expect(s.restoreCalls, isEmpty);
      expect(s.opened, isEmpty);
    });

    testWidgets(
      'cancelling the dialog after a failure makes no further calls and opens nothing',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        s.runner.scriptRestore(
          const RestoreFailure(code: 'backup_invalid', message: 'bad zip'),
        );
        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(s.restoreCalls, hasLength(1));

        await _tap(tester, find.byKey(_restoreCancelKey));

        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, isEmpty);
      },
    );
  });

  // ==================================================================== AC6
  group('AC6 failures keep the dialog open', () {
    final cases =
        <
          (
            String,
            RestoreRunResult Function(String parent),
            String Function(String parent),
          )
        >[
          (
            'a failed restore with restore_target_not_empty makes exactly 1 call per press and keeps the dialog open with its message',
            (parent) => RestoreFailure(
              code: 'restore_target_not_empty',
              message: 'restore target is not empty',
              fields: {'path': p.join(parent, 'memex')},
            ),
            (parent) =>
                "a folder named memex already exists in $parent and isn't "
                'empty. choose another name or folder.',
          ),
          (
            'a failed restore with backup_invalid makes exactly 1 call per press and keeps the dialog open with its message',
            (_) => const RestoreFailure(
              code: 'backup_invalid',
              message: 'not a backup',
            ),
            (_) =>
                "this file isn't an open memex backup, or it's damaged. "
                'nothing was written.',
          ),
          (
            'a failed restore with backup_too_new makes exactly 1 call per press and names both schema versions',
            (_) => const RestoreFailure(
              code: 'backup_too_new',
              message:
                  'backup too new: it holds schema V7; this memex supports V6',
              fields: {'schema_version': 7, 'supported_schema_version': 6},
            ),
            (_) =>
                'this backup was made by a newer memex (schema V7; this memex '
                'supports V6). update memex, then try again.',
          ),
          (
            'a failed restore with network_filesystem makes exactly 1 call per press and keeps the dialog open with its message',
            (_) => const RestoreFailure(
              code: 'network_filesystem',
              message: 'the folder is on a network filesystem',
            ),
            (_) =>
                'this folder is on a network drive. vaults on network drives '
                'can be corrupted — connect to a vault server instead.',
          ),
          (
            'a failed restore with a too old memex makes exactly 1 call per press and keeps the dialog open with its message',
            (_) => const RestoreTooOld(),
            (_) =>
                'this memex is too old to open vaults safely. update memex, '
                'then try again.',
          ),
          (
            'a failed restore with the binary not found makes exactly 1 call per press and keeps the dialog open with its message',
            (_) => const RestoreBinaryNotFound(),
            (_) =>
                'memex binary not found. install memex, or locate it, then '
                'try again.',
          ),
          (
            'a failed restore with any other code makes exactly 1 call per press and shows the raw message',
            (_) => const RestoreFailure(code: 'internal', message: 'disk full'),
            (_) => "the backup couldn't be restored: disk full.",
          ),
        ];
    for (final (name, result, message) in cases) {
      testWidgets(name, (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent folder');
        await _chooseParent(tester, s, parent);
        final target = p.join(parent, 'memex');
        s.runner
          ..scriptRestore(result(parent))
          ..scriptRestore(result(parent));

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(1));
        expect(s.restoreCalls.single.from, s.file);
        expect(s.restoreCalls.single.to, target);
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(find.byKey(restoreErrorKey), findsOneWidget);
        expect(_error(), message(parent));
        // The error replaces the meta line and the target block (R4-R7).
        expect(find.byKey(_restoreMetaKey), findsNothing);
        expect(find.byKey(_restoreTargetKey), findsNothing);
        expect(find.text(_hint), findsNothing);
        expect(s.opened, isEmpty);
        // The button is usable again: another press is one more call.
        expect(_button(tester, restoreSubmitKey).onPressed, isNotNull);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(2));
        expect(s.restoreCalls.last.to, target);
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(_error(), message(parent));
        expect(s.opened, isEmpty);
      });
    }

    testWidgets(
      'after a failure a new name clears the error and the next press restores there',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);
        s.runner.scriptRestore(
          const RestoreFailure(
            code: 'restore_target_not_empty',
            message: 'restore target is not empty',
          ),
        );
        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(find.byKey(restoreErrorKey), findsOneWidget);

        await _enterName(tester, 'memex-restored');

        expect(find.byKey(restoreErrorKey), findsNothing);
        expect(
          _textIn(find.byKey(_restoreMetaKey)).trim(),
          matches(_metaPattern(_req4Bytes, _req4Stamp)),
        );
        expect(_target(tester), p.join(parent, 'memex-restored'));

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls.map((c) => c.to), [
          p.join(parent, 'memex'),
          p.join(parent, 'memex-restored'),
        ]);
        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.opened, [LocalVaultRef(p.join(parent, 'memex-restored'))]);
      },
    );

    testWidgets(
      'after a failure a new parent folder clears the error and names it in the next message',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final first = s.parent('first');
        final second = s.parent('second');
        await _chooseParent(tester, s, first);
        const notEmpty = RestoreFailure(
          code: 'restore_target_not_empty',
          message: 'restore target is not empty',
        );
        s.runner
          ..scriptRestore(notEmpty)
          ..scriptRestore(notEmpty);
        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(_error(), contains(' in $first '));

        await _chooseParent(tester, s, second);

        expect(find.byKey(restoreErrorKey), findsNothing);
        expect(_target(tester), p.join(second, 'memex'));

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls.last.to, p.join(second, 'memex'));
        expect(
          _error(),
          "a folder named memex already exists in $second and isn't empty. "
          'choose another name or folder.',
        );
      },
    );
  });

  // ==================================================================== AC7
  group('AC7 while restoring', () {
    testWidgets(
      'while restoring restore-submit is disabled and a second press makes 0 calls',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);
        final hold = s.runner.holdRuns();

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(1));
        expect(s.runner.inFlight, 1);
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(_button(tester, restoreSubmitKey).onPressed, isNull);
        expect(
          find.descendant(
            of: find.byKey(restoreSubmitKey),
            matching: find.text('restoring…'),
          ),
          findsOneWidget,
        );
        expect(_button(tester, _restoreCancelKey).onPressed, isNull);
        expect(_button(tester, restoreFolderKey).onPressed, isNull);
        final field = tester.widget<TextField>(find.byKey(restoreNameKey));
        expect(
          field.enabled == false || field.readOnly,
          isTrue,
          reason: 'the name field is not editable while restoring',
        );
        // R3: the meta line and the target stay; the hint goes.
        expect(
          _textIn(find.byKey(_restoreMetaKey)).trim(),
          matches(_metaPattern(_req4Bytes, _req4Stamp)),
        );
        expect(_target(tester), p.join(parent, 'memex'));
        expect(find.text(_hint), findsNothing);

        await _tap(tester, find.byKey(restoreSubmitKey));
        await _tap(tester, find.byKey(restoreFolderKey));
        await _tap(tester, find.byKey(_restoreCancelKey));

        expect(s.restoreCalls, hasLength(1));
        expect(
          s.picker.calls.where((c) => c.method == 'getDirectoryPath'),
          hasLength(1),
        );
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(s.opened, isEmpty);

        hold.complete();
        await _frames(tester);

        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, [LocalVaultRef(p.join(parent, 'memex'))]);
      },
    );

    testWidgets(
      'escape and a barrier tap while restoring leave the dialog open until the run ends',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);
        final hold = s.runner.holdRuns();
        await _tap(tester, find.byKey(restoreSubmitKey));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        await tester.tapAt(const Offset(4, 4));
        await _frames(tester);
        expect(find.byKey(restoreDialogKey), findsOneWidget);

        // The held run answers with the default result (success).
        hold.complete();
        await _frames(tester);

        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, [LocalVaultRef(p.join(parent, 'memex'))]);
      },
    );

    testWidgets(
      'a held run that fails re-enables the dialog with the error and makes no extra call',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        s.runner.scriptRestore(
          const RestoreFailure(code: 'backup_invalid', message: 'bad'),
        );
        final hold = s.runner.holdRuns();
        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(_button(tester, restoreSubmitKey).onPressed, isNull);

        hold.complete();
        await _frames(tester);

        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(find.byKey(restoreErrorKey), findsOneWidget);
        expect(_button(tester, restoreSubmitKey).onPressed, isNotNull);
        expect(_button(tester, _restoreCancelKey).onPressed, isNotNull);
        expect(_button(tester, restoreFolderKey).onPressed, isNotNull);
        expect(
          find.descendant(
            of: find.byKey(restoreSubmitKey),
            matching: find.text('restore'),
          ),
          findsOneWidget,
        );
        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, isEmpty);
      },
    );
  });

  // ==================================================================== AC8
  group('AC8 success', () {
    testWidgets(
      'success closes the dialog and opens exactly 1 LocalVaultRef at the parent with a space and the name',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('my backups');
        await _chooseParent(tester, s, parent);

        await _tap(tester, find.byKey(restoreSubmitKey));

        final target = p.join(parent, 'memex');
        expect(s.restoreCalls, hasLength(1));
        expect(s.restoreCalls.single.from, s.file);
        expect(s.restoreCalls.single.to, target);
        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.opened, [LocalVaultRef(target)]);
      },
    );

    testWidgets('the restore runs with the trimmed name', (tester) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      final parent = s.parent('parent');
      await _chooseParent(tester, s, parent);
      await _enterName(tester, '  photos-2025  ');

      await _tap(tester, find.byKey(restoreSubmitKey));

      expect(s.restoreCalls.single.to, p.join(parent, 'photos-2025'));
      expect(s.opened, [LocalVaultRef(p.join(parent, 'photos-2025'))]);
    });
  });

  // ==================================================================== AC9
  group('AC9 semantics, keyboard and text errors', () {
    final invalid = <(String, String, String)>[
      (
        'an empty name shows its error as text and makes 0 restore calls',
        '   ',
        "vault name can't be empty.",
      ),
      (
        'a name with a slash shows its error as text and makes 0 restore calls',
        'a/b',
        'vault name can\'t contain "/" or "..".',
      ),
      (
        'a name with two dots shows its error as text and makes 0 restore calls',
        '..',
        'vault name can\'t contain "/" or "..".',
      ),
    ];
    for (final (name, value, message) in invalid) {
      testWidgets(name, (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        await _enterName(tester, value);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, isEmpty);
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(_error(), message);
        expect(s.opened, isEmpty);
      });
    }

    testWidgets('every dialog control has a semantic label', (tester) async {
      final handle = tester.ensureSemantics();
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      await tester.pump();

      for (final (key, label) in const [
        (restoreNameKey, 'vault name'),
        (restoreFolderKey, 'choose'),
        (_restoreCancelKey, 'cancel'),
        (restoreSubmitKey, 'restore'),
      ]) {
        final labelled = _semanticsAt(
          tester,
          key,
        ).where((n) => n.label.toLowerCase().contains(label)).toList();
        expect(labelled, isNotEmpty, reason: '$key has a label "$label"');
        final actionable = labelled.where((n) {
          final d = n.getSemanticsData();
          return d.hasAction(SemanticsAction.tap) ||
              d.hasAction(SemanticsAction.focus) ||
              d.flagsCollection.isTextField;
        });
        expect(actionable, isNotEmpty, reason: '$key is actionable');
      }
      handle.dispose();
    });

    testWidgets(
      'the error is announced as a live region and restoring is labelled',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        s.runner.scriptRestore(
          const RestoreFailure(code: 'backup_invalid', message: 'bad'),
        );
        await _tap(tester, find.byKey(restoreSubmitKey));

        final error = _semanticsAt(tester, restoreErrorKey).where(
          (n) => n.label.contains("this file isn't an open memex backup"),
        );
        expect(error, isNotEmpty);
        // The live region may sit on the error box around the text.
        var live = false;
        for (final n in error) {
          for (SemanticsNode? m = n; m != null; m = m.parent) {
            if (m.getSemanticsData().flagsCollection.isLiveRegion) live = true;
          }
        }
        expect(live, isTrue, reason: 'the error is a live region');

        s.runner.holdRuns();
        await _tap(tester, find.byKey(restoreSubmitKey));
        final busy = _semanticsAt(
          tester,
          restoreSubmitKey,
        ).where((n) => n.label.contains('restoring'));
        expect(busy, isNotEmpty);
        expect(
          busy.any((n) => n.getSemanticsData().hasAction(SemanticsAction.tap)),
          isFalse,
        );
        handle.dispose();
      },
    );

    testWidgets('the name field has focus when the dialog opens', (
      tester,
    ) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);

      final focus = FocusManager.instance.primaryFocus;
      expect(focus?.context, isNotNull);
      expect(
        find
            .descendant(
              of: find.byKey(restoreNameKey),
              matching: find.byWidget(focus!.context!.widget),
              matchRoot: true,
            )
            .evaluate(),
        isNotEmpty,
      );
    });

    testWidgets('return in the name field presses restore', (tester) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      final parent = s.parent('parent');
      await _chooseParent(tester, s, parent);
      await tester.showKeyboard(
        find.descendant(
          of: find.byKey(restoreNameKey),
          matching: find.byType(EditableText),
          matchRoot: true,
        ),
      );

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _frames(tester);

      expect(s.restoreCalls.single.to, p.join(parent, 'memex'));
      expect(s.opened, [LocalVaultRef(p.join(parent, 'memex'))]);
    });

    testWidgets('a target not empty error puts focus back in the name field', (
      tester,
    ) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      await _chooseParent(tester, s, s.parent('parent'));
      await _tabTo(tester, restoreSubmitKey);
      s.runner.scriptRestore(
        const RestoreFailure(
          code: 'restore_target_not_empty',
          message: 'not empty',
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _frames(tester);

      expect(find.byKey(restoreErrorKey), findsOneWidget);
      final focus = FocusManager.instance.primaryFocus;
      expect(
        find
            .descendant(
              of: find.byKey(restoreNameKey),
              matching: find.byWidget(focus!.context!.widget),
              matchRoot: true,
            )
            .evaluate(),
        isNotEmpty,
      );
    });

    final keys = <(String, String, String, LogicalKeyboardKey)>[
      (
        'choose works from the keyboard with enter',
        'restore works from the keyboard with enter',
        'cancel works from the keyboard with enter',
        LogicalKeyboardKey.enter,
      ),
      (
        'choose works from the keyboard with space',
        'restore works from the keyboard with space',
        'cancel works from the keyboard with space',
        LogicalKeyboardKey.space,
      ),
    ];
    for (final (chooseName, submitName, cancelName, key) in keys) {
      testWidgets(chooseName, (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        s.picker.directories.add(parent);

        await _tabTo(tester, restoreFolderKey);
        await tester.sendKeyEvent(key);
        await _frames(tester);

        expect(_target(tester), p.join(parent, 'memex'));
      });

      testWidgets(submitName, (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);

        await _tabTo(tester, restoreSubmitKey);
        await tester.sendKeyEvent(key);
        await _frames(tester);

        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, [LocalVaultRef(p.join(parent, 'memex'))]);
      });

      testWidgets(cancelName, (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);

        await _tabTo(tester, _restoreCancelKey);
        await tester.sendKeyEvent(key);
        await _frames(tester);

        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.restoreCalls, isEmpty);
      });
    }

    testWidgets('escape closes the dialog with 0 restore calls', (
      tester,
    ) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);

      expect(find.byKey(restoreDialogKey), findsNothing);
      expect(s.restoreCalls, isEmpty);
      expect(s.opened, isEmpty);
    });
  });

  // =================================================================== AC10
  group('AC10 large text', () {
    testWidgets('at 1.3x text the dialog clips nothing in any state', (
      tester,
    ) async {
      final s = await _pumpPicker(tester, textScale: 1.3);
      await _openDialog(tester, s);
      final parent = s.parent('a parent folder with a fairly long name');
      await _chooseParent(tester, s, parent);
      final dialog = find.byKey(restoreDialogKey);
      final exempt = {_req4Name, parent};

      _expectNothingClipped(tester, dialog, 'open', exempt: exempt);

      s.runner.scriptRestore(
        const RestoreFailure(
          code: 'backup_too_new',
          message: 'too new',
          fields: {'schema_version': 7, 'supported_schema_version': 6},
        ),
      );
      await _tap(tester, find.byKey(restoreSubmitKey));
      expect(find.byKey(restoreErrorKey), findsOneWidget);
      _expectNothingClipped(tester, dialog, 'backup_too_new', exempt: exempt);

      await _enterName(tester, 'memex');
      s.runner.holdRuns();
      await _tap(tester, find.byKey(restoreSubmitKey));
      expect(_button(tester, restoreSubmitKey).onPressed, isNull);
      _expectNothingClipped(tester, dialog, 'restoring', exempt: exempt);
    });

    testWidgets('at 1.3x text the picker restore row clips nothing', (
      tester,
    ) async {
      await _pumpPicker(tester, textScale: 1.3);

      final hint = find.text(_rowHint);
      expect(hint, findsOneWidget);
      _expectNothingClipped(tester, hint, 'picker row');
    });
  });

  group('AC6 the message names what was tried', () {
    testWidgets(
      'a target not empty message names the trimmed name that was tried',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('my backups');
        await _chooseParent(tester, s, parent);
        await _enterName(tester, '  photos  ');
        s.runner.scriptRestore(
          const RestoreFailure(
            code: 'restore_target_not_empty',
            message: 'restore target is not empty',
          ),
        );

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls.single.to, p.join(parent, 'photos'));
        expect(
          _error(),
          "a folder named photos already exists in $parent and isn't empty. "
          'choose another name or folder.',
        );
      },
    );
  });

  // ===================================================== open after restore
  // Review r1: the restore succeeded and the open of the restored folder
  // failed. The picker must show what the open gave, under the open eyebrow.
  group('the open after a successful restore', () {
    testWidgets(
      'a restored folder on a network drive shows the refusal under the open eyebrow',
      (tester) async {
        late String target;
        final s = await _pumpPicker(
          tester,
          openOutcome: (_) => VaultOnNetworkDrive(target, 'on a network drive'),
        );
        await _openDialog(tester, s);
        final parent = s.parent('my backups');
        target = p.join(parent, 'memex');
        await _chooseParent(tester, s, parent);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(1));
        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.opened, [LocalVaultRef(target)]);
        final refusal = find.byKey(const Key('network-drive-refusal'));
        expect(refusal, findsOneWidget);
        expect(
          find.descendant(of: refusal, matching: find.text('OPEN LOCAL VAULT')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: refusal, matching: find.text('CREATE NEW VAULT')),
          findsNothing,
        );
        expect(
          find.descendant(of: refusal, matching: find.text(target)),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a restored folder that fails to open shows the open error in a snackbar',
      (tester) async {
        final s = await _pumpPicker(
          tester,
          openOutcome: (_) => const VaultOpenFailure('could not open it.'),
        );
        await _openDialog(tester, s);
        final parent = s.parent('my backups');
        await _chooseParent(tester, s, parent);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(1));
        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.opened, [LocalVaultRef(p.join(parent, 'memex'))]);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.text('could not open it.'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a restored folder that opens shows no error', (tester) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      await _chooseParent(tester, s, s.parent('my backups'));

      await _tap(tester, find.byKey(restoreSubmitKey));

      expect(s.opened, hasLength(1));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(const Key('network-drive-refusal')), findsNothing);
    });
  });

  // ===================================================== verify-mode additions
  // Sites the handoff listed as untested: the picker flow, the thrown-runner
  // catch, the mounted guards, the refocus and the target block.
  group('picker flow', () {
    testWidgets('the file picker is asked for zip files only', (tester) async {
      final picker = _RecordingPicker();
      final s = await _pumpPicker(tester, nativePicker: picker);
      picker.files.add(s.file);

      await _tap(tester, find.byKey(vaultPickerRestoreKey));

      expect(picker.filters, hasLength(1));
      expect(picker.filters.single.$1, FileType.custom);
      expect(picker.filters.single.$2, ['zip']);
    });

    testWidgets(
      'the dialog reads the size from the file and ignores the size the picker reports',
      (tester) async {
        final picker = _RecordingPicker()..reportedSize = 7;
        final s = await _pumpPicker(tester, nativePicker: picker);

        await _openDialog(tester, s);

        expect(
          _textIn(find.byKey(_restoreMetaKey)).trim(),
          matches(_metaPattern(_req4Bytes, _req4Stamp)),
        );
      },
    );

    testWidgets(
      'a file whose size cannot be read shows the size the picker reports',
      (tester) async {
        final picker = _RecordingPicker()..reportedSize = _oldCopyBytes;
        final s = await _pumpPicker(tester, nativePicker: picker);
        File(s.file).deleteSync();

        await _openDialog(tester, s);

        expect(
          _textIn(find.byKey(_restoreMetaKey)).trim(),
          matches(_metaPattern(_oldCopyBytes, _req4Stamp)),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a picker answered after the screen is gone opens no dialog and runs no restore',
      (tester) async {
        final picker = _RecordingPicker()..holdPick = Completer<void>();
        final s = await _pumpPicker(tester, nativePicker: picker);
        picker.files.add(s.file);
        await _tap(tester, find.byKey(vaultPickerRestoreKey));
        await tester.pumpWidget(const SizedBox());

        picker.holdPick!.complete();
        await _frames(tester);

        expect(tester.takeException(), isNull);
        expect(find.byKey(restoreDialogKey), findsNothing);
        expect(s.restoreCalls, isEmpty);
        expect(s.opened, isEmpty);
      },
    );
  });

  group('the run and the dialog going away', () {
    testWidgets(
      'a runner that throws ends the run with its message and the next press runs again',
      (tester) async {
        final runner = _ThrowingRunner();
        final s = await _pumpPicker(tester, runner: runner);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(1));
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(_error(), contains('the runner blew up'));
        expect(_button(tester, restoreSubmitKey).onPressed, isNotNull);
        expect(_button(tester, _restoreCancelKey).onPressed, isNotNull);
        expect(s.opened, isEmpty);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls, hasLength(2));
        expect(find.byKey(restoreDialogKey), findsOneWidget);
        expect(s.opened, isEmpty);
      },
    );

    final answers = <(String, RestoreRunResult?)>[
      (
        'a run that succeeds after the screen is gone ends quietly and opens nothing',
        null,
      ),
      (
        'a run that fails after the screen is gone ends quietly and opens nothing',
        const RestoreFailure(code: 'backup_invalid', message: 'bad'),
      ),
    ];
    for (final (name, answer) in answers) {
      testWidgets(name, (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        if (answer != null) s.runner.scriptRestore(answer);
        final hold = s.runner.holdRuns();
        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(s.restoreCalls, hasLength(1));
        await tester.pumpWidget(const SizedBox());

        hold.complete();
        await _frames(tester);

        expect(tester.takeException(), isNull);
        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, isEmpty);
      });
    }

    testWidgets(
      'a parent folder answered after the dialog closed changes nothing',
      (tester) async {
        final picker = _RecordingPicker()..holdDirectory = Completer<void>();
        final s = await _pumpPicker(tester, nativePicker: picker);
        await _openDialog(tester, s);
        picker.directories.add(s.parent('late'));
        await _tap(tester, find.byKey(restoreFolderKey));
        await _tap(tester, find.byKey(_restoreCancelKey));
        expect(find.byKey(restoreDialogKey), findsNothing);

        picker.holdDirectory!.complete();
        await _frames(tester);

        expect(tester.takeException(), isNull);
        expect(s.restoreCalls, isEmpty);
        expect(s.opened, isEmpty);
      },
    );

    testWidgets(
      'a cancelled parent folder picker keeps the parent and the error',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);
        s.runner.scriptRestore(
          const RestoreFailure(
            code: 'restore_target_not_empty',
            message: 'not empty',
          ),
        );
        await _tap(tester, find.byKey(restoreSubmitKey));
        final message = _error();
        expect(message, contains(parent));

        // The queue is empty: the native dialog is cancelled.
        await _tap(tester, find.byKey(restoreFolderKey));

        expect(
          s.picker.calls.where((c) => c.method == 'getDirectoryPath'),
          hasLength(2),
        );
        expect(_error(), message);
        expect(find.text(parent), findsOneWidget);
        expect(find.text('(none selected)'), findsNothing);

        await _tap(tester, find.byKey(restoreSubmitKey));

        expect(s.restoreCalls.last.to, p.join(parent, 'memex'));
      },
    );
  });

  group('the name field, the target and the focus', () {
    testWidgets('an empty name hides the target and its hint', (tester) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      await _chooseParent(tester, s, s.parent('parent'));
      expect(find.byKey(_restoreTargetKey), findsOneWidget);
      expect(find.text('will be restored to'), findsOneWidget);
      expect(find.text(_hint), findsOneWidget);

      await _enterName(tester, '   ');

      expect(find.byKey(_restoreTargetKey), findsNothing);
      expect(find.text('will be restored to'), findsNothing);
      expect(find.text(_hint), findsNothing);
      expect(find.byKey(restoreErrorKey), findsNothing);
    });

    testWidgets(
      'a name error puts focus back in the name field and marks it with the danger border until the name changes',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        await _enterName(tester, 'a/b');
        expect(_nameBorder(tester), isNot(OmColors.danger));
        await _tabTo(tester, restoreSubmitKey);
        expect(_nameHasFocus(), isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);

        expect(find.byKey(restoreErrorKey), findsOneWidget);
        expect(s.restoreCalls, isEmpty);
        expect(_nameHasFocus(), isTrue);
        expect(_nameBorder(tester), OmColors.danger);

        await _enterName(tester, 'ab');

        expect(find.byKey(restoreErrorKey), findsNothing);
        expect(_nameBorder(tester), isNot(OmColors.danger));
      },
    );

    testWidgets(
      'a target not empty error marks the name field and a backup invalid error does not',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        s.runner
          ..scriptRestore(
            const RestoreFailure(
              code: 'restore_target_not_empty',
              message: 'not empty',
            ),
          )
          ..scriptRestore(
            const RestoreFailure(code: 'backup_invalid', message: 'bad'),
          );

        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(_nameBorder(tester), OmColors.danger);

        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(_error(), contains('damaged'));
        expect(_nameBorder(tester), isNot(OmColors.danger));
      },
    );

    testWidgets(
      'a failure that is not about the name leaves the focus on restore',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        await _tabTo(tester, restoreSubmitKey);
        s.runner.scriptRestore(
          const RestoreFailure(code: 'backup_invalid', message: 'bad'),
        );
        final hold = s.runner.holdRuns();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);

        // Restoring: the disabled button keeps its focus.
        expect(_button(tester, restoreSubmitKey).onPressed, isNull);
        expect(_focusIsAt(restoreSubmitKey), isTrue);

        hold.complete();
        await _frames(tester);

        expect(find.byKey(restoreErrorKey), findsOneWidget);
        expect(_button(tester, restoreSubmitKey).onPressed, isNotNull);
        expect(_focusIsAt(restoreSubmitKey), isTrue);
        expect(_nameHasFocus(), isFalse);
      },
    );

    testWidgets(
      'return in the name field and enter on restore while restoring make no second call',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        final parent = s.parent('parent');
        await _chooseParent(tester, s, parent);
        await _tabTo(tester, restoreSubmitKey);
        final hold = s.runner.holdRuns();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);
        expect(s.restoreCalls, hasLength(1));

        // Enter again on the disabled button, then Return in the field.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);
        tester.widget<TextField>(find.byKey(restoreNameKey)).onSubmitted!(
          'memex',
        );
        await _frames(tester);

        expect(s.restoreCalls, hasLength(1));
        expect(s.runner.inFlight, 1);

        hold.complete();
        await _frames(tester);

        expect(s.restoreCalls, hasLength(1));
        expect(s.opened, [LocalVaultRef(p.join(parent, 'memex'))]);
      },
    );
  });

  // ========================================= gate mutants: states and semantics
  group('the name field, the buttons and the error as a person sees them', () {
    testWidgets('a fresh dialog shows the name field focused and in no error', (
      tester,
    ) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);

      final d = _nameDecoration(tester);
      expect((d.border! as Border).top.color, OmColors.accentSoft);
      expect(d.boxShadow, hasLength(1));
      expect(d.boxShadow!.single.color, OmColors.accentGlow);
      expect(_nameHasFocus(), isTrue);
      expect(find.byKey(restoreErrorKey), findsNothing);
    });

    testWidgets(
      'an empty name marks the name field with the danger border and ring and focuses it',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        await _enterName(tester, '   ');
        await _tabTo(tester, restoreSubmitKey);
        expect(_nameHasFocus(), isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _frames(tester);

        expect(_error(), "vault name can't be empty.");
        expect(s.restoreCalls, isEmpty);
        final d = _nameDecoration(tester);
        expect((d.border! as Border).top.color, OmColors.danger);
        expect(d.boxShadow!.single.color, OmColors.danger.withAlpha(51));
        expect(_nameHasFocus(), isTrue);
      },
    );

    testWidgets('the name field shows no focus style once focus has left it', (
      tester,
    ) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      expect(_nameHasFocus(), isTrue);

      await _tabTo(tester, restoreFolderKey);

      expect(_nameHasFocus(), isFalse);
      final d = _nameDecoration(tester);
      expect((d.border! as Border).top.color, OmColors.line2);
      expect(d.boxShadow, isEmpty);
    });

    testWidgets(
      'while restoring a focused name field shows no focus style and is read only',
      (tester) async {
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        final hold = s.runner.holdRuns();
        await tester.showKeyboard(
          find.descendant(
            of: find.byKey(restoreNameKey),
            matching: find.byType(EditableText),
            matchRoot: true,
          ),
        );

        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _frames(tester);

        expect(s.restoreCalls, hasLength(1));
        expect(_button(tester, restoreSubmitKey).onPressed, isNull);
        // Return unfocuses the field; a click puts the focus back into the
        // read only field while the run is held.
        await tester.tap(find.byKey(restoreNameKey), warnIfMissed: false);
        await _frames(tester);
        expect(_nameHasFocus(), isTrue, reason: 'the field has the focus');
        expect(
          tester.widget<TextField>(find.byKey(restoreNameKey)).readOnly,
          isTrue,
        );
        final d = _nameDecoration(tester);
        expect((d.border! as Border).top.color, OmColors.line2);
        expect(d.boxShadow, isEmpty);

        hold.complete();
        await _frames(tester);
      },
    );

    testWidgets('no button draws a focus ring until focus reaches it', (
      tester,
    ) async {
      final s = await _pumpPicker(tester);
      await _openDialog(tester, s);
      await _chooseParent(tester, s, s.parent('parent'));
      final buttons = [restoreFolderKey, _restoreCancelKey, restoreSubmitKey];

      for (final k in buttons) {
        expect(_buttonRing(tester, k), isNull, reason: '$k is not focused');
      }

      await _tabTo(tester, restoreSubmitKey);
      final ring = _buttonRing(tester, restoreSubmitKey);
      expect(ring, isNotNull);
      expect(ring!.top.color, OmColors.accentSoft);
      expect(_buttonRing(tester, restoreFolderKey), isNull);
      expect(_buttonRing(tester, _restoreCancelKey), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_buttonRing(tester, restoreSubmitKey), isNull);
    });

    testWidgets(
      'each dialog button is one labelled button node with exactly its own label',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));

        for (final (key, label) in [
          (restoreFolderKey, 'choose…'),
          (_restoreCancelKey, 'cancel'),
          (restoreSubmitKey, 'restore'),
        ]) {
          final nodes = _semanticsAt(tester, key);
          expect(nodes, hasLength(1), reason: '$key is one semantics node');
          final d = nodes.single.getSemanticsData();
          expect(d.flagsCollection.isButton, isTrue, reason: '$key a button');
          expect(d.flagsCollection.isEnabled, Tristate.isTrue);
          expect(d.hasAction(SemanticsAction.tap), isTrue);
          expect(d.label, label, reason: '$key reads as its label once');
        }

        s.runner.holdRuns();
        await _tap(tester, find.byKey(restoreSubmitKey));
        final busyNodes = _semanticsAt(tester, restoreSubmitKey);
        expect(busyNodes, hasLength(1));
        final busy = busyNodes.single.getSemanticsData();
        expect(busy.label, 'restoring…');
        expect(busy.flagsCollection.isButton, isTrue);
        expect(busy.flagsCollection.isEnabled, Tristate.isFalse);
        expect(busy.hasAction(SemanticsAction.tap), isFalse);
        handle.dispose();
      },
    );

    testWidgets(
      'the error is its own live region node carrying exactly the error text',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pumpPicker(tester);
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        s.runner.scriptRestore(
          const RestoreFailure(code: 'backup_invalid', message: 'bad'),
        );
        await _tap(tester, find.byKey(restoreSubmitKey));

        final n = _node(tester, restoreErrorKey);
        expect(n.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
        expect(n.label, _error(), reason: 'nothing else is read with it');
        handle.dispose();
      },
    );

    testWidgets(
      'in a short window at 1.3x text the dialog scrolls instead of overflowing and restore can be reached',
      (tester) async {
        final s = await _pumpPicker(
          tester,
          textScale: 1.3,
          surfaceSize: const Size(700, 380),
        );
        await _openDialog(tester, s);
        await _chooseParent(tester, s, s.parent('parent'));
        s.runner.scriptRestore(
          const RestoreFailure(
            code: 'backup_too_new',
            message: 'too new',
            fields: {'schema_version': 7, 'supported_schema_version': 6},
          ),
        );
        await _tap(tester, find.byKey(restoreSubmitKey));
        expect(find.byKey(restoreErrorKey), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'no overflow');

        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(restoreDialogKey),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(0));
        await tester.ensureVisible(find.byKey(restoreSubmitKey));
        await tester.pump();
        final box = tester.getRect(find.byKey(restoreSubmitKey));
        expect(box.top, greaterThanOrEqualTo(0));
        expect(box.bottom, lessThanOrEqualTo(380));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
