// WI #171 (C4, Spec #157 R30; rulings D9, D12, D17): undo and redo at text
// segment level, across all its editor rows.
// - Cmd+Z undoes, as one step each, every SegmentEdit the host applies
//   (driven through the host's applyEdit, since C1b's checkbox and C2's keys
//   may land later: a toggleTask toggle, and edits shaped like an Enter
//   split, a marker removal, a join and a prefix conversion), plus a
//   cross-row delete, a cut, a paste and a type-over. Undo restores the exact
//   previous bytes and Shift+Cmd+Z the exact bytes after (D17).
// - Typing coalesces as Flutter's UndoHistory does: the test runs the same
//   typing script in a plain TextField and in the segment and compares.
// - History resets when the segment is rebuilt from outside (a server
//   write): Cmd+Z then changes nothing.
// Every test runs on macOS (mac_editing.dart, TS7); time moves only through
// pump durations (no wall-clock waits).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_edits.dart';
import 'package:open_memex_app/src/editor/segment_selection.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/vault_state.dart'
    show
        LocalVaultRef,
        currentVaultProvider,
        linkKindsAsyncProvider,
        memexCliProvider,
        noteTitlesAsyncProvider,
        selectedNoteAsyncProvider,
        vaultDbProvider;
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/wi171_segment_harness.dart';

/// Rows: prose `intro` (CRLF), task `milk`, bullet `eggs`, an empty bullet,
/// prose `plain\r\nend`.
const _wi171Base = 'intro\r\n- [ ] milk\n- eggs\n- \nplain\r\nend';

/// Longer than Flutter's undo throttle (500 ms): the next edit is a new
/// step.
const _wi171Idle = Duration(seconds: 1);

/// The pause between two typed keys of one burst.
const _wi171KeyGap = Duration(milliseconds: 50);

List<RowSpec> _wi171Rows(String text) => splitRows(text, atSegmentStart: true);

/// An edit of segment text through the host's applyEdit, as C1b, C2 and A3
/// shape them.
typedef _Wi171EditOf = SegmentEdit Function(String text, List<RowSpec> rows);

/// Records every vault write (`updateNote`) the editor sends; never shells
/// out.
class _Wi171WriteCli extends MemexCli {
  _Wi171WriteCli() : super(binaryPath: '/nonexistent/memex-test-binary');

  /// The body of every `updateNote` call, in order.
  final writes = <String>[];

  @override
  Future<NoteUpdateResult> updateNote({
    required String vaultPath,
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool withEmbeddings = false,
    bool noRenameLinks = false,
  }) async {
    writes.add(contentMd);
    return NoteUpdateResult(
      noteId: noteId,
      version: expectedVersion + 1,
      updatedAt: 1,
    );
  }
}

const _wi171VaultPath = '/vaults/wi171';

/// Pumps the whole note editor (EditorController with its save debounce on
/// [clock], and the segmented body) on a note whose body is [text].
Future<void> _wi171PumpEditor(
  WidgetTester tester,
  String text, {
  required _Wi171WriteCli cli,
  required FakeClock clock,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final note = Note(
    id: 'n171',
    title: 'Ops',
    contentMd: text,
    frontmatter: '',
    version: 3,
    createdAt: 0,
    updatedAt: 0,
    tags: const [],
  );
  const vault = LocalVaultRef(_wi171VaultPath);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(clock),
        selectedNoteAsyncProvider.overrideWith(
          (ref) => VaultScoped(vault, note),
        ),
        currentVaultProvider.overrideWith((ref) => vault),
        memexCliProvider.overrideWithValue(cli),
        vaultDbProvider.overrideWithValue(null),
        noteTitlesAsyncProvider.overrideWith(
          (ref) => const VaultScoped(vault, <NoteTitle>[]),
        ),
        linkKindsAsyncProvider.overrideWith(
          (ref) => const VaultScoped(vault, <String>[]),
        ),
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: NoteEditor(rightPanelOpen: false, onToggleRightPanel: () {}),
        ),
      ),
    ),
  );
  // The editor hydrates in a post-frame callback; one more frame renders it.
  await tester.pump();
  await tester.pump();
}

