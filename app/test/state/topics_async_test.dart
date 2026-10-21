// WI #87 (W3): the Topics tree reads through VaultAccess.topics (D13, D14a).
// smartFolderTreeAsyncProvider returns a VaultScoped<TopicsTree> stamped with
// the vault it loaded for; smartFolderTreeProvider stays as the synchronous
// facade and never shows another vault's rows; selectedFolderInTreeProvider
// is derived from the tree.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/smart_folder_actions.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/topics_tree.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_seed.dart';

const _pathA = '/tmp/om-87-vault-a';
const _pathB = '/tmp/om-87-vault-b';
const _vaultA = LocalVaultRef(_pathA);
const _vaultB = LocalVaultRef(_pathB);

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  return db;
}

ProviderContainer _container({
  required VaultDb? db,
  required AccessDoubles doubles,
  VaultRef? vault = _vaultA,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
      doubles.override,
    ],
  );
  addTearDown(c.dispose);
  // A mounted pane keeps the tree provider alive, so a bump or a vault switch
  // re-reads it without anyone reading it again.
  final keepAlive = c.listen(smartFolderTreeProvider, (_, _) {});
  addTearDown(keepAlive.close);
  return c;
}

List<String> _ids(List<FolderNode> nodes) => [for (final n in nodes) n.id];

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

/// Lets started reads reach their gates.
Future<void> _settle() => pumpEventQueue();

