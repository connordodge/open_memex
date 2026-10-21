// WI #87 (W3): the Topics pane renders the async Topics tree (D14a).
// On a local vault the first load shows today's tree or its empty state with
// no spinner and a reload keeps the previous tree; on a hosted vault the first
// load shows the A12 loading state; a vault switch never shows the previous
// vault's rows.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';
import '../support/topics_seed.dart';
import '../support/vault_scoped_reads.dart';

/// Completes every gate of `smartFolders` that is still open.
Future<void> _release(
  WidgetTester tester,
  RecordingTopicsAccess topics, {
  int? only,
}) async {
  final gates = topics.gates['smartFolders'] ?? const [];
  for (final (i, g) in gates.indexed) {
    if (only != null && i != only) continue;
    if (!g.isCompleted) g.complete();
  }
  await pumpFrames(tester);
}

/// The one vault's topics double; it exists once the app read the domain.
RecordingTopicsAccess _topicsOf(AccessDoubles doubles) {
  expect(
    doubles.topics,
    isNotEmpty,
    reason: 'the Topics pane reads through vaultAccessProvider',
  );
  return doubles.topics.values.single;
}

Finder get _loading => find.byKey(vaultAsyncLoadingKey);

void _expectNoSpinner() {
  expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
  expect(find.byIcon(LucideIcons.loader2), findsNothing);
}

