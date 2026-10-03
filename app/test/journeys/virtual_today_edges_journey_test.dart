// WI #22 (A5), beyond the ACs: the virtual Today note's first edit when the
// person leaves the tab, comes back, retries after a failure, or keeps typing
// while an adopting add is in flight. Nothing typed is lost.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

import '../robots/today_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/today_cli_fakes.dart';

const _otherId = '01J9BBBBBBBBBBBBBBBBBBBBBB';
const _plainId = '01J9PPPPPPPPPPPPPPPPPPPPPP';
const _adoptedId = '01J9AAAAAAAAAAAAAAAAAAAAAA';
const _canvasId = '01J9CCCCCCCCCCCCCCCCCCCCCC';

PersistedTab _note(String id) =>
    PersistedTab(kind: PersistedTab.kindNote, id: id);

FakeVaultDb _dbWithOther() =>
    FakeVaultDb.v5()
      ..seedNote(id: _otherId, title: 'Other', content: 'other body\n');

SaveStatus _status(TodayRobot r) => r.h.read(editorControllerProvider).status;

void main() {
  group('leaving the virtual Today tab', () {
    testWidgets(
      'leaving the virtual Today tab before the first save sends the add at once and keeps the other tab active',
      (tester) async {
        final db = _dbWithOther();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db)
            ..onUpdateWrites(db),
          restoredTabs: [_note(_otherId)],
        );
        expect(_status(r), SaveStatus.idle);

        await r.type('hi');
        r.h.read(tabsProvider.notifier).setActive(1);
        await tester.pump();
        await tester.pump();

        expect(r.adds, hasLength(1), reason: 'sent without waiting');
        expect(r.adds.single.stdinBody, 'hi');
        expect(r.tabs.tabs, [
          const NoteTab(createdDailyId),
          const NoteTab(_otherId),
        ]);
        r.expectRealNoteTab(_otherId);
        expect(r.bodyText, 'other body\n');

        await r.waitForSave();
        expect(r.adds, hasLength(1));
        expect(r.updates, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'text typed while the add is in flight is saved to the created note after leaving the virtual Today tab',
      (tester) async {
        final db = _dbWithOther();
        final gate = Completer<void>();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db, gate: gate)
            ..onUpdateWrites(db),
          restoredTabs: [_note(_otherId)],
        );

        await r.type('h');
        await r.waitForSave();
        expect(_status(r), SaveStatus.saving);
        await r.type('hi you');
        await r.waitForSave();
        r.h.read(tabsProvider.notifier).setActive(1);
        await pumpFrames(tester);
        r.expectRealNoteTab(_otherId);

        gate.complete();
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        final update = r.updates.single;
        expect(update.flag('note-id'), createdDailyId);
        expect(update.flag('expected-version'), '1');
        expect(update.stdinBody, 'hi you');
        expect(db.getNote(createdDailyId)!.contentMd, 'hi you');
        r.expectRealNoteTab(_otherId);
        expect(r.tabs.tabs.first, const NoteTab(createdDailyId));
        expect(r.bodyText, 'other body\n');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'coming back to the virtual Today tab while its add is in flight shows the typed text, which is then saved',
      (tester) async {
        final db = _dbWithOther();
        final gate = Completer<void>();
        final r = TodayRobot(tester);
        await r.launch(
          db: db,
          cli: FakeMemexCli()
            ..onAddDailyCreates(db, gate: gate)
            ..onUpdateWrites(db),
          restoredTabs: [_note(_otherId)],
        );

        await r.type('h');
        await r.waitForSave();
        await r.type('hi');
        r.h.read(tabsProvider.notifier).setActive(1);
        await pumpFrames(tester);
        expect(r.bodyText, 'other body\n');
        r.h.read(tabsProvider.notifier).setActive(0);
        await pumpFrames(tester);

        r.expectVirtualToday('2026-10-03');
        expect(r.bodyText, 'hi');
        expect(_status(r), SaveStatus.saving);

        gate.complete();
        await r.waitForSave();

        expect(r.adds, hasLength(1));
        r.expectRealNoteTab(createdDailyId);
        expect(r.updates.single.stdinBody, 'hi');
        expect(r.updates.single.flag('expected-version'), '1');
        expect(r.bodyText, 'hi');
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets(
    'the cursor stays where it is when the virtual Today note becomes the created note',
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

      await r.type('hello');
      await r.waitForSave();
      tester.widget<EditableText>(r.body).controller.selection =
          const TextSelection.collapsed(offset: 2);
      await tester.pump();

      gate.complete();
      await r.waitForSave();

      r.expectRealNoteTab(createdDailyId);
      expect(r.bodyText, 'hello');
      expect(r.bodySelection, const TextSelection.collapsed(offset: 2));
    },
  );

  testWidgets(
    'after a failed add the next edit tries the add again and clears the message',
    (tester) async {
      final db = FakeVaultDb.v5();
      final cli = FakeMemexCli()..onUpdateWrites(db);
      final r = TodayRobot(tester);
      await r.launch(db: db, cli: cli);
      cli.onAddReturns(FakeMemexCli.error('internal', 'database is locked'));

      await r.type('hi');
      await r.waitForSave();
      expect(find.textContaining('database is locked'), findsOneWidget);
      expect(_status(r), SaveStatus.error);

      cli.onAddDailyCreates(db);
      await r.type('hi again');
      await r.waitForSave();

      expect(r.adds, hasLength(2));
      expect(r.adds.last.stdinBody, 'hi again');
      r.expectRealNoteTab(createdDailyId);
      expect(find.textContaining('database is locked'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the virtual Today tab after a failed add sends no second add and keeps the text for later',
    (tester) async {
      final db = _dbWithOther();
      final cli = FakeMemexCli()..onUpdateWrites(db);
      final r = TodayRobot(tester);
      await r.launch(db: db, cli: cli, restoredTabs: [_note(_otherId)]);
      cli.onAddReturns(FakeMemexCli.error('internal', 'database is locked'));

      await r.type('hi');
      await r.waitForSave();
      expect(r.adds, hasLength(1));

      r.h.read(tabsProvider.notifier).setActive(1);
      await r.waitForSave();
      expect(r.adds, hasLength(1), reason: 'no retry without an edit');
      r.expectRealNoteTab(_otherId);

      r.h.read(tabsProvider.notifier).setActive(0);
      await pumpFrames(tester);
      r.expectVirtualToday('2026-10-03');
      expect(r.bodyText, 'hi');
      expect(find.textContaining('database is locked'), findsOneWidget);
    },
  );

  testWidgets(
    'an Adopted note answer with text typed while the add was in flight saves the old text followed by the full typed text',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedNote(id: _adoptedId, title: '2026-10-03', content: 'old\n');
      final gate = Completer<void>();
      final cli = FakeMemexCli()..onUpdateWrites(db);
      cli.on('add', (call) async {
        await gate.future;
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

      await r.type('hi');
      await r.waitForSave();
      await r.type('hi you');
      gate.complete();
      await r.waitForSave();

      r.expectRealNoteTab(_adoptedId);
      final update = r.updates.single;
      expect(update.flag('note-id'), _adoptedId);
      expect(update.flag('expected-version'), '2');
      expect(splitDailyBody(update.stdinBody!).person, 'old\n\nhi you\n');
      expect(r.bodyText, contains('old\n\nhi you\n'));
    },
  );

  testWidgets(
    'opening a past daily note puts the cursor at the end of its focused body while a role-less note opens unfocused',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedNote(id: _plainId, title: 'Plain', content: 'plain body')
        ..seedDailyNote('2026-10-02', id: _otherId);
      db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
        'yesterday\n',
        _otherId,
      ]);
      final r = TodayRobot(tester);
      await r.launch(
        db: db,
        cli: FakeMemexCli(),
        restoredTabs: [
          PersistedTab(kind: PersistedTab.kindCanvas, id: _canvasId),
        ],
      );
      final tabs = r.h.read(tabsProvider.notifier);
      tabs.close(r.tabs.tabs.first);
      await pumpFrames(tester);

      tabs.openOrFocus(const NoteTab(_plainId));
      await pumpFrames(tester);
      expect(r.bodyText, 'plain body');
      expect(r.bodyHasFocus, isFalse);

      tabs.close(const NoteTab(_plainId));
      await pumpFrames(tester);
      tabs.openOrFocus(const NoteTab(_otherId));
      await pumpFrames(tester);
      r.expectDateHeader('Friday, 2 October 2026');
      expect(r.bodyHasFocus, isTrue);
      expect(
        r.bodySelection,
        const TextSelection.collapsed(offset: 'yesterday\n'.length),
      );
    },
  );
}
