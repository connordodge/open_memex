// WI #87 (W3): every Topics write goes through VaultAccess (D13, D14a, D16).
// Recording doubles that extend the local domain classes (D21) sit behind
// vaultAccessProvider and forward to the FakeMemexCli / FolderCliFake server,
// so each test sees both what the app asked the domain for and what the
// screen shows. Writes that are not saves run through guardVaultWrite (L17)
// and keep their revision bump; a Smart Folder, settings or topic write that
// throws VaultUnreachableException shows the snackbar and changes nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/smart_folder_actions.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/topics_tree.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';

import '../robots/smart_folder_robot.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/today_cli_fakes.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';
import '../support/topics_seed.dart';
import '../support/vault_scoped_reads.dart';

const _noCli = 'The memex CLI is not available.';
const _depthKey = 'smart_folder_max_depth';
const _today = '2026-10-03';
const _todayId = 'daily-2026-10-03';

const _unreachable = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: false,
);
const _unreachableText = "couldn't reach nas. try again.";

/// The domain double of the one open vault.
RecordingTopicsAccess _topics(AccessDoubles d, SmartFolderRobot r) {
  expect(
    d.topics,
    isNotEmpty,
    reason: 'the app reads and writes through vaultAccessProvider',
  );
  return d.topicsAt(r.h.vaultPath);
}

/// The ids of the folders the tree facade holds (depth-first).
List<String> _treeIds(SmartFolderRobot r) {
  final out = <String>[];
  void walk(List<FolderNode> nodes) {
    for (final n in nodes) {
      out.add(n.id);
      walk(n.children);
    }
  }

  walk(
    readScoped(
      r.h.container,
      smartFolderTreeAsyncProvider,
      emptyTopicsTree(),
    ).folders,
  );
  return out;
}

/// The write calls (not the reads) the double recorded, in order.
List<RecordedCall> _writeCalls(RecordingTopicsAccess t) => [
  for (final c in t.calls)
    if (c.method != 'smartFolders' && c.method != 'unsortedNotes') c,
];

List<String> _writes(RecordingTopicsAccess t) => [
  for (final c in _writeCalls(t)) c.method,
];

/// One Smart Folder write the person can make from the Topics pane, with the
/// three test names it gets (each one string literal for the AC map).
class _Write {
  const _Write({
    required this.successName,
    required this.failName,
    required this.unreachableName,
    required this.method,
    required this.args,
    required this.run,
  });

  final String successName;
  final String failName;
  final String unreachableName;

  /// The `TopicsAccess` method it must reach.
  final String method;

  /// The arguments it must carry.
  final Map<String, Object?> args;

  final Future<void> Function(SmartFolderRobot r) run;
}

