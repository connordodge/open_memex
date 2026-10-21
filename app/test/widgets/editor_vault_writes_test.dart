// WI #78 (W2) AC12: excerpt removal, note delete and `[[` create go through
// `VaultAccess` (D13) inside `guardVaultWrite` (L17). Local outcomes stay as
// today (inline error, `noteDeleteErrorProvider`, the autocomplete's error
// snackbar); a write that throws `VaultUnreachableException` shows the
// guard's snackbar instead and changes nothing. The domains are recording
// doubles that delegate to the FakeMemexCli unless told to throw.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/note_menu.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/editor_access_doubles.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/note_cli_fakes.dart';
import '../support/today_cli_fakes.dart';

const _alphaId = '01J9ALPHAWRITE00000000000078';

Finder get _bodyField => find.descendant(
  of: find.byKey(const Key('editor-body')),
  matching: find.byType(EditableText),
);

String _bodyText(WidgetTester tester) =>
    tester.widget<EditableText>(_bodyField).controller.text;

Finder _snack(String text) => find.descendant(
  of: find.byType(SnackBar),
  matching: find.textContaining(text),
);

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  expect(f, findsOneWidget, reason: key);
  await tester.tap(f);
  await pumpFrames(tester);
}

// ---------------------------------------------------------------- excerpts

Future<(SegmentedEditorRobot, EditorVaultDoubles)> _excerptEditor(
  WidgetTester tester, {
  Object? writeError,
}) async {
  final vault = seedSegmentedVault();
  final doubles = EditorVaultDoubles(
    notesDb: vault.db,
    dailyDb: vault.db,
    cli: vault.cli,
  );
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    overrides: [editorSingleVaultOverride(doubles)],
  );
  h.read(vaultAccessProvider);
  final r = SegmentedEditorRobot(tester, h);
  await r.open(fixtureTopicId);
  doubles.daily.writeError = writeError;
  return (r, doubles);
}

// ------------------------------------------------------------ notes (plain)

/// The workspace on a vault with the plain note "Alpha" (`alpha body`,
/// version 3), opened in its tab. The CLI answers `rm`, `add` and `update`.
Future<(WorkspaceHarness, EditorVaultDoubles)> _alphaEditor(
  WidgetTester tester, {
  Object? writeError,
}) async {
  final db = FakeVaultDb.v5()
    ..seedNote(id: _alphaId, title: 'Alpha', content: 'alpha body', version: 3);
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onRm(db)
    ..onAddCreates(db)
    ..onUpdateWrites(db);
  final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli);
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: cli,
    overrides: [editorSingleVaultOverride(doubles)],
  );
  h.read(vaultAccessProvider);
  h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_alphaId));
  await pumpFrames(tester);
  doubles.notes.writeError = writeError;
  return (h, doubles);
}

Future<void> _deleteFromMenu(WidgetTester tester) async {
  await _tapKey(tester, 'note-menu-button');
  await _tapKey(tester, 'note-menu-delete');
  await _tapKey(tester, 'delete-note-confirm');
  await pumpFrames(tester);
}

Future<void> _createFromAutocomplete(WidgetTester tester) async {
  await _tapKey(tester, 'editor-source-toggle');
  await tester.enterText(_bodyField, 'alpha body [[Sleep');
  await tester.pump();
  await _tapKey(tester, 'wikilink-popover-create');
}

