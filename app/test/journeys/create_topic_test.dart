// WI #26 (A14): create topic notes from the app and link them from the daily
// note (Req 17, Req 54).
//
// Two paths: `+ New topic` in the Topics sidebar (links today's daily note,
// creating it first when needed) and `[[` autocomplete create inside a daily
// note (links that daily note). Failures leave the UI as it was and show the
// CLI error message inline (Key `inline-error`, dismissible).
//
// Stable Keys: topics-new-topic, new-topic-title-field, new-topic-confirm,
// wikilink-popover-create, inline-error, inline-error-dismiss, editor-body,
// sidebar-mode-topics, topics-unsorted-<noteId>.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/daily_reads.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

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
const _plainId = 'note-plain';
const _raceId = '01J9RRRRRRRRRRRRRRRRRRRRRR';

// ------------------------------------------------------------------ helpers

FakeMemexCli _newCli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..onUpdateWrites(db);

Future<WorkspaceHarness> _launch(
  WidgetTester tester,
  FakeVaultDb db,
  FakeMemexCli cli,
) => pumpWorkspace(
  tester,
  db: db,
  cli: cli,
  // Tall enough that the lazily built Topics tree holds every row.
  surfaceSize: const Size(1600, 1400),
);

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  expect(f, findsOneWidget, reason: key);
  await tester.tap(f);
  await pumpFrames(tester);
}

/// Open Topics mode (Days is the default), press `+ New topic`, type [title]
/// and confirm.
Future<void> _newTopic(
  WidgetTester tester,
  String title, {
  bool confirm = true,
}) async {
  await _tap(tester, 'sidebar-mode-topics');
  await _tap(tester, 'topics-new-topic');
  final field = find.byKey(const Key('new-topic-title-field'));
  expect(field, findsOneWidget);
  await tester.enterText(field, title);
  await tester.pump();
  if (confirm) await _tap(tester, 'new-topic-confirm');
}

Future<void> _openNote(
  WidgetTester tester,
  WorkspaceHarness h,
  String id,
) async {
  h.read(tabsProvider.notifier).openOrFocus(NoteTab(id));
  await pumpFrames(tester);
}

Finder get _bodyField => find.descendant(
  of: find.byKey(const Key('editor-body')),
  matching: find.byType(EditableText),
);

String _bodyText(WidgetTester tester) =>
    tester.widget<EditableText>(_bodyField).controller.text;

/// Type [text] into the open note body and choose the popover's create item.
Future<void> _typeLinkAndChooseCreate(WidgetTester tester, String text) async {
  await tester.enterText(_bodyField, text);
  await tester.pump();
  await _tap(tester, 'wikilink-popover-create');
}

/// Let the editor's 500 ms save debounce and any CLI round trip finish.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await pumpFrames(tester);
}

List<String> _mutations(FakeMemexCli cli) => [
  for (final c in cli.calls)
    if (c.subcommand == 'add' || c.subcommand == 'footer add') c.subcommand,
];

void _expectInlineError(WidgetTester tester, String message) {
  final error = find.byKey(const Key('inline-error'));
  expect(error, findsOneWidget);
  expect(
    find.descendant(of: error, matching: find.textContaining(message)),
    findsOneWidget,
    reason: 'the CLI error message is shown inline',
  );
  expect(find.byKey(const Key('inline-error-dismiss')), findsOneWidget);
}