/// Moves the save debounce's clock by [by], then lets the save land.
Future<void> _wi171Advance(
  WidgetTester tester,
  FakeClock clock,
  Duration by,
) async {
  clock.advance(by);
  await tester.pump();
  await tester.pump();
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC7: every applied SegmentEdit is one undo step with exact bytes
  // -------------------------------------------------------------------------
  group('applied edits undo as one step (AC7)', () {
    final cases = <(String, _Wi171EditOf)>[
      (
        'Cmd+Z undoes a toggleTask toggle applied through applyEdit as one step and Shift+Cmd+Z redoes it',
        (text, rows) => toggleTask(text, rows[1])!,
      ),
      (
        'Cmd+Z undoes an Enter split as one step and Shift+Cmd+Z redoes it',
        (text, rows) => splitItem(text, rows, 2, rows[2].textStart + 2)!,
      ),
      (
        'Cmd+Z undoes a marker removal as one step and Shift+Cmd+Z redoes it',
        (text, rows) => backspaceAtStart(text, rows, 2)!,
      ),
      (
        'Cmd+Z undoes a join as one step and Shift+Cmd+Z redoes it',
        (text, rows) => joinPrevious(text, rows, 4, rows[4].textStart)!,
      ),
      (
        'Cmd+Z undoes a prefix conversion as one step and Shift+Cmd+Z redoes it',
        (text, rows) => SegmentEdit(
          start: rows[2].start,
          end: rows[2].textStart,
          replacement: '- [ ] ',
          selection: SegmentSelection.collapsed(rows[2].textStart + 4),
        ),
      ),
      (
        'Cmd+Z undoes a cross row delete as one step and Shift+Cmd+Z redoes it',
        (text, rows) => deleteRange(
          text,
          rows,
          SegmentSelection(
            baseOffset: rows[1].textStart + 2,
            extentOffset: rows[2].textStart + 2,
          ),
        ),
      ),
    ];

    for (final (name, editOf) in cases) {
      testWidgets(name, (tester) async {
        final body = await wi171Pump(tester, _wi171Base);
        await wi171FocusRow(tester, 0, 0);
        await tester.pump(_wi171Idle);
        final edit = editOf(_wi171Base, _wi171Rows(_wi171Base));
        final after = edit.apply(_wi171Base);

        wi171View(tester, 0).applyEdit(edit);
        await tester.pump();
        expect(segmentEditingAt(tester, 0).text, after);
        expect(body.changes, [after]);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, _wi171Base);
        expect(body.changes, [after, _wi171Base]);
        expect(segmentEditingAt(tester, 0).focusedRow, isNotNull);

        // One step: nothing older to undo.
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, _wi171Base);
        expect(body.changes, hasLength(2));

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, after);
        expect(body.changes, [after, _wi171Base, after]);

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, after);
        expect(body.changes, hasLength(3));
      }, variant: macOnly);
    }

    testWidgets(
      'Cmd+Z undoes a cut across rows as one step and Shift+Cmd+Z redoes it',
      (tester) async {
        MacClipboard.install(tester);
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        await tester.macCmdChord(LogicalKeyboardKey.keyX);
        expect(segmentEditingAt(tester, 0).text, 'para\n- ad');

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes.last, wi171Text);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- ad');
        expect(body.changes.last, 'para\n- ad');
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Z undoes a paste across rows as one step and Shift+Cmd+Z redoes it',
      (tester) async {
        MacClipboard.install(tester, initial: 'X\nY');
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        await tester.macCmdChord(LogicalKeyboardKey.keyV);
        await tester.pump();
        expect(segmentEditingAt(tester, 0).text, 'para\n- aX\nYd');

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes.last, wi171Text);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- aX\nYd');
        expect(body.changes.last, 'para\n- aX\nYd');
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Z undoes a type over across rows as one step and Shift+Cmd+Z redoes it',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        await wi171TypeKey(tester, 'z');
        expect(segmentEditingAt(tester, 0).text, 'para\n- azd');

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes.last, wi171Text);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- azd');
        expect(body.changes.last, 'para\n- azd');
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Z walks back through several edits one step each and Shift+Cmd+Z walks forward to the exact bytes',
      (tester) async {
        await wi171Pump(tester, _wi171Base);
        await wi171FocusRow(tester, 0, 0);
        await tester.pump(_wi171Idle);
        final states = [_wi171Base];

        Future<void> apply(_Wi171EditOf editOf) async {
          final text = segmentEditingAt(tester, 0).text;
          wi171View(tester, 0).applyEdit(editOf(text, _wi171Rows(text)));
          await tester.pump();
          states.add(segmentEditingAt(tester, 0).text);
          await tester.pump(_wi171Idle);
        }

        await apply((text, rows) => toggleTask(text, rows[1])!);
        await apply(
          (text, rows) => splitItem(text, rows, 2, rows[2].textStart + 2)!,
        );
        // A typed key in the focused first row.
        await wi171TypeKey(tester, 'x');
        states.add(segmentEditingAt(tester, 0).text);
        await tester.pump(_wi171Idle);
        await apply(
          (text, rows) => deleteRange(
            text,
            rows,
            SegmentSelection(
              baseOffset: rows[1].textStart + 1,
              extentOffset: rows[3].textStart + 1,
            ),
          ),
        );
        expect(states.toSet(), hasLength(5), reason: 'every edit changed it');

        for (var i = states.length - 2; i >= 0; i--) {
          await wi171Undo(tester);
          expect(
            segmentEditingAt(tester, 0).text,
            states[i],
            reason: 'undo $i',
          );
        }
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, _wi171Base);

        for (var i = 1; i < states.length; i++) {
          await wi171Redo(tester);
          expect(
            segmentEditingAt(tester, 0).text,
            states[i],
            reason: 'redo $i',
          );
        }
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, states.last);
      },
      variant: macOnly,
    );

    testWidgets('a new edit after Cmd+Z clears what Shift+Cmd+Z would redo', (
      tester,
    ) async {
      await wi171Pump(tester, _wi171Base);
      await wi171FocusRow(tester, 0, 0);
      await tester.pump(_wi171Idle);
      final rows = _wi171Rows(_wi171Base);
      final toggle = toggleTask(_wi171Base, rows[1])!;
      wi171View(tester, 0).applyEdit(toggle);
      await tester.pump(_wi171Idle);
      await wi171Undo(tester);
      expect(segmentEditingAt(tester, 0).text, _wi171Base);
      await tester.pump(_wi171Idle);

      final marker = backspaceAtStart(_wi171Base, rows, 2)!;
      wi171View(tester, 0).applyEdit(marker);
      await tester.pump(_wi171Idle);
      await wi171Redo(tester);

      expect(segmentEditingAt(tester, 0).text, marker.apply(_wi171Base));
    }, variant: macOnly);

    testWidgets('Cmd+Z with no history changes nothing and reports nothing', (
      tester,
    ) async {
      final body = await wi171Pump(tester, _wi171Base);
      await wi171FocusRow(tester, 0, 1);
      await tester.pump(_wi171Idle);

      await wi171Undo(tester);
      await wi171Redo(tester);

      expect(segmentEditingAt(tester, 0).text, _wi171Base);
      expect(body.changes, isEmpty);
    }, variant: macOnly);

    testWidgets(
      'Cmd+Z in one text segment leaves the other text segment unchanged',
      (tester) async {
        const token = '![[2026-09-05#^b7k2m9..^c3d4e5]]';
        await wi171Pump(tester, '- [ ] a\n- b\n$token\nplain\n- [ ] c');
        final first = segmentEditingAt(tester, 0).text;
        final second = segmentEditingAt(tester, 2).text;
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);
        wi171View(
          tester,
          0,
        ).applyEdit(toggleTask(first, _wi171Rows(first)[0])!);
        await tester.pump(_wi171Idle);
        final rows2 = _wi171Rows(second);
        wi171View(tester, 2).applyEdit(toggleTask(second, rows2.last)!);
        await tester.pump(_wi171Idle);
        final second2 = segmentEditingAt(tester, 2).text;
        expect(second2, isNot(second));

        await wi171Undo(tester);

        expect(segmentEditingAt(tester, 0).text, first);
        expect(segmentEditingAt(tester, 2).text, second2);

        await wi171FocusRow(tester, 2, rows2.length - 1);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 2).text, second);
        expect(segmentEditingAt(tester, 0).text, first);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: typing coalesces as Flutter's UndoHistory does
  // -------------------------------------------------------------------------
  group('typing coalesces as UndoHistory (AC8)', () {
    /// Runs the typing script on the focused field (or segment): type
    /// [first] in a burst on line 0, move the caret to the end of line
    /// [moveTo] and type `z` within the same burst, then after a pause a
    /// second burst `wv`; then three Cmd+Z and three Shift+Cmd+Z. Returns
    /// the text [read] gives after each Cmd+Z and Shift+Cmd+Z.
    Future<List<String>> runScript(
      WidgetTester tester, {
      required Future<void> Function(int line) caretToLineEnd,
      required String Function() read,
      int moveTo = 0,
    }) async {
      for (final ch in ['x', 'y']) {
        await wi171TypeKey(tester, ch);
        await tester.pump(_wi171KeyGap);
      }
      await caretToLineEnd(moveTo);
      await wi171TypeKey(tester, 'z');
      await tester.pump(_wi171KeyGap);
      await tester.pump(_wi171Idle);
      for (final ch in ['w', 'v']) {
        await wi171TypeKey(tester, ch);
        await tester.pump(_wi171KeyGap);
      }
      final out = <String>[];
      for (var i = 0; i < 3; i++) {
        await wi171Undo(tester);
        out.add(read());
      }
      for (var i = 0; i < 3; i++) {
        await wi171Redo(tester);
        out.add(read());
      }
      return out;
    }

    /// The same script in a plain Flutter TextField holding [text], the
    /// caret at the end of its first line.
    Future<List<String>> reference(
      WidgetTester tester,
      String text, {
      int moveTo = 0,
    }) async {
      final lines = text.split('\n');
      final ctrl = TextEditingController.fromValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: lines.first.length),
        ),
      );
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TextField(controller: ctrl, maxLines: null)),
        ),
      );
      await tester.showKeyboard(find.byType(TextField));
      await tester.pump(_wi171Idle);
      expect(ctrl.selection.baseOffset, lines.first.length);
      return runScript(
        tester,
        moveTo: moveTo,
        caretToLineEnd: (line) async {
          final current = ctrl.text.split('\n');
          var end = 0;
          for (var i = 0; i <= line; i++) {
            end += current[i].length + (i < line ? 1 : 0);
          }
          ctrl.selection = TextSelection.collapsed(offset: end);
          await tester.pump();
        },
        read: () => ctrl.text,
      );
    }

    testWidgets(
      'a burst of typed characters in one row undoes as Flutter UndoHistory coalesces it',
      (tester) async {
        final expected = await reference(tester, 'ab');
        // The script coalesced: the first Cmd+Z drops `wv`, the second the
        // whole `xyz` burst.
        expect(expected.take(2), ['abxyz', 'ab']);

        await wi171Pump(tester, 'para\n- ab\n- cd');
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);
        final got = await runScript(
          tester,
          caretToLineEnd: (line) => wi171FocusRow(tester, 0, 1 + line),
          read: () => wi171Ctrl(tester, 0, 1).text,
        );

        expect(got, expected);
      },
      variant: macOnly,
    );

    testWidgets(
      'a burst typed across two rows undoes as Flutter UndoHistory coalesces it in one field',
      (tester) async {
        final expected = await reference(tester, 'ab\ncd', moveTo: 1);
        expect(expected.take(2), ['abxy\ncdz', 'ab\ncd']);

        await wi171Pump(tester, 'para\n- ab\n- cd');
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);
        final got = await runScript(
          tester,
          moveTo: 1,
          caretToLineEnd: (line) => wi171FocusRow(tester, 0, 1 + line),
          read: () {
            final text = segmentEditingAt(tester, 0).text;
            expect(text, startsWith('para\n- '));
            return text.substring('para\n- '.length).replaceAll('\n- ', '\n');
          },
        );

        expect(got, expected);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC9: a server write resets the history
  // -------------------------------------------------------------------------
  group('server writes reset the history (AC9)', () {
    testWidgets(
      'after a server write rebuilds the segment Cmd+Z changes nothing',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);
        wi171View(tester, 0).applyEdit(
          const SegmentEdit(
            start: 9,
            end: 9,
            replacement: 'x',
            selection: SegmentSelection.collapsed(10),
          ),
        );
        await tester.pump(_wi171Idle);
        expect(segmentEditingAt(tester, 0).text, 'para\n- abx\n- cd');

        // A poll appends to the focused row.
        const server = 'para\n- abxy\n- cd\n- e';
        await body.serverWrite(server);
        await tester.pump(_wi171Idle);
        expect(segmentEditingAt(tester, 0).text, server);
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
        final reports = body.changes.length;

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, server);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, server);
        expect(body.changes, hasLength(reports));
      },
      variant: macOnly,
    );

    testWidgets(
      'after a server write new edits undo back to the server text only',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);
        await wi171TypeKey(tester, 'x');
        await tester.pump(_wi171Idle);
        const server = 'para\n- abxy\n- cd';
        await body.serverWrite(server);
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);

        await wi171TypeKey(tester, 'q');
        expect(segmentEditingAt(tester, 0).text, 'para\n- abxyq\n- cd');
        await tester.pump(_wi171Idle);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, server);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, server);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- abxyq\n- cd');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // D20 follow-up and contracts the recorder documents (verify-mode pins)
  // -------------------------------------------------------------------------
  group('recorder contracts (D20, documented behaviour)', () {
    testWidgets(
      'Cmd+Z undoes an Enter over a cross row selection as one step and Shift+Cmd+Z redoes it',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);
        // C2's Enter over the range, composed into one SegmentEdit (D20):
        // delete `b\n- c`, then split the bullet at the caret.
        const enter = SegmentEdit(
          start: 8,
          end: 13,
          replacement: '\n- ',
          selection: SegmentSelection.collapsed(11),
        );
        const after = 'para\n- a\n- d';
        expect(enter.apply(wi171Text), after);

        wi171View(tester, 0).applyEdit(enter);
        await tester.pump();
        expect(segmentEditingAt(tester, 0).text, after);
        expect(body.changes, [after]);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes, [after, wi171Text]);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes, hasLength(2));

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, after);
        expect(body.changes, [after, wi171Text, after]);
      },
      variant: macOnly,
    );

    testWidgets('Cmd+Z after a cut restores the cross row selection', (
      tester,
    ) async {
      MacClipboard.install(tester);
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await tester.pump(_wi171Idle);

      await tester.macCmdChord(LogicalKeyboardKey.keyX);
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 8),
      );
      await wi171Undo(tester);

      expect(segmentEditingAt(tester, 0).text, wi171Text);
      expect(segmentEditingAt(tester, 0).selection, wi171Across);

      await wi171Redo(tester);
      expect(
        segmentEditingAt(tester, 0).selection,
        const TextSelection.collapsed(offset: 8),
      );
    }, variant: macOnly);

    testWidgets(
      'Shift+Cmd+Z while typing is pending has nothing to redo and keeps the typing',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171FocusRow(tester, 0, 1);
        await tester.pump(_wi171Idle);

        await wi171TypeKey(tester, 'x');
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- abx\n- cd');
        expect(body.changes, ['para\n- abx\n- cd']);

        // The redo made the typing a step: Cmd+Z goes back past it at once.
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- abx\n- cd');
      },
      variant: macOnly,
    );

    testWidgets(
      'an applied edit right after typing undoes on its own and leaves the typing as the step before',
      (tester) async {
        await wi171Pump(tester, _wi171Base);
        await wi171FocusRow(tester, 0, 0);
        await tester.pump(_wi171Idle);

        await wi171TypeKey(tester, 'x');
        const typed = 'introx\r\n- [ ] milk\n- eggs\n- \nplain\r\nend';
        expect(segmentEditingAt(tester, 0).text, typed);
        final toggle = toggleTask(typed, _wi171Rows(typed)[1])!;
        wi171View(tester, 0).applyEdit(toggle);
        await tester.pump();
        final toggled = toggle.apply(typed);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, typed);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, _wi171Base);
        await wi171Redo(tester);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, toggled);
      },
      variant: macOnly,
    );

    testWidgets('typing after a type over is its own undo step', (
      tester,
    ) async {
      await wi171Pump(tester, wi171Text);
      await wi171SelectAcross(tester, focus: 2);
      await tester.pump(_wi171Idle);

      await wi171TypeKey(tester, 'z');
      await tester.pump(_wi171KeyGap);
      await wi171TypeKey(tester, 'q');
      expect(segmentEditingAt(tester, 0).text, 'para\n- azqd');
      await tester.pump(_wi171Idle);

      await wi171Undo(tester);
      expect(segmentEditingAt(tester, 0).text, 'para\n- azd');
      await wi171Undo(tester);
      expect(segmentEditingAt(tester, 0).text, wi171Text);
    }, variant: macOnly);

    testWidgets(
      'a typed edit after a type over key that inserted nothing is its own undo step',
      (tester) async {
        await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        // The key deletes the range, but no text arrives for it.
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.keyZ,
          platform: 'macos',
          character: 'z',
        );
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ, platform: 'macos');
        await tester.pump();
        expect(segmentEditingAt(tester, 0).text, 'para\n- ad');

        await wi171TypeKey(tester, 'q');
        expect(segmentEditingAt(tester, 0).text, 'para\n- aqd');
        await tester.pump(_wi171Idle);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- ad');
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Z undoes an accent composed over a cross row selection as one step',
      (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        await tester.macCompose('´d', const TextRange(start: 0, end: 1));
        await tester.pump(_wi171KeyGap);
        await tester.macEditingValue(
          'aéd',
          selection: const TextSelection.collapsed(offset: 2),
        );
        expect(segmentEditingAt(tester, 0).text, 'para\n- aéd');
        await tester.pump(_wi171Idle);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes.last, wi171Text);
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- aéd');
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+Z undoes a Japanese composition over a cross row selection as one step',
      (tester) async {
        await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        await tester.macCompose('にd', const TextRange(start: 0, end: 1));
        await tester.pump(_wi171Idle);
        await tester.macCompose('aにほd', const TextRange(start: 1, end: 3));
        await tester.pump(_wi171Idle);
        await tester.macEditingValue(
          'a日本d',
          selection: const TextSelection.collapsed(offset: 3),
        );
        await tester.pump(_wi171Idle);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, 'para\n- a日本d');
      },
      variant: macOnly,
    );

    testWidgets('a composition within one row undoes to the text before it', (
      tester,
    ) async {
      await wi171Pump(tester, wi171Text);
      await wi171FocusRow(tester, 0, 2);
      await tester.pump(_wi171Idle);

      await tester.macCompose('cd´', const TextRange(start: 2, end: 3));
      await tester.pump(_wi171Idle);
      await tester.macEditingValue(
        'cdé',
        selection: const TextSelection.collapsed(offset: 3),
      );
      expect(segmentEditingAt(tester, 0).text, 'para\n- ab\n- cdé');
      await tester.pump(_wi171Idle);

      await wi171Undo(tester);
      expect(segmentEditingAt(tester, 0).text, wi171Text);
      await wi171Redo(tester);
      expect(segmentEditingAt(tester, 0).text, 'para\n- ab\n- cdé');
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // Ruling D20a: type-over and IME start over a cross-row selection delete
  // the range first (at key down, or through the D19 rowComposingInterceptor
  // when composing starts) and let the field or the IME insert. That is more
  // than one onContentChanged report, but ONE undo step with exact bytes
  // both ways, and the deleted-only text is never saved on its own.
  // -------------------------------------------------------------------------
  group('type over and IME start (D20a)', () {
    final typeOver = <(String, Duration)>[
      (
        'D20a after a type over one Cmd+Z restores the exact original bytes and Shift+Cmd+Z the typed bytes',
        Duration.zero,
      ),
      (
        'D20a after a type over and an idle pause one Cmd+Z restores the exact original bytes and Shift+Cmd+Z the typed bytes',
        _wi171Idle,
      ),
    ];
    for (final (name, pause) in typeOver) {
      testWidgets(name, (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        await wi171TypeKey(tester, 'z');
        await tester.pump(pause);
        const typed = 'para\n- azd';
        expect(segmentEditingAt(tester, 0).text, typed);
        // D20a: the range delete, then the field's insert.
        expect(body.changes, ['para\n- ad', typed]);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(segmentEditingAt(tester, 0).selection, wi171Across);
        expect(body.changes, ['para\n- ad', typed, wi171Text]);

        // One step: the deleted-only text is not a step of its own.
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes, hasLength(3));

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, typed);
        expect(
          segmentEditingAt(tester, 0).selection,
          const TextSelection.collapsed(offset: 9),
        );
        expect(body.changes, ['para\n- ad', typed, wi171Text, typed]);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, typed);
        expect(body.changes, hasLength(4));

        // And back again: still the exact original in one step.
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes, hasLength(5));
      }, variant: macOnly);
    }

    final composing = <(String, Duration)>[
      (
        'D20a after composing over a cross row selection and its commit one Cmd+Z restores the exact original bytes',
        Duration.zero,
      ),
      (
        'D20a after composing over a cross row selection an idle pause and its commit one Cmd+Z restores the exact original bytes',
        _wi171Idle,
      ),
    ];
    for (final (name, pause) in composing) {
      testWidgets(name, (tester) async {
        final body = await wi171Pump(tester, wi171Text);
        await wi171SelectAcross(tester, focus: 2);
        await tester.pump(_wi171Idle);

        // Option+E over the row slice `c`: the D19 interceptor deletes the
        // whole cross-row range into the focused row first.
        await tester.macCompose('´d', const TextRange(start: 0, end: 1));
        expect(segmentEditingAt(tester, 0).text, 'para\n- a´d');
        expect(segmentEditingAt(tester, 0).focusedRow, 1);
        await tester.pump(pause);
        // E: the IME commits.
        await tester.macEditingValue(
          'aéd',
          selection: const TextSelection.collapsed(offset: 2),
        );
        const committed = 'para\n- aéd';
        expect(segmentEditingAt(tester, 0).text, committed);
        expect(body.changes, ['para\n- ad', 'para\n- a´d', committed]);

        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(segmentEditingAt(tester, 0).selection, wi171Across);
        expect(body.changes, hasLength(4));
        expect(body.changes.last, wi171Text);

        // One step: neither the deleted-only nor the marked text is a step.
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        expect(body.changes, hasLength(4));

        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, committed);
        expect(body.changes, hasLength(5));
        expect(body.changes.last, committed);
        await wi171Redo(tester);
        expect(segmentEditingAt(tester, 0).text, committed);
        expect(body.changes, hasLength(5));
      }, variant: macOnly);
    }

    testWidgets(
      'D20a a type over across rows makes one vault write carrying the final bytes',
      (tester) async {
        final cli = _Wi171WriteCli();
        final clock = FakeClock();
        await _wi171PumpEditor(tester, wi171Text, cli: cli, clock: clock);
        await wi171SelectAcross(tester, focus: 2);

        await wi171TypeKey(tester, 'z');
        expect(segmentEditingAt(tester, 0).text, 'para\n- azd');
        expect(cli.writes, isEmpty);

        await _wi171Advance(
          tester,
          clock,
          saveDebounce - const Duration(milliseconds: 1),
        );
        expect(cli.writes, isEmpty);
        await _wi171Advance(tester, clock, const Duration(milliseconds: 1));
        expect(cli.writes, ['para\n- azd']);

        // Nothing else is ever saved, not the deleted-only `para\n- ad`.
        await _wi171Advance(tester, clock, const Duration(seconds: 5));
        expect(cli.writes, ['para\n- azd']);

        // After the save the type-over is still one undo step; undoing it
        // saves the exact original bytes.
        await wi171Undo(tester);
        expect(segmentEditingAt(tester, 0).text, wi171Text);
        await _wi171Advance(tester, clock, saveDebounce);
        expect(cli.writes, ['para\n- azd', wi171Text]);
      },
      variant: macOnly,
    );

    testWidgets(
      'D20a composing over a cross row selection then its commit makes one vault write carrying the committed bytes',
      (tester) async {
        final cli = _Wi171WriteCli();
        final clock = FakeClock();
        await _wi171PumpEditor(tester, wi171Text, cli: cli, clock: clock);
        await wi171SelectAcross(tester, focus: 2);

        await tester.macCompose('´d', const TextRange(start: 0, end: 1));
        expect(segmentEditingAt(tester, 0).text, 'para\n- a´d');
        await _wi171Advance(tester, clock, const Duration(milliseconds: 100));
        await tester.macEditingValue(
          'aéd',
          selection: const TextSelection.collapsed(offset: 2),
        );
        expect(segmentEditingAt(tester, 0).text, 'para\n- aéd');
        expect(cli.writes, isEmpty);

        await _wi171Advance(tester, clock, saveDebounce);
        expect(cli.writes, ['para\n- aéd']);
        await _wi171Advance(tester, clock, const Duration(seconds: 5));
        expect(cli.writes, ['para\n- aéd']);
      },
      variant: macOnly,
    );
  });
}
