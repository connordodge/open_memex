// WI #87 (W3): after a `[[` create adds a footer chip to the open daily note
// (`memex footer add` bumps its version), the editor rebases onto the returned
// version, reading the stored note through VaultAccess.notes, and keeps the
// unsaved text and title. The footer write goes through VaultAccess.daily.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/today_cli_fakes.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';

const _today = '2026-10-03';
const _todayId = 'daily-2026-10-03';
const _earlier = '2026-09-30';
const _earlierId = 'daily-2026-09-30';
const _typed = 'Slept badly [[Sleep';

FakeMemexCli _newCli(FakeVaultDb db) => FakeMemexCli()
  ..onUpdateWrites(db)
  ..onAddCreates(db)
  ..onFooterAdd(db);

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  expect(f, findsOneWidget, reason: key);
  await tester.tap(f);
  await pumpFrames(tester);
}

Finder get _bodyField => find.descendant(
  of: find.byKey(const Key('editor-body')),
  matching: find.byType(EditableText),
);

String _bodyText(WidgetTester tester) =>
    tester.widget<EditableText>(_bodyField).controller.text;

/// Let the editor's 500 ms save debounce (on the harness clock) and the CLI
/// round trip finish.
Future<void> _drain(WidgetTester tester, WorkspaceHarness h) async {
  h.clock.advance(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  await pumpFrames(tester);
}

Future<void> _typeAndChooseCreate(WidgetTester tester) async {
  await tester.enterText(_bodyField, _typed);
  await tester.pump();
  await _tap(tester, 'wikilink-popover-create');
}

/// Launches on two daily notes (today and [_earlier]) and opens [_earlier].
Future<(WorkspaceHarness, FakeMemexCli, AccessDoubles, FakeVaultDb)> _launch(
  WidgetTester tester, {
  bool getNoteIsNull = false,
  Object? footerFailure,
}) async {
  final db = FakeVaultDb.v5()
    ..seedDailyNote(_today, id: _todayId)
    ..seedDailyNote(_earlier, id: _earlierId);
  final cli = _newCli(db);
  final doubles = AccessDoubles(
    configureDaily: (_, d) {
      if (footerFailure != null) d.failNext('addFooterChip', footerFailure);
    },
  );
  final r = await launchTopics(
    tester,
    doubles,
    db: db,
    cli: cli,
    topicsMode: false,
  );
  r.h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
  await pumpFrames(tester);
  // TEST-CHANGE (#78): the editor loads the open note through
  // VaultAccess.notes too, so only the next read (the rebase's, the first
  // getNote after the note is open) answers null.
  doubles.notesAt(r.h.vaultPath).nextGetNoteIsNull = getNoteIsNull;
  return (r.h, cli, doubles, db);
}

void main() {
  testWidgets(
    'after a [[ create adds a footer chip the editor rebases onto the returned version reading the stored note through the notes domain and keeps the unsaved text and title',
    (tester) async {
      final (h, cli, doubles, db) = await _launch(tester);
      final readsBefore = doubles.notesCalls(h.vaultPath, 'getNote').length;

      await _typeAndChooseCreate(tester);

      expect(
        doubles.dailyAt(h.vaultPath).callsTo('addFooterChip').single.args,
        {'dailyNoteId': _earlierId, 'topicNoteId': createdTopicId},
      );
      final reads = doubles
          .notesAt(h.vaultPath)
          .callsTo('getNote')
          .skip(readsBefore);
      expect(
        reads.map((c) => c.args['id']),
        contains(_earlierId),
        reason: 'the rebase reads the stored daily note through the domain',
      );
      final editor = h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, 2, reason: 'the footer add version');
      expect(editor.contentMd, 'Slept badly [[Sleep]]');
      expect(editor.title, _earlier);
      expect(_bodyText(tester), 'Slept badly [[Sleep]]');

      await _drain(tester, h);

      final update = cli.callsFor('update').single;
      expect(update.flag('note-id'), _earlierId);
      expect(update.flag('expected-version'), '2');
      expect(update.stdinBody, 'Slept badly [[Sleep]]');
      expect(update.flag('title'), _earlier);
      expect(h.read(editorControllerProvider).status, SaveStatus.clean);
      expect(
        db.db.select('SELECT version FROM notes WHERE id = ?', [
          _earlierId,
        ]).first['version'],
        3,
      );
      expect(find.byKey(const Key('inline-error')), findsNothing);
    },
  );

  testWidgets(
    'when the notes domain finds no stored note the editor still rebases onto the returned version with the unsaved text',
    (tester) async {
      final (h, cli, doubles, _) = await _launch(tester, getNoteIsNull: true);

      await _typeAndChooseCreate(tester);

      final editor = h.read(editorControllerProvider);
      expect(editor.lastSavedVersion, 2);
      expect(editor.contentMd, 'Slept badly [[Sleep]]');
      expect(editor.title, _earlier);
      await _drain(tester, h);
      final update = cli.callsFor('update').single;
      expect(update.flag('expected-version'), '2');
      expect(update.stdinBody, 'Slept badly [[Sleep]]');
      expect(update.flag('title'), _earlier);
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(
        doubles.dailyAt(h.vaultPath).callsTo('addFooterChip'),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'in Source mode a footer chip added through the daily domain rebases the editor onto the returned version',
    (tester) async {
      final (h, cli, doubles, _) = await _launch(tester);
      await _tap(tester, 'editor-source-toggle');
      final readsBefore = doubles.notesCalls(h.vaultPath, 'getNote').length;

      await _typeAndChooseCreate(tester);

      expect(
        doubles.dailyAt(h.vaultPath).callsTo('addFooterChip').single.args,
        {'dailyNoteId': _earlierId, 'topicNoteId': createdTopicId},
      );
      expect(
        doubles
            .notesAt(h.vaultPath)
            .callsTo('getNote')
            .skip(readsBefore)
            .map((c) => c.args['id']),
        contains(_earlierId),
      );
      expect(_bodyText(tester), 'Slept badly [[Sleep]]');
      await _drain(tester, h);
      expect(cli.callsFor('update').single.flag('expected-version'), '2');
    },
  );

  testWidgets(
    'when the footer call fails the editor is not rebased and the body keeps its text with the message inline',
    (tester) async {
      final (h, cli, doubles, _) = await _launch(
        tester,
        footerFailure: MemexException('footer exploded'),
      );
      final readsBefore = doubles.notesCalls(h.vaultPath, 'getNote').length;

      await _typeAndChooseCreate(tester);

      final error = find.byKey(const Key('inline-error'));
      expect(error, findsOneWidget);
      expect(
        find.descendant(
          of: error,
          matching: find.textContaining(
            "Topic created, but it couldn't be linked to this daily note: "
            'footer exploded',
          ),
        ),
        findsOneWidget,
      );
      // TEST-CHANGE (#78): the topic note was created, so the revision bump
      // refreshes the selected note through VaultAccess.notes (one read).
      // The rebase makes no read of its own.
      expect(
        doubles.notesCalls(h.vaultPath, 'getNote').length,
        readsBefore + 1,
        reason: 'only the selected note refresh, no rebase read',
      );
      expect(h.read(editorControllerProvider).lastSavedVersion, 1);
      expect(_bodyText(tester), _typed);
      await _drain(tester, h);
      // The next save is against the unchanged base version.
      expect(cli.callsFor('update').single.flag('expected-version'), '1');
    },
  );
}
