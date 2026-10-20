// WI #24 (A7): smartFolderTreeProvider and the PromptCli wrapper (TD8, D18,
// D21; Req 52, 53).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/prompt_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/topics_tree.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/topics_seed.dart';

ProviderContainer _container({VaultDb? db}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => LocalVaultRef('/tmp/om-fake-vault'),
      ),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      clockProvider.overrideWithValue(FakeClock()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  return db;
}

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

List<String> _ids(List<FolderNode> nodes) => [for (final n in nodes) n.id];

void main() {
  group('smartFolderTreeProvider (AC1)', () {
    test('builds the tree from the Smart Folder reads', () {
      final db = _v5()..seedTopicsFixture();
      final c = _container(db: db);

      final tree = c.read(smartFolderTreeProvider);

      // Sorted case-insensitively: Games before health.
      expect(_ids(tree.folders), [TP.games, TP.health]);
      final games = tree.folders.first;
      expect(games.pinned, isTrue);
      expect(games.depth, 0);
      expect(_ids(games.children), [TP.design]);
      expect(games.children.single.depth, 1);
      expect(games.topics.map((t) => t.title), ['Economy', 'Player Loop']);
      expect(games.topics.map((t) => t.pinned), [false, true]);
      expect(games.children.single.topics.map((t) => t.title), [
        'Level Design',
        'Player Loop',
      ]);
      expect(tree.folders.last.topics.map((t) => t.noteId), [TP.sleep]);
      // Unsorted: role-less and topic notes in no folder, never the daily
      // note.
      expect(tree.unsorted.notes.map((n) => n.noteId), [
        TP.looseNote,
        TP.orphan,
      ]);
      expect(tree.isEmpty, isFalse);
    });

    test(
      'rebuilds after a vault revision bump so a seeded new folder appears',
      () {
        final db = _v5()..seedTopicsFixture();
        final c = _container(db: db);
        final seen = <List<String>>[];
        c.listen<TopicsTree>(
          smartFolderTreeProvider,
          (_, next) => seen.add(_ids(next.folders)),
          fireImmediately: true,
        );
        expect(seen.last, [TP.games, TP.health]);

        db.seedSmartFolder('f-new', 'Archive');
        // Nothing changes until the revision moves.
        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          TP.games,
          TP.health,
        ]);

        _bump(c);

        expect(_ids(c.read(smartFolderTreeProvider).folders), [
          'f-new',
          TP.games,
          TP.health,
        ]);
        expect(seen.last, ['f-new', TP.games, TP.health]);
      },
    );

    test('a membership added after the first read shows after a bump', () {
      final db = _v5()..seedTopicsFixture();
      final c = _container(db: db);
      expect(
        c.read(smartFolderTreeProvider).unsorted.notes.map((n) => n.noteId),
        contains(TP.looseNote),
      );

      db.seedFolderMember(TP.health, TP.looseNote);
      _bump(c);

      final tree = c.read(smartFolderTreeProvider);
      expect(tree.unsorted.notes.map((n) => n.noteId), [TP.orphan]);
      final health = tree.folders.firstWhere((f) => f.id == TP.health);
      expect(health.topics.map((t) => t.noteId), contains(TP.looseNote));
    });

    test('an empty V5 vault gives an empty tree', () {
      final c = _container(db: _v5());

      final tree = c.read(smartFolderTreeProvider);

      expect(tree.isEmpty, isTrue);
      expect(tree.folders, isEmpty);
      expect(tree.unsorted.notes, isEmpty);
    });

    test('a vault below V5 gives an empty tree and does not throw', () {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      db.seedNote(id: 'n1', title: 'Old note');
      final c = _container(db: db);

      final tree = c.read(smartFolderTreeProvider);

      expect(tree.isEmpty, isTrue);
      expect(tree.folders, isEmpty);
      expect(tree.unsorted.notes, isEmpty);
    });

    test('a vault migrated to V5 fills the tree after a bump', () {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      db.seedNote(id: 'n1', title: 'Old note');
      final c = _container(db: db);
      expect(c.read(smartFolderTreeProvider).unsorted.notes, isEmpty);

      db.migrateToV5();
      _bump(c);

      expect(
        c.read(smartFolderTreeProvider).unsorted.notes.map((n) => n.noteId),
        ['n1'],
      );
    });

    test('no open database gives an empty tree', () {
      final c = _container(db: null);

      final tree = c.read(smartFolderTreeProvider);

      expect(tree.isEmpty, isTrue);
      expect(tree.unsorted.notes, isEmpty);
    });
  });

  group('PromptCli (D18, C2.13, D21)', () {
    test(
      'reviewPrompt runs memex prompt review and returns stdout byte for byte',
      () async {
        const text =
            'Review the days.\n\n  - keep indent\n- unicode: “quoted” — done\n';
        final cli = FakeMemexCli()
          ..on('prompt review', (_) => FakeMemexCli.ok(text));

        final out = await cli.reviewPrompt();

        expect(out, text);
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.subcommand, 'prompt review');
        expect(cli.calls.single.args, ['prompt', 'review']);
      },
    );

    test(
      'reviewPrompt throws a MemexException carrying the C1 code and message on failure',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'prompt review',
            (_) => FakeMemexCli.error('internal', 'prompt store unreadable'),
          );

        await expectLater(
          cli.reviewPrompt(),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'internal')
                .having(
                  (e) => e.message,
                  'message',
                  contains('prompt store unreadable'),
                ),
          ),
        );
      },
    );

    test(
      'reviewPrompt throws a MemexException for a non-JSON failure',
      () async {
        final cli = FakeMemexCli()
          ..on('prompt review', (_) => FakeMemexCli.failure('boom'));

        await expectLater(
          cli.reviewPrompt(),
          throwsA(
            isA<MemexException>().having(
              (e) => e.message,
              'message',
              contains('boom'),
            ),
          ),
        );
      },
    );
  });
}
