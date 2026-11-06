// WI #31 (A13): delete a note from the editor's note menu.
//
// Journeys run through the whole workspace with the #18 harness: a seeded
// FakeVaultDb, a FakeMemexCli whose `rm` handler (note_cli_fakes.dart) deletes
// the row, and a pinned clock. Never pumpAndSettle the workspace.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart' show NoteListItem;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/note_cli_fakes.dart';
import '../support/vault_scoped_reads.dart';

const _alphaId = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _betaId = '01J9Z8Y7X6W5V4T3S2R1Q0P9N9';
const _dailyId = '01J9Z8Y7X6W5V4T3S2R1Q0P9NA';

const _menuButton = Key('note-menu-button');
const _menuDelete = Key('note-menu-delete');
const _dialog = Key('delete-note-dialog');
const _confirm = Key('delete-note-confirm');
const _cancel = Key('delete-note-cancel');
const _inlineError = Key('inline-error');
const _inlineErrorDismiss = Key('inline-error-dismiss');

/// A note's row in the sidebar's Topics mode: the role-less notes of these
/// journeys sit under Unsorted (#24).
Key _listItem(String id) => Key('topics-unsorted-$id');
Key _tab(String id) => Key('tab-note-$id');

FakeVaultDb _seededDb() {
  final db = FakeVaultDb.v5();
  db.seedNote(
    id: _alphaId,
    title: 'Alpha note',
    content: 'alpha body',
    version: 7,
    updatedAt: 1759500002000,
  );
  db.seedNote(
    id: _betaId,
    title: 'Beta note',
    content: 'beta body',
    version: 3,
    updatedAt: 1759500001000,
  );
  db.seedNote(
    id: _dailyId,
    title: '2026-10-02',
    content: 'daily body',
    role: 'daily',
    version: 4,
    updatedAt: 1759500000000,
  );
  return db;
}

/// A harness whose `rm` behaves like `memex rm` against [db].
Future<WorkspaceHarness> _pump(
  WidgetTester tester,
  FakeVaultDb db, {
  void Function(FakeMemexCli cli)? configure,
}) async {
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onRm(db);
  configure?.call(cli);
  final h = await pumpWorkspace(tester, db: db, cli: cli);
  // The launch opens today's daily note (#22); these journeys start from an
  // empty workspace, so close it.
  final tabs = h.read(tabsProvider.notifier);
  for (final tab in [...h.read(tabsProvider).tabs]) {
    tabs.close(tab);
  }
  // The sidebar opens in Days mode (#23); the note list is the Topics mode,
  // where role-less notes show under Unsorted (#24).
  await tester.tap(find.byKey(const Key('sidebar-mode-topics')));
  await pumpFrames(tester);
  return h;
}

Future<void> _openNote(WidgetTester tester, String id) async {
  if (id == _dailyId) {
    // Daily notes are not listed under Unsorted; open the tab directly.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Workspace)),
    );
    container.read(tabsProvider.notifier).openOrFocus(NoteTab(id));
  } else {
    await tester.tap(find.byKey(_listItem(id)));
  }
  await pumpFrames(tester);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(_menuButton));
  await pumpFrames(tester);
}

Future<void> _chooseDelete(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.tap(find.byKey(_menuDelete));
  await pumpFrames(tester);
}

Finder _inDialog(Finder f) =>
    find.descendant(of: find.byKey(_dialog), matching: f);