void main() {
  group('excerpt removal through the daily domain (AC12)', () {
    testWidgets(
      'excerpt removal goes through the daily domain and drops the card',
      (tester) async {
        final (r, doubles) = await _excerptEditor(tester);
        final before = r.h.read(vaultRevisionProvider);

        await r.tapRemove(1);

        expect(doubles.daily.writes, [
          'removeExcerpt:$fixtureTopicId:2026-09-05:b7k2m9..c3d4e5',
        ]);
        expect(r.allCards, findsNothing);
        expect(r.inlineError, findsNothing);
        expect(r.h.read(vaultRevisionProvider), greaterThan(before));
      },
    );

    testWidgets(
      'a failed excerpt removal from the daily domain keeps the card and shows the inline error',
      (tester) async {
        final (r, doubles) = await _excerptEditor(
          tester,
          writeError: MemexException(
            'excerpt rm failed: invalid date: 2026-09-05',
            code: 'invalid_date',
          ),
        );
        final before = r.h.read(vaultRevisionProvider);

        await r.tapRemove(1);

        expect(doubles.daily.writes, hasLength(1));
        expect(r.card(1), findsOneWidget);
        expect(
          find.descendant(
            of: r.inlineError,
            matching: find.textContaining('invalid date: 2026-09-05'),
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(r.h.read(vaultRevisionProvider), before);
      },
    );

    testWidgets(
      'an unreachable vault on excerpt removal shows the snackbar and changes nothing',
      (tester) async {
        final (r, doubles) = await _excerptEditor(
          tester,
          writeError: unreachableNas,
        );
        final before = r.h.read(vaultRevisionProvider);

        await r.tapRemove(1);

        expect(doubles.daily.writes, hasLength(1));
        expect(_snack(unreachableNasSnack), findsOneWidget);
        expect(r.card(1), findsOneWidget);
        expect(r.inlineError, findsNothing);
        expect(r.excerptRms, isEmpty);
        expect(r.h.read(vaultRevisionProvider), before);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('note delete through the notes domain (AC12)', () {
    testWidgets(
      'note delete goes through the notes domain and closes the tab',
      (tester) async {
        final (h, doubles) = await _alphaEditor(tester);
        final before = h.read(vaultRevisionProvider);

        await _deleteFromMenu(tester);

        expect(doubles.notes.writes, ['deleteNote:$_alphaId@3']);
        expect(
          h.read(tabsProvider).tabs,
          isNot(contains(const NoteTab(_alphaId))),
        );
        expect(h.read(noteDeleteErrorProvider), isNull);
        expect(h.read(vaultRevisionProvider), greaterThan(before));
      },
    );

    testWidgets(
      'a failed note delete from the notes domain sets noteDeleteErrorProvider and keeps the tab',
      (tester) async {
        final (h, doubles) = await _alphaEditor(
          tester,
          writeError: MemexException(
            'rm failed: note changed since last read',
            code: 'version_conflict',
            kind: MemexErrorKind.versionConflict,
          ),
        );
        final before = h.read(vaultRevisionProvider);

        await _deleteFromMenu(tester);

        expect(doubles.notes.writes, hasLength(1));
        final error = h.read(noteDeleteErrorProvider);
        expect(error?.noteId, _alphaId);
        expect(error?.message, contains('note changed since last read'));
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(h.read(tabsProvider).tabs, contains(const NoteTab(_alphaId)));
        expect(find.byType(SnackBar), findsNothing);
        expect(h.read(vaultRevisionProvider), before);
      },
    );

    testWidgets(
      'an unreachable vault on note delete shows the snackbar and changes nothing',
      (tester) async {
        final (h, doubles) = await _alphaEditor(
          tester,
          writeError: unreachableNas,
        );
        final before = h.read(vaultRevisionProvider);

        await _deleteFromMenu(tester);

        expect(doubles.notes.writes, hasLength(1));
        expect(_snack(unreachableNasSnack), findsOneWidget);
        expect(h.read(noteDeleteErrorProvider), isNull);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(h.read(tabsProvider).activeTab, const NoteTab(_alphaId));
        expect(h.cli.callsFor('rm'), isEmpty);
        expect(h.read(vaultRevisionProvider), before);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('wikilink create through the notes domain (AC12)', () {
    testWidgets(
      'creating a note from the wikilink autocomplete goes through the notes domain addNote',
      (tester) async {
        final (h, doubles) = await _alphaEditor(tester);
        final before = h.read(vaultRevisionProvider);

        await _createFromAutocomplete(tester);

        expect(doubles.notes.writes, contains('addNote:Sleep:null'));
        expect(_bodyText(tester), 'alpha body [[Sleep]]');
        expect(h.read(vaultRevisionProvider), greaterThan(before));
        h.clock.advance(const Duration(milliseconds: 600));
        await pumpFrames(tester);
      },
    );

    testWidgets(
      'a failed wikilink create from the notes domain shows the autocomplete error',
      (tester) async {
        final (h, doubles) = await _alphaEditor(
          tester,
          writeError: MemexException(
            'add failed: a note titled "Sleep" already exists',
            code: 'title_conflict',
          ),
        );

        await _createFromAutocomplete(tester);

        expect(doubles.notes.writes, ['addNote:Sleep:null']);
        expect(
          _snack('Could not create note: add failed: a note titled'),
          findsOneWidget,
        );
        expect(_bodyText(tester), 'alpha body [[Sleep');
        h.clock.advance(const Duration(milliseconds: 600));
        await pumpFrames(tester);
      },
    );

    testWidgets(
      'an unreachable vault on wikilink create shows the snackbar and changes nothing',
      (tester) async {
        final (h, doubles) = await _alphaEditor(
          tester,
          writeError: unreachableNas,
        );
        final before = h.read(vaultRevisionProvider);

        await _createFromAutocomplete(tester);

        expect(doubles.notes.writes, ['addNote:Sleep:null']);
        expect(_snack(unreachableNasSnack), findsOneWidget);
        expect(_snack('Could not create note'), findsNothing);
        expect(_bodyText(tester), 'alpha body [[Sleep');
        expect(h.cli.callsFor('add'), isEmpty);
        expect(h.read(vaultRevisionProvider), before);
        expect(tester.takeException(), isNull);
        h.clock.advance(const Duration(milliseconds: 600));
        await pumpFrames(tester);
      },
    );
  });
}
