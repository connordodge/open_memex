// WI #26 (A14), Req 54: `memex add` creates the topic note but
// `memex footer add` fails. The note stays (no rollback), a dismissible inline
// error says it was created but not linked and carries the CLI message, and
// the vault views refresh so the note shows under Unsorted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/today_cli_fakes.dart';

const _today = '2026-10-03';
const _todayId = 'daily-2026-10-03';
const _earlier = '2026-09-30';
const _earlierId = 'daily-2026-09-30';
const _footerMessage = 'footer chips link a daily note to a topic note';

/// `add` really creates rows in [db]; `footer add` fails with `role_rule`.
FakeMemexCli _cliFooterFails(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..onUpdateWrites(db)
  ..onAddCreates(db)
  ..on('footer add', (_) => FakeMemexCli.error('role_rule', _footerMessage));

Future<WorkspaceHarness> _launch(
  WidgetTester tester,
  FakeVaultDb db,
  FakeMemexCli cli,
) => pumpWorkspace(
  tester,
  db: db,
  cli: cli,
  surfaceSize: const Size(1600, 1400),
);

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  expect(f, findsOneWidget, reason: key);
  await tester.tap(f);
  await pumpFrames(tester);
}

void _expectNotLinkedError(WidgetTester tester, String where) {
  final error = find.byKey(const Key('inline-error'));
  expect(error, findsOneWidget);
  for (final part in [
    "Topic created, but it couldn't be linked to $where: ",
    _footerMessage,
  ]) {
    expect(
      find.descendant(of: error, matching: find.textContaining(part)),
      findsOneWidget,
      reason: part,
    );
  }
  expect(find.byKey(const Key('inline-error-dismiss')), findsOneWidget);
}

void main() {
  testWidgets(
    'when memex add creates the topic and memex footer add fails + New topic shows a dismissible inline error with the footer message and the topic appears under Unsorted',
    (tester) async {
      final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
      final cli = _cliFooterFails(db);
      final h = await _launch(tester, db, cli);
      final tabsBefore = h.read(tabsProvider).tabs;
      await _tap(tester, 'sidebar-mode-topics');
      await _tap(tester, 'topics-new-topic');
      await tester.enterText(
        find.byKey(const Key('new-topic-title-field')),
        'Player Loop',
      );
      await tester.pump();

      await _tap(tester, 'new-topic-confirm');

      expect(cli.callsFor('add'), hasLength(1));
      expect(cli.callsFor('footer add'), hasLength(1));
      _expectNotLinkedError(tester, 'today');
      final row = find.byKey(const Key('topics-unsorted-$createdTopicId'));
      expect(row, findsOneWidget, reason: 'the created note shows in the tree');
      expect(
        find.descendant(of: row, matching: find.text('Player Loop')),
        findsOneWidget,
      );
      expect(h.read(tabsProvider).tabs, tabsBefore, reason: 'no tab opens');
      expect(db.footerChips(_todayId), isEmpty);

      await _tap(tester, 'inline-error-dismiss');
      expect(find.byKey(const Key('inline-error')), findsNothing);
    },
  );

  testWidgets(
    'when memex add creates the topic and memex footer add fails in daily note autocomplete the inline error names the footer message and the body is left as it was',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedDailyNote(_earlier, id: _earlierId);
      final cli = _cliFooterFails(db);
      final h = await _launch(tester, db, cli);
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
      await pumpFrames(tester);
      final body = find.descendant(
        of: find.byKey(const Key('editor-body')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(body, 'Slept badly [[Sleep');
      await tester.pump();

      await _tap(tester, 'wikilink-popover-create');

      expect(cli.callsFor('add'), hasLength(1));
      _expectNotLinkedError(tester, 'this daily note');
      expect(
        tester.widget<EditableText>(body).controller.text,
        'Slept badly [[Sleep',
      );
      expect(db.footerChips(_earlierId), isEmpty);

      await _tap(tester, 'sidebar-mode-topics');
      expect(
        find.byKey(const Key('topics-unsorted-$createdTopicId')),
        findsOneWidget,
        reason: 'the created note shows in the tree',
      );
      await tester.pump(const Duration(milliseconds: 600));
      await pumpFrames(tester);
    },
  );
}