void main() {
  group('note menu Delete item (AC1)', () {
    testWidgets(
      'opening the note menu shows Delete note with Key note-menu-delete',
      (tester) async {
        final h = await _pump(tester, _seededDb());
        await _openNote(tester, _alphaId);

        expect(find.byKey(_menuDelete), findsNothing);
        await _openMenu(tester);

        expect(find.byKey(const Key('note-menu')), findsOneWidget);
        final item = find.byKey(_menuDelete);
        expect(item, findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('note-menu')),
            matching: item,
          ),
          findsOneWidget,
          reason: 'the item lives inside NoteMenu',
        );
        expect(tester.widget(item), isA<MenuItemButton>());
        expect(
          find.descendant(of: item, matching: find.text('Delete note')),
          findsOneWidget,
        );
        expect(h.cli.callsFor('rm'), isEmpty);
      },
    );
  });

  group('confirmation dialog (AC2, AC3)', () {
    testWidgets(
      'choosing Delete note shows the confirmation dialog with the note title and makes no CLI call',
      (tester) async {
        final h = await _pump(tester, _seededDb());
        await _openNote(tester, _alphaId);
        expect(find.byKey(_dialog), findsNothing);

        await _chooseDelete(tester);

        expect(find.byKey(_dialog), findsOneWidget);
        expect(tester.widget(find.byKey(_dialog)), isA<AlertDialog>());
        expect(_inDialog(find.text('Delete note?')), findsOneWidget);
        expect(
          _inDialog(
            find.text('"Alpha note" will be deleted. This can\'t be undone.'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_cancel),
            matching: find.text('Cancel'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(_confirm),
            matching: find.text('Delete'),
          ),
          findsOneWidget,
        );
        expect(h.cli.callsFor('rm'), isEmpty, reason: 'nothing deleted yet');
        expect(h.cli.calls.where((c) => c.args.first == 'rm'), isEmpty);
        expect(find.byKey(_tab(_alphaId)), findsOneWidget);
      },
    );

    testWidgets('the dialog names the note that is open, not another note', (
      tester,
    ) async {
      await _pump(tester, _seededDb());
      await _openNote(tester, _alphaId);
      await _openNote(tester, _betaId);

      await _chooseDelete(tester);

      expect(
        _inDialog(
          find.text('"Beta note" will be deleted. This can\'t be undone.'),
        ),
        findsOneWidget,
      );
      expect(_inDialog(find.textContaining('Alpha note')), findsNothing);
    });

    testWidgets(
      'Cancel closes the dialog, makes no CLI call, and leaves the tab and the note listed',
      (tester) async {
        final db = _seededDb();
        final h = await _pump(tester, db);
        await _openNote(tester, _alphaId);
        final revisionBefore = h.read(vaultRevisionProvider);
        await _chooseDelete(tester);
        expect(find.byKey(_dialog), findsOneWidget);

        await tester.tap(find.byKey(_cancel));
        await pumpFrames(tester);

        expect(find.byKey(_dialog), findsNothing);
        expect(h.cli.callsFor('rm'), isEmpty);
        expect(find.byKey(_tab(_alphaId)), findsOneWidget);
        expect(find.byKey(_listItem(_alphaId)), findsOneWidget);
        expect(db.getNote(_alphaId), isNotNull);
        expect(find.byKey(_inlineError), findsNothing);
        expect(h.read(vaultRevisionProvider), revisionBefore);
        expect(h.read(tabsProvider).tabs, [const NoteTab(_alphaId)]);
      },
    );
  });

  group('confirming the delete (AC4, AC5, AC6)', () {
    testWidgets(
      'Delete calls memex rm with the vault, note id and last saved version',
      (tester) async {
        final h = await _pump(tester, _seededDb());
        await _openNote(tester, _alphaId);
        await _chooseDelete(tester);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        final calls = h.cli.callsFor('rm');
        expect(calls, hasLength(1));
        expect(calls.single.args, [
          'rm',
          '--vault',
          h.vaultPath,
          '--note-id',
          _alphaId,
          '--expected-version',
          '7',
        ]);
        expect(find.byKey(_dialog), findsNothing);
      },
    );

    testWidgets(
      'after a successful delete the tab closes, the note leaves the sidebar list and lists refresh',
      (tester) async {
        final db = _seededDb();
        final h = await _pump(tester, db);
        await _openNote(tester, _alphaId);
        expect(find.byKey(_tab(_alphaId)), findsOneWidget);
        expect(find.byKey(_listItem(_alphaId)), findsOneWidget);
        final revisionBefore = h.read(vaultRevisionProvider);
        await _chooseDelete(tester);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(db.getNote(_alphaId), isNull);
        expect(find.byKey(_tab(_alphaId)), findsNothing);
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(find.byKey(const Key('empty-workspace')), findsOneWidget);
        expect(find.byKey(_listItem(_alphaId)), findsNothing);
        expect(find.byKey(_listItem(_betaId)), findsOneWidget);
        expect(
          readScoped(
            h.container,
            notesListAsyncProvider,
            const <NoteListItem>[],
          ).map((n) => n.id),
          isNot(contains(_alphaId)),
        );
        expect(h.read(vaultRevisionProvider), greaterThan(revisionBefore));
        expect(find.byKey(_inlineError), findsNothing);
        expect(find.byKey(_dialog), findsNothing);
      },
    );

    testWidgets('deleting one note leaves other open tabs open', (
      tester,
    ) async {
      final h = await _pump(tester, _seededDb());
      await _openNote(tester, _alphaId);
      // #266: a plain click navigates in place; Cmd opens a second tab.
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await _openNote(tester, _betaId);
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      expect(h.read(tabsProvider).tabs, hasLength(2));

      await _chooseDelete(tester);
      await tester.tap(find.byKey(_confirm));
      await pumpFrames(tester);

      expect(h.cli.callsFor('rm').single.flag('note-id'), _betaId);
      expect(h.cli.callsFor('rm').single.flag('expected-version'), '3');
      expect(find.byKey(_tab(_betaId)), findsNothing);
      expect(find.byKey(_tab(_alphaId)), findsOneWidget);
      expect(h.read(tabsProvider).tabs, [const NoteTab(_alphaId)]);
      expect(find.byKey(_listItem(_alphaId)), findsOneWidget);
      expect(find.byKey(_listItem(_betaId)), findsNothing);
    });

    testWidgets(
      'deleting a daily note calls memex rm with the daily note id and closes its tab',
      (tester) async {
        final db = _seededDb();
        final h = await _pump(tester, db);
        await _openNote(tester, _dailyId);
        await _chooseDelete(tester);
        expect(_inDialog(find.textContaining('2026-10-02')), findsOneWidget);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        final calls = h.cli.callsFor('rm');
        expect(calls, hasLength(1));
        expect(calls.single.args, [
          'rm',
          '--vault',
          h.vaultPath,
          '--note-id',
          _dailyId,
          '--expected-version',
          '4',
        ]);
        expect(db.getNote(_dailyId), isNull);
        expect(find.byKey(_tab(_dailyId)), findsNothing);
        expect(find.byKey(_listItem(_dailyId)), findsNothing);
      },
    );

    testWidgets('deleting a role-less note works the same way', (tester) async {
      final db = _seededDb();
      final h = await _pump(tester, db);
      expect(db.getNote(_betaId)!.role, isNull);
      await _openNote(tester, _betaId);
      await _chooseDelete(tester);

      await tester.tap(find.byKey(_confirm));
      await pumpFrames(tester);

      expect(h.cli.callsFor('rm'), hasLength(1));
      expect(find.byKey(_tab(_betaId)), findsNothing);
      expect(db.getNote(_betaId), isNull);
    });

    testWidgets(
      'with an unsaved edit the delete still uses the last saved version',
      (tester) async {
        final db = _seededDb();
        final h = await _pump(
          tester,
          db,
          // The debounced save never answers, so lastSavedVersion stays 7.
          configure: (cli) =>
              cli.on('update', (_) => Completer<MemexResult>().future),
        );
        await _openNote(tester, _alphaId);
        await tester.enterText(
          find.byKey(const Key('editor-title')),
          'Alpha note edited',
        );
        // The save debounce runs on the clock (D14).
        h.clock.advance(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));
        expect(h.cli.callsFor('update'), hasLength(1));

        await _chooseDelete(tester);
        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(h.cli.callsFor('rm').single.flag('expected-version'), '7');
        expect(h.cli.callsFor('rm').single.flag('note-id'), _alphaId);
        expect(find.byKey(_tab(_alphaId)), findsNothing);
      },
    );
  });

  group('failed delete (AC7)', () {
    testWidgets(
      'a version_conflict keeps the tab and the note and shows the CLI message inline',
      (tester) async {
        final db = _seededDb();
        final h = await _pump(
          tester,
          db,
          configure: (cli) => cli.on(
            'rm',
            (_) => FakeMemexCli.error(
              'version_conflict',
              'note changed since last read',
              {'current_version': 9},
            ),
          ),
        );
        await _openNote(tester, _alphaId);
        expect(find.byKey(_inlineError), findsNothing);
        final revisionBefore = h.read(vaultRevisionProvider);
        await _chooseDelete(tester);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(h.cli.callsFor('rm'), hasLength(1));
        expect(find.byKey(_dialog), findsNothing);
        expect(find.byKey(_tab(_alphaId)), findsOneWidget);
        expect(h.read(tabsProvider).tabs, [const NoteTab(_alphaId)]);
        expect(find.byKey(_listItem(_alphaId)), findsOneWidget);
        expect(db.getNote(_alphaId), isNotNull);
        expect(h.read(vaultRevisionProvider), revisionBefore);
        expect(find.byKey(_inlineError), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_inlineError),
            matching: find.textContaining('note changed since last read'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a not_found failure also keeps the tab and shows the CLI message inline',
      (tester) async {
        final db = _seededDb();
        final h = await _pump(
          tester,
          db,
          configure: (cli) => cli.on(
            'rm',
            (_) => FakeMemexCli.error('not_found', 'no such note on disk'),
          ),
        );
        await _openNote(tester, _betaId);
        await _chooseDelete(tester);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(find.byKey(_tab(_betaId)), findsOneWidget);
        expect(find.byKey(_listItem(_betaId)), findsOneWidget);
        expect(db.getNote(_betaId), isNotNull);
        expect(h.read(tabsProvider).tabs, [const NoteTab(_betaId)]);
        expect(
          find.descendant(
            of: find.byKey(_inlineError),
            matching: find.textContaining('no such note on disk'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a stale version from the fake CLI surfaces version_conflict end to end',
      (tester) async {
        // The row changed behind the editor: the fake rm compares the version
        // the app sent (7) against the stored one (8) and refuses.
        final db = _seededDb();
        final h = await _pump(tester, db);
        await _openNote(tester, _alphaId);
        db.db.execute('UPDATE notes SET version = 8 WHERE id = ?', [_alphaId]);
        await _chooseDelete(tester);

        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(h.cli.callsFor('rm').single.flag('expected-version'), '7');
        expect(db.getNote(_alphaId), isNotNull);
        expect(find.byKey(_tab(_alphaId)), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_inlineError),
            matching: find.textContaining('note changed since last read'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the inline error is dismissible', (tester) async {
      await _pump(
        tester,
        _seededDb(),
        configure: (cli) => cli.on(
          'rm',
          (_) => FakeMemexCli.error('version_conflict', 'stale note'),
        ),
      );
      await _openNote(tester, _alphaId);
      await _chooseDelete(tester);
      await tester.tap(find.byKey(_confirm));
      await pumpFrames(tester);
      expect(find.byKey(_inlineError), findsOneWidget);

      await tester.tap(find.byKey(_inlineErrorDismiss));
      await pumpFrames(tester);

      expect(find.byKey(_inlineError), findsNothing);
      expect(find.byKey(_tab(_alphaId)), findsOneWidget);
    });

    testWidgets(
      'retrying after a failure deletes the note and clears the error',
      (tester) async {
        final db = _seededDb();
        var fail = true;
        final h = await _pump(
          tester,
          db,
          configure: (cli) {
            cli.on('rm', (call) {
              if (fail) {
                return FakeMemexCli.error('version_conflict', 'stale note');
              }
              final id = call.flag('note-id');
              db.db.execute('DELETE FROM notes WHERE id = ?', [id]);
              return FakeMemexCli.ok(
                '{"vault_id":"01HV0000000000000000000000","note_id":"$id","deleted":true}',
              );
            });
          },
        );
        await _openNote(tester, _alphaId);
        await _chooseDelete(tester);
        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);
        expect(find.byKey(_inlineError), findsOneWidget);

        fail = false;
        await _chooseDelete(tester);
        await tester.tap(find.byKey(_confirm));
        await pumpFrames(tester);

        expect(h.cli.callsFor('rm'), hasLength(2));
        expect(find.byKey(_tab(_alphaId)), findsNothing);
        expect(find.byKey(_inlineError), findsNothing);
        expect(db.getNote(_alphaId), isNull);
      },
    );
  });
}