void main() {
  group('first load', () {
    testWidgets(
      'on first load of a local vault the topics pane shows the empty state with no spinner until the read completes then today tree',
      (tester) async {
        final db = FakeVaultDb.v5()..seedTopicsFixture();
        final doubles = AccessDoubles(
          configureTopics: (_, t) => t.gate('smartFolders'),
        );
        final r = await launchTopics(tester, doubles, db: db);
        final topics = _topicsOf(doubles);
        expect(topics.gates['smartFolders'], isNotEmpty, reason: 'pending');

        expect(r.topics.pane, findsOneWidget);
        expect(r.topics.empty, findsOneWidget);
        expect(r.topics.folder(TP.games), findsNothing);
        _expectNoSpinner();

        await _release(tester, topics);

        expect(r.topics.empty, findsNothing);
        expect(r.topics.folder(TP.games), findsOneWidget);
        expect(r.topics.folder(TP.health), findsOneWidget);
        expect(r.topics.unsortedNote(TP.orphan), findsOneWidget);
        _expectNoSpinner();
      },
    );

    testWidgets(
      'on first load of a local vault with no topics the pane shows the topics-empty state and no spinner',
      (tester) async {
        final doubles = AccessDoubles();
        final r = await launchTopics(tester, doubles, db: FakeVaultDb.v5());

        expect(r.topics.empty, findsOneWidget);
        r.topics.expectEmptyCopy();
        expect(r.topics.copyButton, findsOneWidget);
        _expectNoSpinner();
        expect(
          _topicsOf(doubles).callsTo('smartFolders'),
          isNotEmpty,
          reason: 'the empty tree was read through the topics domain',
        );
      },
    );

    testWidgets(
      'on first load of a hosted vault the topics pane shows the loading state in place of the tree until the read completes',
      (tester) async {
        final db = FakeVaultDb.v5()..seedTopicsFixture();
        final doubles = AccessDoubles(
          configureTopics: (_, t) => t.gate('smartFolders'),
        );
        final r = await launchTopics(
          tester,
          doubles,
          db: db,
          overrides: [vaultIsHostedProvider.overrideWithValue(true)],
        );
        final topics = _topicsOf(doubles);

        expect(_loading, findsOneWidget);
        expect(r.topics.empty, findsNothing);
        expect(r.topics.folder(TP.games), findsNothing);

        await _release(tester, topics);

        expect(_loading, findsNothing);
        expect(r.topics.folder(TP.games), findsOneWidget);
        _expectNoSpinner();
      },
    );
  });

  group('reload', () {
    for (final (name, hosted) in [
      (
        'after a revision bump the topics pane keeps the previous tree on screen until the new read completes on a local vault',
        false,
      ),
      (
        'after a revision bump the topics pane keeps the previous tree on screen until the new read completes on a hosted vault',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final db = FakeVaultDb.v5()..seedTopicsFixture();
        final doubles = AccessDoubles();
        final r = await launchTopics(
          tester,
          doubles,
          db: db,
          overrides: [
            if (hosted) vaultIsHostedProvider.overrideWithValue(true),
          ],
        );
        final topics = _topicsOf(doubles);
        expect(r.topics.folder(TP.games), findsOneWidget);
        topics.gate('smartFolders');
        db.seedSmartFolder('f-new', 'Archive');

        await r.topics.bumpRevision();

        expect(topics.gates['smartFolders'], hasLength(1), reason: 'pending');
        expect(r.topics.folder(TP.games), findsOneWidget);
        expect(r.topics.folder(TP.health), findsOneWidget);
        expect(r.topics.folder('f-new'), findsNothing);
        expect(r.topics.empty, findsNothing);
        _expectNoSpinner();

        await _release(tester, topics);

        expect(r.topics.folder('f-new'), findsOneWidget);
        expect(r.topics.folder(TP.games), findsOneWidget);
      });
    }
  });

  group('vault switch', () {
    for (final (name, hosted) in [
      (
        'switching local vaults never shows the previous vault rows in the topics pane or the facade while the new read is pending',
        false,
      ),
      (
        'switching hosted vaults never shows the previous vault rows in the topics pane or the facade while the new read is pending',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final dbA = FakeVaultDb.v5()..seedTopicsFixture();
        final dbB = FakeVaultDb.v5()
          ..seedTopicNote('b-topic', 'Only in B')
          ..seedSmartFolder('f-b-only', 'Only in B folder')
          ..seedFolderMember('f-b-only', 'b-topic');
        addTearDown(dbB.close);
        final vaultB = Directory.systemTemp.createTempSync('om87_b');
        addTearDown(() {
          if (vaultB.existsSync()) vaultB.deleteSync(recursive: true);
        });
        final doubles = AccessDoubles(
          dbFor: (path, db) => path == vaultB.path ? dbB : db,
          configureTopics: (path, t) {
            if (path == vaultB.path) t.gate('smartFolders');
          },
        );
        final r = await launchTopics(
          tester,
          doubles,
          db: dbA,
          overrides: [
            if (hosted) vaultIsHostedProvider.overrideWithValue(true),
          ],
        );
        expect(r.topics.folder(TP.games), findsOneWidget);
        expect(r.topics.unsortedNote(TP.orphan), findsOneWidget);

        r.h.container.read(currentVaultProvider.notifier).state = LocalVaultRef(
          vaultB.path,
        );
        await pumpFrames(tester);
        // Switching vaults leaves the sidebar in Days mode.
        await r.topics.chooseTopics();

        final b = doubles.topicsAt(vaultB.path);
        expect(b.gates['smartFolders'], isNotEmpty, reason: 'B is loading');
        // Nothing of A's, in the pane or in the facade.
        expect(r.topics.folder(TP.games), findsNothing);
        expect(r.topics.folder(TP.health), findsNothing);
        expect(r.topics.unsortedNote(TP.orphan), findsNothing);
        expect(r.topics.unsortedNote(TP.looseNote), findsNothing);
        expect(
          readScoped(
            r.h.container,
            smartFolderTreeAsyncProvider,
            emptyTopicsTree(),
          ).isEmpty,
          isTrue,
        );
        expect(
          readScoped(
            r.h.container,
            smartFolderTreeAsyncProvider,
            emptyTopicsTree(),
          ).folders,
          isEmpty,
        );
        expect(
          readScoped(
            r.h.container,
            smartFolderTreeAsyncProvider,
            emptyTopicsTree(),
          ).unsorted.notes,
          isEmpty,
        );
        if (hosted) {
          expect(_loading, findsOneWidget);
        } else {
          expect(r.topics.empty, findsOneWidget);
          _expectNoSpinner();
        }

        await _release(tester, b);

        expect(r.topics.folder('f-b-only'), findsOneWidget);
        expect(r.topics.folder(TP.games), findsNothing);
        expect(_loading, findsNothing);
        expect(r.topics.empty, findsNothing);
      });
    }
  });
}