final _smartFolderWrites = <_Write>[
  _Write(
    successName:
        'the new Smart Folder at root write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed new Smart Folder at root write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the new Smart Folder at root write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'createFolder',
    args: {'name': 'Reading', 'parentId': null},
    run: (r) => r.createFolder('Reading'),
  ),
  _Write(
    successName:
        'the new Smart Folder inside a selected folder write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed new Smart Folder inside a selected folder write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the new Smart Folder inside a selected folder write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'createFolder',
    args: {'name': 'Combat', 'parentId': TP.games},
    run: (r) async {
      await r.selectFolder(TP.games);
      await r.createFolder('Combat');
    },
  ),
  _Write(
    successName:
        'the rename write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed rename write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the rename write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'updateFolder',
    args: {
      'id': TP.health,
      'name': 'Wellbeing',
      'parentId': null,
      'toRoot': false,
      'pinned': null,
    },
    run: (r) => r.renameFolder(TP.health, 'Wellbeing'),
  ),
  _Write(
    successName:
        'the move under another folder write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed move under another folder write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the move under another folder write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'updateFolder',
    args: {
      'id': TP.health,
      'name': null,
      'parentId': TP.games,
      'toRoot': false,
      'pinned': null,
    },
    run: (r) => r.moveFolder(TP.health, TP.games),
  ),
  _Write(
    successName:
        'the move to root write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed move to root write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the move to root write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'updateFolder',
    args: {
      'id': TP.design,
      'name': null,
      'parentId': null,
      'toRoot': true,
      'pinned': null,
    },
    run: (r) async {
      await r.ensureExpanded(TP.games);
      await r.moveFolder(TP.design, null);
    },
  ),
  _Write(
    successName:
        'the folder pinned toggle write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed folder pinned toggle write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the folder pinned toggle write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'updateFolder',
    args: {
      'id': TP.games,
      'name': null,
      'parentId': null,
      'toRoot': false,
      'pinned': false,
    },
    run: (r) => r.toggleFolderPinned(TP.games),
  ),
  _Write(
    successName:
        'the delete write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed delete write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the delete write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'deleteFolder',
    args: {'id': TP.health},
    run: (r) => r.deleteFolder(TP.health, confirm: true),
  ),
  _Write(
    successName:
        'the membership pinned toggle write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed membership pinned toggle write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the membership pinned toggle write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'addToFolder',
    args: {'folderId': TP.games, 'noteId': TP.economy, 'pinned': true},
    run: (r) async {
      await r.ensureExpanded(TP.games);
      await r.toggleMembershipPinned(TP.games, TP.economy);
    },
  ),
  _Write(
    successName:
        'the drop of an Unsorted note onto a folder write goes through the topics domain and success bumps the revision once',
    failName:
        'a failed drop of an Unsorted note onto a folder write leaves the tree as is and shows the CLI message inline',
    unreachableName:
        'the drop of an Unsorted note onto a folder write whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
    method: 'addToFolder',
    args: {'folderId': TP.health, 'noteId': TP.orphan, 'pinned': null},
    run: (r) => r.dragOntoFolder(r.unsortedNote(TP.orphan), TP.health),
  ),
];

/// Max depth 2 holds Games > Design; a folder under Design is too deep.
Future<void> _createUnderDesign(SmartFolderRobot r, String name) async {
  await r.selectFolder(TP.games);
  await r.selectFolder(TP.design);
  await r.createFolder(name);
}

void _expectSnackbar(String text) =>
    expect(find.text(text), findsOneWidget, reason: 'the guard snackbar');

Finder _in(Finder dialog, String key) =>
    find.descendant(of: dialog, matching: find.byKey(Key(key)));