void main() {
  group('+ New topic (AC1, AC2, AC3)', () {
    testWidgets(
      '+ New topic with title Player Loop calls memex add --role topic --title Player Loop and then memex footer add for the existing daily note of today',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);

        await _newTopic(tester, 'Player Loop');

        expect(_mutations(cli), ['add', 'footer add'], reason: 'in order');
        final add = cli.callsFor('add').single;
        expect(add.flag('role'), 'topic');
        expect(add.flag('title'), 'Player Loop');
        expect(add.flag('vault'), h.vaultPath);
        final footer = cli.callsFor('footer add').single;
        expect(footer.flag('daily-note-id'), _todayId);
        expect(footer.flag('topic-note-id'), createdTopicId);
        expect(footer.flag('vault'), h.vaultPath);
        expect(find.byKey(const Key('inline-error')), findsNothing);
      },
    );

    testWidgets(
      'the title typed into + New topic is trimmed before memex add',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        await _launch(tester, db, cli);

        await _newTopic(tester, '  Player Loop \n');

        expect(cli.callsFor('add').single.flag('title'), 'Player Loop');
      },
    );

    testWidgets(
      'confirming + New topic with a blank title makes no CLI call and creates nothing',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);
        final tabsBefore = h.read(tabsProvider).tabs;

        await _newTopic(tester, '   ');

        expect(_mutations(cli), isEmpty);
        expect(h.read(tabsProvider).tabs, tabsBefore);
        expect(db.footerChips(_todayId), isEmpty);
      },
    );

    testWidgets(
      '+ New topic when today has no daily note first calls memex add --role daily with empty content then memex add --role topic then memex footer add with the new daily note id',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);
        expect(h.read(todayNoteProvider), isNull);

        await _newTopic(tester, 'Player Loop');

        expect(_mutations(cli), ['add', 'add', 'footer add']);
        final adds = cli.callsFor('add');
        expect(adds[0].flag('role'), 'daily');
        expect(adds[0].flag('title'), _today);
        expect(adds[0].stdinBody, '', reason: 'empty content');
        expect(adds[1].flag('role'), 'topic');
        expect(adds[1].flag('title'), 'Player Loop');
        final footer = cli.callsFor('footer add').single;
        expect(footer.flag('daily-note-id'), createdDailyId);
        expect(footer.flag('topic-note-id'), createdTopicId);
        expect(
          h.read(todayNoteProvider)?.noteId,
          createdDailyId,
          reason: 'today now has a daily note and the app re-read the vault',
        );
        expect(find.byKey(const Key('inline-error')), findsNothing);
      },
    );

    testWidgets(
      'after + New topic succeeds the topic note is the active tab, sits under Unsorted in the Topics tree, and the footer of today shows a Player Loop person chip',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newTopic(tester, 'Player Loop');

        expect(h.read(tabsProvider).activeTab, const NoteTab(createdTopicId));
        final row = find.byKey(const Key('topics-unsorted-$createdTopicId'));
        expect(row, findsOneWidget, reason: 'the tree re-read the vault');
        expect(
          find.descendant(of: row, matching: find.text('Player Loop')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('topics-unsorted')), findsOneWidget);
        final chips = h.read(footerChipsProvider(_todayId));
        expect(chips, hasLength(1));
        expect(chips.single.topicTitle, 'Player Loop');
        expect(chips.single.topicNoteId, createdTopicId);
        expect(chips.single.origin, 'person');
        expect(
          h.read(vaultRevisionProvider),
          greaterThan(revisionBefore),
          reason: 'the app bumps vaultRevisionProvider after success',
        );
      },
    );
  });

  group('daily_note_exists race (AC6)', () {
    testWidgets(
      'when memex add --role daily fails with daily_note_exists + New topic uses existing_id for the footer call and still succeeds',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = _newCli(db)..onFooterAdd(db);
        cli.on('add', (call) {
          if (call.flag('role') == 'daily') {
            // Today was created elsewhere between the app's read and this call.
            db.seedDailyNote(_today, id: _raceId);
            return FakeMemexCli.error(
              'daily_note_exists',
              'a daily note for $_today already exists: $_raceId',
              {'date': _today, 'existing_id': _raceId},
            );
          }
          db.seedTopicNote(createdTopicId, call.flag('title')!);
          return FakeMemexCli.ok(
            addDailyStdout(createdTopicId, call.flag('title')!),
          );
        });
        final h = await _launch(tester, db, cli);

        await _newTopic(tester, 'Player Loop');

        expect(_mutations(cli), ['add', 'add', 'footer add']);
        final footer = cli.callsFor('footer add').single;
        expect(footer.flag('daily-note-id'), _raceId);
        expect(footer.flag('topic-note-id'), createdTopicId);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(h.read(tabsProvider).activeTab, const NoteTab(createdTopicId));
        expect(db.footerChips(_raceId).single.topicTitle, 'Player Loop');
      },
    );
  });

  group('+ New topic failures (AC7)', () {
    testWidgets(
      'a title_conflict from memex add shows the message in a dismissible inline error and changes no tree footer or tab',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedNote(id: _plainId, title: 'Player Loop', content: 'x');
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);
        final tabsBefore = h.read(tabsProvider).tabs;
        final activeBefore = h.read(tabsProvider).activeTab;

        await _newTopic(tester, 'Player Loop');

        _expectInlineError(
          tester,
          'a note titled "Player Loop" already exists',
        );
        expect(cli.callsFor('footer add'), isEmpty);
        expect(h.read(tabsProvider).tabs, tabsBefore, reason: 'no tab opens');
        expect(h.read(tabsProvider).activeTab, activeBefore);
        expect(db.footerChips(_todayId), isEmpty);
        expect(
          find.byKey(const Key('topics-unsorted-$createdTopicId')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('topics-unsorted-$_plainId')),
          findsOneWidget,
          reason: 'the Topics tree is as it was',
        );
      },
    );

    testWidgets(
      'tapping the dismiss button removes the inline error from + New topic',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedNote(id: _plainId, title: 'Player Loop', content: 'x');
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        await _launch(tester, db, cli);
        await _newTopic(tester, 'Player Loop');
        expect(find.byKey(const Key('inline-error')), findsOneWidget);

        await _tap(tester, 'inline-error-dismiss');

        expect(find.byKey(const Key('inline-error')), findsNothing);
      },
    );

    testWidgets(
      'a failing memex add --role daily shows the message inline and never creates the topic note',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        cli.on(
          'add',
          (_) => FakeMemexCli.error('internal', 'could not write the vault'),
        );
        final h = await _launch(tester, db, cli);
        final tabsBefore = h.read(tabsProvider).tabs;

        await _newTopic(tester, 'Player Loop');

        _expectInlineError(tester, 'could not write the vault');
        expect(
          cli.callsFor('add'),
          hasLength(1),
          reason: 'the topic add is not attempted after the daily add failed',
        );
        expect(cli.callsFor('footer add'), isEmpty);
        expect(h.read(tabsProvider).tabs, tabsBefore);
        expect(h.read(todayNoteProvider), isNull);
      },
    );

    testWidgets(
      'a role_rule failure from memex footer add shows the message inline with no tab opened and no chip in the footer',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);
        final cli = _newCli(db);
        cli.on(
          'add',
          (_) => FakeMemexCli.ok(addDailyStdout(createdTopicId, 'Player Loop')),
        );
        cli.on(
          'footer add',
          (_) => FakeMemexCli.error(
            'role_rule',
            'footer chips link a daily note to a topic note',
          ),
        );
        final h = await _launch(tester, db, cli);
        final tabsBefore = h.read(tabsProvider).tabs;
        final activeBefore = h.read(tabsProvider).activeTab;

        await _newTopic(tester, 'Player Loop');

        _expectInlineError(
          tester,
          'footer chips link a daily note to a topic note',
        );
        expect(h.read(tabsProvider).tabs, tabsBefore, reason: 'no tab opens');
        expect(h.read(tabsProvider).activeTab, activeBefore);
        expect(db.footerChips(_todayId), isEmpty);
        expect(
          find.byKey(const Key('topics-unsorted-$createdTopicId')),
          findsNothing,
        );
      },
    );
  });

  group('autocomplete create inside a daily note (AC4)', () {
    testWidgets(
      'inside an earlier daily note choosing Create new note titled Sleep calls memex add --role topic then memex footer add with that daily note id not today and inserts [[Sleep]]',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedDailyNote(_earlier, id: _earlierId);
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);
        await _openNote(tester, h, _earlierId);

        await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

        expect(_mutations(cli), ['add', 'footer add'], reason: 'in order');
        final add = cli.callsFor('add').single;
        expect(add.flag('role'), 'topic');
        expect(add.flag('title'), 'Sleep');
        expect(add.stdinBody, '# Sleep\n\n', reason: 'body as today');
        final footer = cli.callsFor('footer add').single;
        expect(footer.flag('daily-note-id'), _earlierId);
        expect(footer.flag('daily-note-id'), isNot(_todayId));
        expect(footer.flag('topic-note-id'), createdTopicId);
        expect(_bodyText(tester), 'Slept badly [[Sleep]]');
        expect(db.footerChips(_earlierId).single.topicTitle, 'Sleep');
        expect(db.footerChips(_todayId), isEmpty);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        await _drain(tester);
      },
    );
  });

  group('autocomplete create in a non-daily note (AC5)', () {
    testWidgets(
      'in a role-less note choosing Create new note titled Sleep calls memex add without --role and makes no memex footer add call',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedNote(id: _plainId, title: 'Scratch', content: '');
        final cli = _newCli(db)
          ..onAddCreates(db)
          ..onFooterAdd(db);
        final h = await _launch(tester, db, cli);
        await _openNote(tester, h, _plainId);

        await _typeLinkAndChooseCreate(tester, 'see [[Sleep');

        final add = cli.callsFor('add').single;
        expect(add.hasFlag('role'), isFalse);
        expect(add.flag('title'), 'Sleep');
        expect(add.stdinBody, '# Sleep\n\n');
        expect(cli.callsFor('footer add'), isEmpty);
        expect(_bodyText(tester), 'see [[Sleep]]');
        expect(db.footerChips(_todayId), isEmpty);
        await _drain(tester);
      },
    );
  });

  group('autocomplete create failures in a daily note (AC7)', () {
    testWidgets(
      'a title_conflict from memex add in a daily note shows the message in a dismissible inline error and leaves the body without a wikilink',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedDailyNote(_earlier, id: _earlierId);
        final cli = _newCli(db)..onFooterAdd(db);
        cli.on(
          'add',
          (_) => FakeMemexCli.error(
            'title_conflict',
            'a note titled "Sleep" already exists',
            {'existing_id': 'note-elsewhere'},
          ),
        );
        final h = await _launch(tester, db, cli);
        await _openNote(tester, h, _earlierId);
        final tabsBefore = h.read(tabsProvider).tabs;

        await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

        _expectInlineError(tester, 'a note titled "Sleep" already exists');
        expect(cli.callsFor('footer add'), isEmpty);
        expect(
          _bodyText(tester),
          'Slept badly [[Sleep',
          reason: 'body as it was',
        );
        expect(h.read(tabsProvider).tabs, tabsBefore);
        expect(db.footerChips(_earlierId), isEmpty);

        await _tap(tester, 'inline-error-dismiss');
        expect(find.byKey(const Key('inline-error')), findsNothing);
        await _drain(tester);
      },
    );

    testWidgets(
      'a role_rule failure from memex footer add in a daily note shows the message inline and leaves the body without a wikilink and the footer without a chip',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedDailyNote(_today, id: _todayId)
          ..seedDailyNote(_earlier, id: _earlierId);
        final cli = _newCli(db);
        cli.on(
          'add',
          (_) => FakeMemexCli.ok(addDailyStdout(createdTopicId, 'Sleep')),
        );
        cli.on(
          'footer add',
          (_) => FakeMemexCli.error(
            'role_rule',
            'footer chips link a daily note to a topic note',
          ),
        );
        final h = await _launch(tester, db, cli);
        await _openNote(tester, h, _earlierId);
        final tabsBefore = h.read(tabsProvider).tabs;

        await _typeLinkAndChooseCreate(tester, 'Slept badly [[Sleep');

        _expectInlineError(
          tester,
          'footer chips link a daily note to a topic note',
        );
        expect(
          _bodyText(tester),
          'Slept badly [[Sleep',
          reason: 'body as it was',
        );
        expect(h.read(tabsProvider).tabs, tabsBefore);
        expect(db.footerChips(_earlierId), isEmpty);
        await _drain(tester);
      },
    );
  });
}
