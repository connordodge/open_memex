// WI #26 (A14): behaviour beyond the acceptance criteria. Creating a topic
// from `[[` autocomplete in a daily note changes that note on the server
// (`memex footer add` bumps its version), so the editor must rebase onto the
// returned version; the Source surface wires the same create path; the
// virtual Today note (no row yet) has no footer to add a chip to.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
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

FakeMemexCli _newCli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..onUpdateWrites(db)
  ..onAddCreates(db)
  ..onFooterAdd(db);

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

Finder get _bodyField => find.descendant(
  of: find.byKey(const Key('editor-body')),
  matching: find.byType(EditableText),
);

String _bodyText(WidgetTester tester) =>
    tester.widget<EditableText>(_bodyField).controller.text;

Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await pumpFrames(tester);
}

Future<void> _typeLinkAndChooseCreate(WidgetTester tester, String text) async {
  await tester.enterText(_bodyField, text);
  await tester.pump();
  await _tap(tester, 'wikilink-popover-create');
}

void main() {
  testWidgets(
    'the save after creating a topic in a daily note autocomplete uses the version memex footer add returned and keeps the typed text',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedDailyNote(_earlier, id: _earlierId);
      final cli = _newCli(db);
      final h = await _launch(tester, db, cli);
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
      await pumpFrames(tester);

      await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');
      await _drain(tester);

      final footerVersion = db.db.select(
        'SELECT version FROM notes WHERE id = ?',
        [_earlierId],
      ).first['version'];
      expect(footerVersion, 3, reason: 'footer add (2) then the save (3)');
      final update = cli.callsFor('update').single;
      expect(update.flag('note-id'), _earlierId);
      expect(update.flag('expected-version'), '2');
      expect(update.stdinBody, 'Slept badly [[Sleep]]');
      expect(h.read(editorControllerProvider).status, SaveStatus.clean);
      expect(find.byKey(const Key('inline-error')), findsNothing);
    },
  );

  testWidgets(
    'the footer of the daily note shows a chip for the topic created from its autocomplete',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedDailyNote(_earlier, id: _earlierId);
      final cli = _newCli(db);
      final h = await _launch(tester, db, cli);
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
      await pumpFrames(tester);

      await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

      expect(
        find.byKey(const Key('footer-chip-$createdTopicId')),
        findsOneWidget,
      );
      await _drain(tester);
    },
  );

  testWidgets(
    'in Source mode of a daily note choosing Create new note calls memex add --role topic then memex footer add with that daily note id',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedDailyNote(_earlier, id: _earlierId);
      final cli = _newCli(db);
      final h = await _launch(tester, db, cli);
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
      await pumpFrames(tester);
      await _tap(tester, 'editor-source-toggle');

      await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

      expect(cli.callsFor('add').single.flag('role'), 'topic');
      expect(
        cli.callsFor('footer add').single.flag('daily-note-id'),
        _earlierId,
      );
      expect(_bodyText(tester), 'Slept badly [[Sleep]]');
      await _drain(tester);
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(
        cli.callsFor('update').single.flag('expected-version'),
        '2',
        reason: 'the Source surface rebases on the footer version too',
      );
    },
  );

  testWidgets(
    'in Source mode of a daily note a failed create shows the message in a dismissible inline error and leaves the body as it was',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedDailyNote(_today, id: _todayId)
        ..seedDailyNote(_earlier, id: _earlierId);
      final cli = _newCli(db);
      cli.on(
        'add',
        (_) => FakeMemexCli.error(
          'title_conflict',
          'a note titled "Sleep" already exists',
        ),
      );
      final h = await _launch(tester, db, cli);
      h.read(tabsProvider.notifier).openOrFocus(const NoteTab(_earlierId));
      await pumpFrames(tester);
      await _tap(tester, 'editor-source-toggle');

      await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

      expect(
        find.descendant(
          of: find.byKey(const Key('inline-error')),
          matching: find.textContaining('a note titled "Sleep" already exists'),
        ),
        findsOneWidget,
      );
      expect(_bodyText(tester), 'Slept badly [[Sleep');
      await _tap(tester, 'inline-error-dismiss');
      expect(find.byKey(const Key('inline-error')), findsNothing);
      await _drain(tester);
    },
  );

  testWidgets(
    'in the virtual Today note choosing Create new note makes no memex footer add call and creates a role-less note',
    (tester) async {
      final db = FakeVaultDb.v5();
      final cli = _newCli(db);
      await _launch(tester, db, cli);

      await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

      final add = cli.callsFor('add').single;
      expect(add.hasFlag('role'), isFalse);
      expect(add.flag('title'), 'Sleep');
      expect(cli.callsFor('footer add'), isEmpty);
      expect(_bodyText(tester), 'Slept badly [[Sleep]]');
      await _drain(tester);
    },
  );
}