void main() {
  group('the async Topics tree', () {
    test(
      'the topics tree is built from the topics domain smart folders and unsorted notes stamped with the vault',
      () async {
        final db = _v5()..seedTopicsFixture();
        final doubles = AccessDoubles();
        final c = _container(db: db, doubles: doubles);

        final scoped = await c.read(smartFolderTreeAsyncProvider.future);

        expect(scoped.vault, _vaultA);
        final tree = scoped.value;
        expect(_ids(tree.folders), [TP.games, TP.health]);
        expect(_ids(tree.folders.first.children), [TP.design]);
        expect(tree.unsorted.notes.map((n) => n.noteId), [
          TP.looseNote,
          TP.orphan,
        ]);
        final topics = doubles.topicsAt(_pathA);
        expect(topics.callsTo('smartFolders'), hasLength(1));
        expect(topics.callsTo('unsortedNotes'), hasLength(1));
        // The facade serves the same tree.
        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          TP.games,
          TP.health,
        ]);
      },
    );

    test(
      'the tree facade is empty before the first load completes and shows the tree once it has',
      () async {
        final db = _v5()..seedTopicsFixture();
        final doubles = AccessDoubles(
          configureTopics: (_, t) => t.gate('smartFolders'),
        );
        final c = _container(db: db, doubles: doubles);

        expect(c.read(smartFolderTreeProvider).isEmpty, isTrue);
        expect(c.read(smartFolderTreeProvider).folders, isEmpty);
        expect(c.read(smartFolderTreeProvider).unsorted.notes, isEmpty);
        await _settle();
        final topics = doubles.topicsAt(_pathA);
        expect(topics.gates['smartFolders'], hasLength(1));
        expect(c.read(smartFolderTreeAsyncProvider).isLoading, isTrue);
        expect(c.read(smartFolderTreeProvider).folders, isEmpty);

        topics.gates['smartFolders']!.single.complete();
        await c.read(smartFolderTreeAsyncProvider.future);

        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          TP.games,
          TP.health,
        ]);
      },
    );

    test('the tree facade is empty with no open vault', () async {
      final doubles = AccessDoubles();
      final c = _container(db: null, doubles: doubles, vault: null);

      expect(c.read(smartFolderTreeProvider).isEmpty, isTrue);
      await _settle();
      expect(c.read(smartFolderTreeProvider).isEmpty, isTrue);
      expect(c.read(smartFolderTreeProvider).folders, isEmpty);
      expect(doubles.topics, isEmpty, reason: 'no vault, no domain reads');
    });

    test(
      'a vault below V5 gives the empty tree from the async provider',
      () async {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        db.seedNote(id: 'n1', title: 'Old note');
        final c = _container(db: db, doubles: AccessDoubles());

        final scoped = await c.read(smartFolderTreeAsyncProvider.future);

        expect(scoped.vault, _vaultA);
        expect(scoped.value.isEmpty, isTrue);
        expect(scoped.value.unsorted.notes, isEmpty);
      },
    );

    test(
      'a revision bump re-reads the topics domain and the facade keeps the previous tree until the new read completes',
      () async {
        final db = _v5()..seedTopicsFixture();
        final doubles = AccessDoubles();
        final c = _container(db: db, doubles: doubles);
        await c.read(smartFolderTreeAsyncProvider.future);
        final topics = doubles.topicsAt(_pathA);
        topics.gate('smartFolders');
        db.seedSmartFolder('f-new', 'Archive');

        _bump(c);
        await _settle();

        expect(topics.gates['smartFolders'], hasLength(1));
        expect(c.read(smartFolderTreeAsyncProvider).isLoading, isTrue);
        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          TP.games,
          TP.health,
        ], reason: 'the previous tree stays while the reload is pending');

        topics.gates['smartFolders']!.single.complete();
        await c.read(smartFolderTreeAsyncProvider.future);

        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          'f-new',
          TP.games,
          TP.health,
        ]);
      },
    );

    test(
      'switching vaults never shows the previous vault rows while the new read is pending',
      () async {
        final dbA = _v5()..seedTopicsFixture();
        final dbB = _v5()..seedSmartFolder('f-b-only', 'Only in B');
        final doubles = AccessDoubles(
          dbFor: (path, db) => path == _pathB ? dbB : db,
          configureTopics: (path, t) {
            if (path == _pathB) t.gate('smartFolders');
          },
        );
        final c = _container(db: dbA, doubles: doubles);
        await c.read(smartFolderTreeAsyncProvider.future);
        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          TP.games,
          TP.health,
        ]);

        c.read(currentVaultProvider.notifier).state = _vaultB;
        await _settle();

        final b = doubles.topicsAt(_pathB);
        expect(b.gates['smartFolders'], hasLength(1), reason: 'B is loading');
        expect(c.read(smartFolderTreeProvider).folders, isEmpty);
        expect(c.read(smartFolderTreeProvider).unsorted.notes, isEmpty);
        expect(c.read(smartFolderTreeProvider).isEmpty, isTrue);

        b.gates['smartFolders']!.single.complete();
        final scoped = await c.read(smartFolderTreeAsyncProvider.future);

        expect(scoped.vault, _vaultB);
        expect(_ids(c.read(smartFolderTreeProvider).folders), ['f-b-only']);
      },
    );

    test(
      'a failed first read of the new vault gives the empty tree and never the previous vault rows',
      () async {
        final dbA = _v5()..seedTopicsFixture();
        final doubles = AccessDoubles(
          configureTopics: (path, t) {
            if (path == _pathB) t.gate('smartFolders');
          },
        );
        final c = _container(db: dbA, doubles: doubles);
        await c.read(smartFolderTreeAsyncProvider.future);

        c.read(currentVaultProvider.notifier).state = _vaultB;
        await _settle();
        final b = doubles.topicsAt(_pathB);
        b.failAlways('smartFolders', StateError('read of B failed'));
        b.gates['smartFolders']!.single.complete();
        await _settle();

        expect(c.read(smartFolderTreeAsyncProvider).hasError, isTrue);
        expect(c.read(smartFolderTreeProvider).folders, isEmpty);
        expect(c.read(smartFolderTreeProvider).isEmpty, isTrue);
      },
    );
  });

  group('selectedFolderInTreeProvider', () {
    Future<ProviderContainer> loaded(FakeVaultDb db) async {
      final c = _container(db: db, doubles: AccessDoubles());
      await c.read(smartFolderTreeAsyncProvider.future);
      return c;
    }

    void select(ProviderContainer c, String? id) =>
        c.read(selectedTopicFolderProvider.notifier).state = id;

    test(
      'selectedFolderInTreeProvider yields the selected folder while it is in the tree at any depth',
      () async {
        final db = _v5()..seedTopicsFixture();
        db.seedSmartFolder('f-deep', 'Deep', parentId: TP.design);
        final c = await loaded(db);

        select(c, TP.games);
        expect(c.read(selectedFolderInTreeProvider), TP.games);
        select(c, TP.design);
        expect(c.read(selectedFolderInTreeProvider), TP.design);
        select(c, 'f-deep');
        expect(c.read(selectedFolderInTreeProvider), 'f-deep');
        select(c, TP.health);
        expect(c.read(selectedFolderInTreeProvider), TP.health);
      },
    );

    test(
      'selectedFolderInTreeProvider is null for no selection and for a folder not in the tree',
      () async {
        final db = _v5()..seedTopicsFixture();
        final c = await loaded(db);

        expect(c.read(selectedFolderInTreeProvider), isNull);
        select(c, 'f-missing');
        expect(c.read(selectedFolderInTreeProvider), isNull);
        // A note id is not a folder either.
        select(c, TP.loop);
        expect(c.read(selectedFolderInTreeProvider), isNull);
      },
    );

    test(
      'selectedFolderInTreeProvider drops a selected folder once a reload no longer holds it',
      () async {
        final db = _v5()..seedTopicsFixture();
        final c = await loaded(db);
        select(c, TP.design);
        expect(c.read(selectedFolderInTreeProvider), TP.design);

        db.db.execute('DELETE FROM smart_folders WHERE id = ?', [TP.design]);
        _bump(c);
        await c.read(smartFolderTreeAsyncProvider.future);

        expect(c.read(selectedTopicFolderProvider), TP.design);
        expect(c.read(selectedFolderInTreeProvider), isNull);
      },
    );

    test(
      'selectedFolderInTreeProvider is null before the first load completes',
      () async {
        final db = _v5()..seedTopicsFixture();
        final c = _container(
          db: db,
          doubles: AccessDoubles(
            configureTopics: (_, t) => t.gate('smartFolders'),
          ),
        );
        select(c, TP.games);

        expect(c.read(selectedFolderInTreeProvider), isNull);
        await _settle();
        expect(c.read(selectedFolderInTreeProvider), isNull);
      },
    );

    test(
      'selectedFolderInTreeProvider is null for a folder of the previous vault after a switch',
      () async {
        final dbA = _v5()..seedTopicsFixture();
        final doubles = AccessDoubles(
          configureTopics: (path, t) {
            if (path == _pathB) t.gate('smartFolders');
          },
        );
        final c = _container(db: dbA, doubles: doubles);
        await c.read(smartFolderTreeAsyncProvider.future);
        select(c, TP.games);
        expect(c.read(selectedFolderInTreeProvider), TP.games);

        c.read(currentVaultProvider.notifier).state = _vaultB;
        await _settle();

        expect(c.read(selectedFolderInTreeProvider), isNull);
      },
    );
  });
}