void main() {
  group('Smart Folder writes', () {
    for (final w in _smartFolderWrites) {
      testWidgets(w.successName, (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);

        await w.run(r);

        final t = _topics(doubles, r);
        final writes = _writeCalls(t);
        expect(writes, hasLength(1), reason: '${t.calls}');
        expect(writes.single.method, w.method);
        expect(writes.single.args, equals(w.args));
        expect(bumps.bumps, 1, reason: 'one revision bump per write');
        expect(r.h.read(smartFolderErrorProvider), isNull);
        expect(r.anyError, findsNothing);
        expect(
          t.callsTo('smartFolders').length,
          greaterThan(1),
          reason: 'the bump re-read the tree through the domain',
        );
      });

      testWidgets(w.failName, (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        final before = _treeIds(r);
        _topics(doubles, r).failNext(w.method, MemexException('boom 87'));

        await w.run(r);

        expect(_writes(_topics(doubles, r)), [w.method]);
        expect(r.h.read(smartFolderErrorProvider), 'boom 87');
        r.expectPaneError('boom 87');
        expect(bumps.bumps, 0);
        expect(_treeIds(r), before);
      });

      testWidgets(w.unreachableName, (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        final before = _treeIds(r);
        _topics(doubles, r).failNext(w.method, _unreachable);

        await w.run(r);

        expect(_writes(_topics(doubles, r)), [w.method]);
        _expectSnackbar(_unreachableText);
        expect(r.anyError, findsNothing);
        expect(r.h.read(smartFolderErrorProvider), isNull);
        expect(bumps.bumps, 0);
        expect(_treeIds(r), before);
      });
    }

    testWidgets(
      'a Smart Folder write that may have committed shows the confirm snackbar naming the server',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        _topics(doubles, r).failNext(
          'deleteFolder',
          const VaultUnreachableException(
            serverName: 'nas',
            mayHaveCommitted: true,
          ),
        );

        await r.deleteFolder(TP.health, confirm: true);

        _expectSnackbar(
          "couldn't confirm with nas — check before trying again",
        );
        expect(r.anyError, findsNothing);
        expect(bumps.bumps, 0);
      },
    );

    testWidgets(
      'a Smart Folder write that fails with a plain exception shows its text inline and changes nothing',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        _topics(doubles, r).failNext('createFolder', Exception('disk gone'));

        await r.createFolder('Reading');

        expect(r.h.read(smartFolderErrorProvider), 'Exception: disk gone');
        r.expectPaneError('Exception: disk gone');
        expect(bumps.bumps, 0);
      },
    );

    testWidgets(
      'a successful Smart Folder write clears the error an earlier failure left',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        _topics(doubles, r).failNext('createFolder', MemexException('first'));
        await r.createFolder('Reading');
        r.expectPaneError('first');
        expect(bumps.bumps, 0);

        await r.createFolder('Reading');

        expect(r.h.read(smartFolderErrorProvider), isNull);
        expect(r.anyError, findsNothing);
        expect(bumps.bumps, 1);
        r.topics.expectShows(r.folder('f-new-1'), 'Reading');
      },
    );

    testWidgets(
      'with no memex binary configured a Smart Folder write shows The memex CLI is not available and changes nothing',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, memexConfigured: false);
        final bumps = RevisionCounter(r.h);
        final before = _treeIds(r);

        await r.createFolder('Reading');
        expect(r.h.read(smartFolderErrorProvider), _noCli);
        r.expectPaneError(_noCli);
        await r.dismissError();

        await r.deleteFolder(TP.health, confirm: true);
        expect(r.h.read(smartFolderErrorProvider), _noCli);
        r.expectPaneError(_noCli);
        await r.dismissError();

        await r.renameFolder(TP.health, 'Wellbeing');
        expect(r.h.read(smartFolderErrorProvider), _noCli);
        r.expectPaneError(_noCli);

        expect(bumps.bumps, 0);
        expect(_treeIds(r), before);
      },
    );
  });

  group('the depth dialog retry', () {
    testWidgets(
      'confirming the depth dialog raises smart_folder_max_depth through the topics domain and retries the write once',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);

        await _createUnderDesign(r, 'Bosses');
        expect(r.depthDialog, findsOneWidget);
        expect(bumps.bumps, 0);
        await r.tap(r.depthConfirm);

        final t = _topics(doubles, r);
        expect(_writes(t), ['createFolder', 'setSetting', 'createFolder']);
        const create = {'name': 'Bosses', 'parentId': TP.design};
        expect(t.callsTo('createFolder').first.args, create);
        expect(t.callsTo('createFolder').last.args, create);
        expect(t.callsTo('setSetting').single.args, {
          'key': _depthKey,
          'value': 3,
        });
        expect(bumps.bumps, 1, reason: 'one bump for the whole sequence');
        expect(r.h.read(smartFolderErrorProvider), isNull);
        expect(r.depthDialog, findsNothing);
        await r.ensureExpanded(TP.design);
        r.topics.expectShows(r.folder('f-new-1'), 'Bosses');
        expect(r.server.maxDepth, 3);
      },
    );

    testWidgets(
      'confirming the depth dialog for a move retries the same update once',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        await r.ensureExpanded(TP.games);

        await r.moveFolder(TP.health, TP.design);
        expect(r.depthDialog, findsOneWidget);
        await r.tap(r.depthConfirm);

        final t = _topics(doubles, r);
        expect(_writes(t), ['updateFolder', 'setSetting', 'updateFolder']);
        final moves = t.callsTo('updateFolder');
        expect(moves.first.args, {
          'id': TP.health,
          'name': null,
          'parentId': TP.design,
          'toRoot': false,
          'pinned': null,
        });
        expect(moves.last.args, moves.first.args);
        expect(t.callsTo('setSetting').single.args, {
          'key': _depthKey,
          'value': 3,
        });
        expect(bumps.bumps, 1);
        expect(r.h.read(smartFolderErrorProvider), isNull);
      },
    );

    testWidgets(
      'cancelling the depth dialog changes nothing and makes no second write',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        final before = _treeIds(r);

        await _createUnderDesign(r, 'Bosses');
        await r.tap(r.depthCancel);

        final t = _topics(doubles, r);
        expect(_writes(t), ['createFolder']);
        expect(t.callsTo('setSetting'), isEmpty);
        expect(bumps.bumps, 0);
        expect(r.h.read(smartFolderErrorProvider), isNull);
        expect(r.anyError, findsNothing);
        expect(_treeIds(r), before);
        expect(r.server.maxDepth, 2);
      },
    );

    testWidgets(
      'a failed settings raise after the depth dialog is shown inline and the write is not retried',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        await _createUnderDesign(r, 'Bosses');
        _topics(doubles, r).failNext('setSetting', MemexException('locked 87'));

        await r.tap(r.depthConfirm);

        expect(_writes(_topics(doubles, r)), ['createFolder', 'setSetting']);
        r.expectPaneError('locked 87');
        expect(bumps.bumps, 0);
      },
    );

    testWidgets(
      'a failed retry after the depth raise is shown inline and does not bump the revision',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        final bumps = RevisionCounter(r.h);
        await _createUnderDesign(r, 'Bosses');
        _topics(
          doubles,
          r,
        ).failNth('createFolder', 2, MemexException('still too deep'));

        await r.tap(r.depthConfirm);

        expect(_writes(_topics(doubles, r)), [
          'createFolder',
          'setSetting',
          'createFolder',
        ]);
        r.expectPaneError('still too deep');
        expect(bumps.bumps, 0);
      },
    );
  });

  group('the vault settings dialog', () {
    testWidgets(
      'the vault settings dialog reads smart_folder_max_depth through the topics domain each time it opens',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);

        await r.openVaultSettings();

        final t = _topics(doubles, r);
        expect(t.callsTo('getSetting').single.args, {'key': _depthKey});
        expect(r.fieldText(r.depthField), '2');

        await r.tap(find.text('Cancel'));
        expect(r.settingsDialog, findsNothing);
        await r.openVaultSettings();
        expect(t.callsTo('getSetting'), hasLength(2));
        expect(t.callsTo('setSetting'), isEmpty);
      },
    );

    testWidgets(
      'saving the vault settings depth sets smart_folder_max_depth through the topics domain and bumps the revision once',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        await r.openVaultSettings();
        final bumps = RevisionCounter(r.h);

        await r.saveDepth('4');

        final t = _topics(doubles, r);
        expect(t.callsTo('setSetting').single.args, {
          'key': _depthKey,
          'value': 4,
        });
        expect(bumps.bumps, 1);
        expect(r.settingsDialog, findsNothing);
        expect(r.server.maxDepth, 4);
      },
    );

    for (final (name, bad) in [
      (
        'the vault settings dialog does not send the invalid depth 0 and keeps its validation message',
        '0',
      ),
      (
        'the vault settings dialog does not send the invalid depth 6 and keeps its validation message',
        '6',
      ),
      (
        'the vault settings dialog does not send the invalid depth minus 1 and keeps its validation message',
        '-1',
      ),
      (
        'the vault settings dialog does not send the invalid depth 2.5 and keeps its validation message',
        '2.5',
      ),
      (
        'the vault settings dialog does not send a non numeric depth and keeps its validation message',
        'abc',
      ),
      (
        'the vault settings dialog does not send an empty depth and keeps its validation message',
        '',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        await r.openVaultSettings();
        final bumps = RevisionCounter(r.h);

        await r.saveDepth(bad);

        expect(_topics(doubles, r).callsTo('setSetting'), isEmpty);
        expect(bumps.bumps, 0);
        expect(r.settingsDialog, findsOneWidget);
        expect(find.text('Enter a whole number from 1 to 5.'), findsOneWidget);
      });
    }

    for (final (name, ok) in [
      (
        'the vault settings dialog sends the lowest depth 1 through the topics domain',
        1,
      ),
      (
        'the vault settings dialog sends the highest depth 5 through the topics domain',
        5,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        await r.openVaultSettings();

        await r.saveDepth('$ok');

        expect(_topics(doubles, r).callsTo('setSetting').single.args, {
          'key': _depthKey,
          'value': ok,
        });
      });
    }

    testWidgets(
      'a failed settings read shows the message inline in the vault settings dialog',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        _topics(
          doubles,
          r,
        ).failNext('getSetting', MemexException('unreadable 87'));

        await r.openVaultSettings();

        expect(_in(r.settingsDialog, 'inline-error'), findsOneWidget);
        expect(
          find.descendant(
            of: r.settingsDialog,
            matching: find.textContaining('unreadable 87'),
          ),
          findsOneWidget,
        );
        expect(r.fieldText(r.depthField), isEmpty);
      },
    );

    testWidgets(
      'a failed settings save keeps the vault settings dialog open with the message inline and does not bump',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        await r.openVaultSettings();
        final bumps = RevisionCounter(r.h);
        _topics(doubles, r).failNext('setSetting', MemexException('locked 87'));

        await r.saveDepth('3');

        expect(r.settingsDialog, findsOneWidget);
        expect(
          find.descendant(
            of: r.settingsDialog,
            matching: find.textContaining('locked 87'),
          ),
          findsOneWidget,
        );
        expect(bumps.bumps, 0);
        expect(r.server.maxDepth, 2);
      },
    );

    testWidgets(
      'a settings save whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles);
        await r.openVaultSettings();
        final bumps = RevisionCounter(r.h);
        _topics(doubles, r).failNext('setSetting', _unreachable);

        await r.saveDepth('3');

        _expectSnackbar(_unreachableText);
        expect(r.anyError, findsNothing);
        expect(bumps.bumps, 0);
        expect(r.server.maxDepth, 2);
      },
    );

    testWidgets(
      'with no memex binary configured the vault settings dialog shows The memex CLI is not available on open and on save',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, memexConfigured: false);

        await r.openVaultSettings();
        expect(
          find.descendant(of: r.settingsDialog, matching: find.text(_noCli)),
          findsOneWidget,
        );
        final bumps = RevisionCounter(r.h);

        await r.saveDepth('3');

        expect(r.settingsDialog, findsOneWidget);
        expect(
          find.descendant(of: r.settingsDialog, matching: find.text(_noCli)),
          findsOneWidget,
        );
        expect(bumps.bumps, 0);
      },
    );
  });

  group('+ New topic', () {
    FakeVaultDb dbWithToday() =>
        FakeVaultDb.v5()..seedDailyNote(_today, id: _todayId);

    FakeMemexCli cliFor(FakeVaultDb db) => FakeMemexCli()
      ..onAddCreates(db)
      ..onFooterAdd(db);

    Future<void> newTopic(SmartFolderRobot r, String title) async {
      await r.tap(r.byKey('topics-new-topic'));
      final field = r.byKey('new-topic-title-field');
      expect(field, findsOneWidget);
      await r.tester.enterText(field, title);
      await r.tester.pump();
      await r.tap(r.byKey('new-topic-confirm'));
    }

    testWidgets(
      '+ New topic creates the topic note and its footer chip on the daily note of today through the vault access and opens the topic tab',
      (tester) async {
        final db = dbWithToday();
        final cli = cliFor(db);
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, db: db, cli: cli);
        final bumps = RevisionCounter(r.h);

        await newTopic(r, 'Player Loop');

        final path = r.h.vaultPath;
        expect(doubles.notesAt(path).callsTo('addNote').single.args, {
          'title': 'Player Loop',
          'tags': <String>[],
          'contentMd': '# Player Loop\n\n',
          'role': 'topic',
        });
        expect(doubles.dailyAt(path).callsTo('addFooterChip').single.args, {
          'dailyNoteId': _todayId,
          'topicNoteId': createdTopicId,
        });
        expect(
          [
            for (final c in cli.calls)
              if (c.subcommand == 'add' || c.subcommand == 'footer add')
                c.subcommand,
          ],
          ['add', 'footer add'],
        );
        expect(bumps.bumps, 1);
        expect(r.topics.activeTab, const NoteTab(createdTopicId));
        expect(r.anyError, findsNothing);
        expect(r.unsortedNote(createdTopicId), findsOneWidget);
      },
    );

    testWidgets(
      '+ New topic when today has no daily note links the topic note to the daily note it created first',
      (tester) async {
        final db = FakeVaultDb.v5();
        final cli = cliFor(db);
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, db: db, cli: cli);
        final bumps = RevisionCounter(r.h);

        await newTopic(r, 'Player Loop');

        final path = r.h.vaultPath;
        expect(
          doubles
              .notesAt(path)
              .callsTo('addNote')
              .where((c) => c.args['role'] == 'topic'),
          hasLength(1),
        );
        expect(doubles.dailyAt(path).callsTo('addFooterChip').single.args, {
          'dailyNoteId': createdDailyId,
          'topicNoteId': createdTopicId,
        });
        expect(bumps.bumps, 1);
        expect(r.topics.activeTab, const NoteTab(createdTopicId));
      },
    );

    testWidgets(
      'when only the footer call fails + New topic shows Topic created but it could not be linked to today with the cause and the note appears under Unsorted',
      (tester) async {
        final db = dbWithToday();
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, db: db, cli: cliFor(db));
        final bumps = RevisionCounter(r.h);
        doubles
            .dailyAt(r.h.vaultPath)
            .failNext('addFooterChip', MemexException('footer exploded'));

        await newTopic(r, 'Player Loop');

        final error = r.byKey('inline-error');
        expect(error, findsOneWidget);
        expect(
          find.descendant(
            of: error,
            matching: find.textContaining(
              "Topic created, but it couldn't be linked to today: "
              'footer exploded',
            ),
          ),
          findsOneWidget,
        );
        expect(r.unsortedNote(createdTopicId), findsOneWidget);
        expect(bumps.bumps, 1);
        expect(r.topics.activeTab, isNot(const NoteTab(createdTopicId)));
      },
    );

    testWidgets(
      'when the topic note cannot be created + New topic shows the message inline makes no footer call and changes nothing',
      (tester) async {
        final db = dbWithToday();
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, db: db, cli: cliFor(db));
        final bumps = RevisionCounter(r.h);
        final tabBefore = r.topics.activeTab;
        doubles
            .notesAt(r.h.vaultPath)
            .failNext('addNote', MemexException('title taken 87'));

        await newTopic(r, 'Player Loop');

        expect(
          find.descendant(
            of: r.byKey('inline-error'),
            matching: find.textContaining('title taken 87'),
          ),
          findsOneWidget,
        );
        expect(
          doubles.dailyAt(r.h.vaultPath).callsTo('addFooterChip'),
          isEmpty,
        );
        expect(bumps.bumps, 0);
        expect(r.topics.activeTab, tabBefore);
        expect(r.unsortedNote(createdTopicId), findsNothing);
      },
    );

    testWidgets(
      'a + New topic whose call throws VaultUnreachableException shows the guard snackbar instead of the inline error and changes nothing',
      (tester) async {
        final db = dbWithToday();
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, db: db, cli: cliFor(db));
        final bumps = RevisionCounter(r.h);
        final tabBefore = r.topics.activeTab;
        doubles.notesAt(r.h.vaultPath).failNext('addNote', _unreachable);

        await newTopic(r, 'Player Loop');

        _expectSnackbar(_unreachableText);
        expect(r.anyError, findsNothing);
        expect(
          doubles.dailyAt(r.h.vaultPath).callsTo('addFooterChip'),
          isEmpty,
        );
        expect(bumps.bumps, 0);
        expect(r.topics.activeTab, tabBefore);
        expect(r.unsortedNote(createdTopicId), findsNothing);
      },
    );

    testWidgets(
      'with no memex binary configured + New topic shows The memex CLI is not available inline and creates nothing',
      (tester) async {
        final db = dbWithToday();
        final doubles = AccessDoubles();
        final r = await launchTopics(
          tester,
          doubles,
          db: db,
          cli: cliFor(db),
          memexConfigured: false,
        );
        final bumps = RevisionCounter(r.h);
        final tabBefore = r.topics.activeTab;

        await newTopic(r, 'Player Loop');

        expect(
          find.descendant(
            of: r.byKey('inline-error'),
            matching: find.text(_noCli),
          ),
          findsOneWidget,
        );
        expect(bumps.bumps, 0);
        expect(r.topics.activeTab, tabBefore);
      },
    );
  });

  group('the review prompt copy', () {
    testWidgets(
      'the Topics empty state copy-review-prompt copies the text from topics reviewPrompt',
      (tester) async {
        const text = 'Review the days.\n\n  - keep indent\n- unicode: done\n';
        final doubles = AccessDoubles(
          configureTopics: (_, t) => t.promptText = text,
        );
        final r = SmartFolderRobot(tester);
        r.topics.mockClipboard();
        await launchTopics(tester, doubles, db: FakeVaultDb.v5(), robot: r);
        expect(r.topics.empty, findsOneWidget);

        await r.topics.copyReviewPrompt();

        expect(_topics(doubles, r).callsTo('reviewPrompt'), hasLength(1));
        expect(r.topics.clipboardWrites, [text]);
        expect(find.textContaining('not available'), findsNothing);
      },
    );

    testWidgets(
      'a failed review prompt copy shows the message below the button and copies nothing',
      (tester) async {
        final doubles = AccessDoubles();
        final r = SmartFolderRobot(tester);
        r.topics.mockClipboard();
        await launchTopics(tester, doubles, db: FakeVaultDb.v5(), robot: r);
        _topics(
          doubles,
          r,
        ).failNext('reviewPrompt', MemexException('prompt store unreadable'));

        await r.topics.copyReviewPrompt();

        expect(find.text('prompt store unreadable'), findsOneWidget);
        expect(r.topics.clipboardWrites, isEmpty);
      },
    );

    testWidgets(
      'a review prompt copy that fails with a plain exception shows its text',
      (tester) async {
        final doubles = AccessDoubles();
        final r = SmartFolderRobot(tester);
        r.topics.mockClipboard();
        await launchTopics(tester, doubles, db: FakeVaultDb.v5(), robot: r);
        _topics(
          doubles,
          r,
        ).failNext('reviewPrompt', Exception('plain failure'));

        await r.topics.copyReviewPrompt();

        expect(find.text('Exception: plain failure'), findsOneWidget);
        expect(r.topics.clipboardWrites, isEmpty);
      },
    );

    testWidgets(
      'with no memex binary configured the review prompt copy shows The memex CLI is not available',
      (tester) async {
        final doubles = AccessDoubles();
        final r = SmartFolderRobot(tester);
        r.topics.mockClipboard();
        await launchTopics(
          tester,
          doubles,
          db: FakeVaultDb.v5(),
          memexConfigured: false,
          robot: r,
        );

        await r.topics.copyReviewPrompt();

        expect(find.text(_noCli), findsOneWidget);
        expect(r.topics.clipboardWrites, isEmpty);
      },
    );
  });
}
