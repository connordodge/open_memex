// WI #327 (A6, D24, Spec req 35 and 37, L7, L9): "restore from backup…" in
// the vault picker and the Restore dialog. Driven through the real
// VaultPickerScreen over the A0 harness: FakeBackupRunner behind
// `backupRunnerProvider` (call counts, scripted results, a held run), the
// FakeFilePicker for the native pickers, and a recording open controller.
// The backup file is a real temp file (sparse, so its size is real without
// writing 41 MB): `FakeFilePicker.pickFiles` reports size 0, so the dialog
// reads the size from the file itself. Copy and layout are the design pack's
// (`design/315-vault-backups/packs/327.md`); the design wins over the WI.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
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
  _RecordingOpener(super.ref);

  final List<VaultRef> opened = [];

  @override
  Future<VaultOpenOutcome> openVault(VaultRef vault) async {
    opened.add(vault);
    return VaultOpened(vault);
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
}) async {
  final dir = Directory.systemTemp.createTempSync('om327_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final file = p.join(dir.path, fileName);
  _sparseFile(file, bytes);
  final picker = installFakeFilePicker();
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  _RecordingOpener? opener;
  final harness = await pumpBackupWidget(
    tester,
    const VaultPickerScreen(),
    surfaceSize: const Size(1280, 1100),
    overrides: [
      vaultOpenControllerProvider.overrideWith(
        (ref) => opener ??= _RecordingOpener(ref),
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
}
