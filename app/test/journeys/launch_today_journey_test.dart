// WI #22 (A5): the app opens on today's daily note, with the fixed date
// header, the `Today` badge and the virtual (unsaved) Today note.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

import '../robots/today_robot.dart';
import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _todayId = '01J9TTTTTTTTTTTTTTTTTTTTTT';
const _existingId = '01J9EEEEEEEEEEEEEEEEEEEEEE';
const _adoptedId = '01J9AAAAAAAAAAAAAAAAAAAAAA';
const _canvasId = '01J9CCCCCCCCCCCCCCCCCCCCCC';

/// C1 sample: today already has a daily note (e.g. the agent captured first).
MemexResult _dailyExists() => FakeMemexCli.error(
  'daily_note_exists',
  'a daily note for 2026-10-03 already exists: $_existingId',
  {'date': '2026-10-03', 'existing_id': _existingId},
);

void main() {
  group('launch lands on today (AC1, AC10)', () {
    testWidgets(
      'launch opens the daily note for 2026-10-03 as the active tab ahead of the restored canvas tab, with header, Today badge and the cursor at the end of the focused body',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: _todayId,
            title: '2026-10-03',
            content: 'Morning pages\n',
            role: 'daily',
            version: 4,
          );
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()..onUpdateWrites(db),
          clock: FakeClock(DateTime(2026, 10, 3, 9)),
          restoredTabs: [
            PersistedTab(kind: PersistedTab.kindCanvas, id: _canvasId),
          ],
        );

        expect(r.tabs.tabs, [
          const NoteTab(_todayId),
          const CanvasTab(_canvasId),
        ]);
        expect(r.tabs.activeIndex, 0);
        r.expectRealNoteTab(_todayId);
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectTodayBadge(shown: true);
        expect(r.bodyText, 'Morning pages\n');
        expect(r.bodyHasFocus, isTrue);
        expect(
          r.bodySelection,
          const TextSelection.collapsed(offset: 'Morning pages\n'.length),
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('virtual Today (AC2)', () {
    testWidgets(
      'a vault with no daily notes launches on an empty virtual Today tab with header and badge and writes nothing',
      (tester) async {
        final db = FakeVaultDb.v5();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db)
            ..onUpdateWrites(db),
        );
        await r.waitForSave();

        r.expectVirtualToday('2026-10-03');
        expect(r.tabs.tabs, hasLength(1));
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectTodayBadge(shown: true);
        expect(r.bodyText, isEmpty);
        expect(r.bodyHasFocus, isTrue);
        expect(r.adds, isEmpty);
        expect(r.updates, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a vault whose only daily note is yesterday launches on the virtual Today tab ahead of nothing else',
      (tester) async {
        final db = FakeVaultDb.v5()..seedDailyNote('2026-10-02');
        final r = TodayRobot(tester);
        await r.launch(db: db, cli: FakeMemexCli());

        r.expectVirtualToday('2026-10-03');
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectTodayBadge(shown: true);
        expect(r.adds, isEmpty);
      },
    );

    testWidgets(
      'the note menu offers no enabled Delete note item for the virtual Today note',
      (tester) async {
        final db = FakeVaultDb.v5();
        final r = TodayRobot(tester);
        await r.launch(db: db, cli: FakeMemexCli());
        // Precondition: the virtual Today note is on screen.
        r.expectVirtualToday('2026-10-03');
        r.expectDateHeader('Saturday, 3 October 2026');

        await r.openNoteMenu();

        final delete = find.byKey(const Key('note-menu-delete'));
        if (delete.evaluate().isNotEmpty) {
          final item = tester.widget<MenuItemButton>(
            find
                .ancestor(of: delete, matching: find.byType(MenuItemButton))
                .first,
          );
          expect(
            item.onPressed,
            isNull,
            reason: 'Delete note must be disabled',
          );
        }
        expect(r.adds, isEmpty);
      },
    );
  });

  group('first edit creates the daily note (AC3)', () {
    testWidgets(
      'typing hi makes exactly one add with role daily and title 2026-10-03, then the next edit saves through update with the created version',
      (tester) async {
        final db = FakeVaultDb.v5();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db)
            ..onUpdateWrites(db),
          restoredTabs: [
            PersistedTab(kind: PersistedTab.kindCanvas, id: _canvasId),
          ],
        );
        r.expectVirtualToday('2026-10-03');

        await r.type('hi');
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        final add = r.adds.single;
        expect(add.flag('role'), 'daily');
        expect(add.flag('title'), '2026-10-03');
        expect(add.flag('vault'), r.h.vaultPath);
        expect(add.stdinBody, contains('hi'));
        expect(r.updates, isEmpty, reason: 'the add carried the text');

        // The tab becomes the created note, in the same position.
        r.expectRealNoteTab(createdDailyId);
        expect(r.tabs.tabs, [
          const NoteTab(createdDailyId),
          const CanvasTab(_canvasId),
        ]);
        expect(r.tabs.activeIndex, 0);
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectTodayBadge(shown: true);
        expect(r.bodyText, contains('hi'));

        await r.type('hi there');
        await r.waitForSave();

        expect(r.adds, hasLength(1), reason: 'no second add');
        expect(r.updates, isNotEmpty);
        final update = r.updates.last;
        expect(update.flag('note-id'), createdDailyId);
        expect(update.flag('expected-version'), '1');
        expect(update.stdinBody, contains('hi there'));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'keystrokes typed while the first add is in flight make no second add and are saved to the created note',
      (tester) async {
        final db = FakeVaultDb.v5();
        final gate = Completer<void>();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db, gate: gate)
            ..onUpdateWrites(db),
        );

        await r.type('h');
        await r.waitForSave();
        expect(r.adds, hasLength(1), reason: 'the first edit starts the add');

        await r.type('hi');
        await r.waitForSave();
        await r.type('hi you');
        await r.waitForSave();
        expect(r.adds, hasLength(1), reason: 'still in flight: no second add');

        gate.complete();
        await r.waitForSave();
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        r.expectRealNoteTab(createdDailyId);
        expect(r.bodyText, contains('hi you'));
        // Nothing typed is lost: the stored note ends up with the full text.
        final stored = db.getNote(createdDailyId)!;
        expect(stored.contentMd, contains('hi you'));
        for (final u in r.updates) {
          expect(u.flag('note-id'), createdDailyId);
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an Adopted note answer opens the adopted note with its old text and the typed text and sends no update',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: _adoptedId, title: '2026-10-03', content: 'old\n');
        final cli = FakeMemexCli()..onUpdateWrites(db);
        cli.on('add', (call) {
          // What the CLI does on a Q2 adoption: role daily, C3.1 append.
          db.db.execute(
            'UPDATE notes SET frontmatter = ?, content_md = ?, version = 2 '
            'WHERE id = ?',
            [
              '{"role":"daily"}',
              'old\n\n${call.stdinBody}\n<!-- memex:topics -->\n',
              _adoptedId,
            ],
          );
          return FakeMemexCli.ok(
            addDailyStdout(_adoptedId, '2026-10-03', adopted: true),
          );
        });
        final r = TodayRobot(tester);
        await r.launch(db: db, cli: cli);
        r.expectVirtualToday('2026-10-03');

        await r.type('hi');
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        r.expectRealNoteTab(_adoptedId);
        expect(r.bodyText, contains('old'));
        expect(r.bodyText, contains('hi'));
        expect(r.updates, isEmpty, reason: 'the CLI already appended the text');

        await r.type('${r.bodyText}more');
        await r.waitForSave();
        expect(r.updates.last.flag('note-id'), _adoptedId);
        expect(r.updates.last.flag('expected-version'), '2');
        expect(db.getNote(_adoptedId)!.contentMd, contains('old'));
      },
    );
  });

  group('first edit when today already exists (AC4)', () {
    testWidgets(
      'daily_note_exists switches the tab to existing_id and appends the typed text to its person section through update',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddReturns(_dailyExists());
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: cli,
          restoredTabs: [
            PersistedTab(kind: PersistedTab.kindCanvas, id: _canvasId),
          ],
        );
        r.expectVirtualToday('2026-10-03');
        // The agent captures to today after launch: the daily note now exists.
        db.seedNote(
          id: _existingId,
          title: '2026-10-03',
          content: 'Morning pages\n<!-- memex:topics -->\n',
          role: 'daily',
          version: 5,
        );

        await r.type('hi');
        await r.waitForSave();
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        r.expectRealNoteTab(_existingId);
        expect(r.tabs.tabs, [
          const NoteTab(_existingId),
          const CanvasTab(_canvasId),
        ]);
        expect(r.tabs.activeIndex, 0);
        expect(r.updates, isNotEmpty);
        final update = r.updates.first;
        expect(update.flag('note-id'), _existingId);
        expect(update.flag('expected-version'), '5');
        expect(
          splitDailyBody(update.stdinBody!).person,
          'Morning pages\n\nhi\n',
        );
        expect(
          splitDailyBody(db.getNote(_existingId)!.contentMd).person,
          'Morning pages\n\nhi\n',
        );
        expect(r.bodyText, contains('Morning pages'));
        expect(r.bodyText, contains('hi'));
        r.expectDateHeader('Saturday, 3 October 2026');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'daily_note_exists with an empty existing note saves just the typed text with no leading blank line',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()
          ..onUpdateWrites(db)
          ..onAddReturns(_dailyExists());
        final r = TodayRobot(tester);
        await r.launch(db: db, cli: cli);
        r.expectVirtualToday('2026-10-03');
        db.seedNote(
          id: _existingId,
          title: '2026-10-03',
          content: '<!-- memex:topics -->\n',
          role: 'daily',
          version: 2,
        );

        await r.type('hi');
        await r.waitForSave();
        await r.waitForSave();

        r.expectRealNoteTab(_existingId);
        expect(r.updates, isNotEmpty);
        expect(r.updates.first.flag('note-id'), _existingId);
        expect(r.updates.first.flag('expected-version'), '2');
        expect(splitDailyBody(r.updates.first.stdinBody!).person, 'hi\n');
      },
    );
  });

  group('first edit fails (AC5)', () {
    testWidgets(
      'any other add failure keeps the typed text in the virtual Today editor and shows the CLI message inline',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = FakeMemexCli()..onUpdateWrites(db);
        cli.onAddReturns(FakeMemexCli.error('internal', 'database is locked'));
        final r = TodayRobot(tester);
        await r.launch(db: db, cli: cli);

        await r.type('hi');
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        expect(r.bodyText, 'hi');
        expect(find.textContaining('database is locked'), findsOneWidget);
        r.expectVirtualToday('2026-10-03');
        r.expectDateHeader('Saturday, 3 October 2026');
        expect(r.updates, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('midnight (AC8, AC9)', () {
    testWidgets(
      'at 23:59 with the note for 2026-10-03 open, two minutes later the badge is gone, the header is unchanged and the active tab stays',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: _todayId,
            title: '2026-10-03',
            content: 'Late note\n',
            role: 'daily',
          );
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli(),
          clock: FakeClock(DateTime(2026, 10, 3, 23, 59)),
          restoredTabs: [
            PersistedTab(kind: PersistedTab.kindCanvas, id: _canvasId),
          ],
        );
        r.expectRealNoteTab(_todayId);
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectTodayBadge(shown: true);
        final before = List<WorkspaceTab>.of(r.tabs.tabs);

        await r.advanceClock(const Duration(minutes: 2));

        r.expectTodayBadge(shown: false);
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectRealNoteTab(_todayId);
        expect(r.tabs.tabs, before);
        expect(r.tabs.activeIndex, 0);
        expect(r.bodyText, 'Late note\n');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a virtual Today tab opened on 2026-10-03 keeps that date after midnight and typing creates the note titled 2026-10-03',
      (tester) async {
        final db = FakeVaultDb.v5();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db)
            ..onUpdateWrites(db),
          clock: FakeClock(DateTime(2026, 10, 3, 23, 59)),
        );
        r.expectVirtualToday('2026-10-03');
        r.expectTodayBadge(shown: true);

        await r.advanceClock(const Duration(minutes: 2));

        r.expectVirtualToday('2026-10-03');
        expect(r.tabs.tabs, hasLength(1));
        r.expectDateHeader('Saturday, 3 October 2026');
        r.expectTodayBadge(shown: false);

        await r.type('late');
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        expect(r.adds.single.flag('title'), '2026-10-03');
        expect(r.adds.single.flag('role'), 'daily');
        r.expectRealNoteTab(createdDailyId);
        expect(db.getNote(createdDailyId)!.title, '2026-10-03');
        expect(tester.takeException(), isNull);
      },
    );
  });
}
