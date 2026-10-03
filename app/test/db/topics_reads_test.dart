import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  return db;
}

FakeVaultDb _v4() {
  final db = FakeVaultDb.v4();
  addTearDown(db.close);
  return db;
}

void main() {
  group('smartFolders (AC12)', () {
    test('reads folders with id, name, parent id and pinned', () {
      final db = _v5();
      db.seedSmartFolder('f-root', 'Projects', pinned: true);
      db.seedSmartFolder('f-child', 'Active', parentId: 'f-root');

      final data = db.smartFolders();
      final byId = {for (final f in data.folders) f.id: f};

      expect(byId.keys.toSet(), {'f-root', 'f-child'});
      expect(byId['f-root']!.name, 'Projects');
      expect(byId['f-root']!.parentId, isNull);
      expect(byId['f-root']!.pinned, isTrue);
      expect(byId['f-child']!.name, 'Active');
      expect(byId['f-child']!.parentId, 'f-root');
      expect(byId['f-child']!.pinned, isFalse);
    });

    test(
      'reads memberships with folder id, note id, note title and pinned',
      () {
        final db = _v5();
        db.seedSmartFolder('f1', 'Projects');
        db.seedSmartFolder('f2', 'Reading');
        db.seedTopicNote('t1', 'Roadmap');
        db.seedTopicNote('t2', 'Books');
        db.seedFolderMember('f1', 't1', pinned: true);
        db.seedFolderMember('f1', 't2');
        db.seedFolderMember('f2', 't2', pinned: true);

        final members = {
          for (final m in db.smartFolders().members)
            '${m.folderId}/${m.noteId}': m,
        };

        expect(members.keys.toSet(), {'f1/t1', 'f1/t2', 'f2/t2'});
        expect(members['f1/t1']!.title, 'Roadmap');
        expect(members['f1/t1']!.pinned, isTrue);
        expect(members['f1/t2']!.title, 'Books');
        expect(members['f1/t2']!.pinned, isFalse);
        expect(members['f2/t2']!.title, 'Books');
        expect(members['f2/t2']!.pinned, isTrue);
      },
    );

    test('a role-less note placed in a folder keeps its membership row', () {
      final db = _v5();
      db.seedSmartFolder('f1', 'Projects');
      db.seedNote(id: 'n1', title: 'Loose note');
      db.seedFolderMember('f1', 'n1');

      final members = db.smartFolders().members;

      expect(members.map((m) => m.noteId), ['n1']);
      expect(members.single.title, 'Loose note');
    });

    test(
      'returns empty folders and members for a vault with no Smart Folders',
      () {
        final db = _v5();
        db.seedTopicNote('t1', 'Roadmap');

        final data = db.smartFolders();

        expect(data.folders, isEmpty);
        expect(data.members, isEmpty);
      },
    );

    test(
      'returns empty folders and members on a V4 vault without throwing',
      () {
        final db = _v4();
        db.seedTopicNote('t1', 'Roadmap');

        final data = db.smartFolders();

        expect(data.folders, isEmpty);
        expect(data.members, isEmpty);
      },
    );
  });

  group('unsortedNotes (AC12)', () {
    test('returns topic and role-less notes with no membership', () {
      final db = _v5();
      db.seedTopicNote('t-free', 'Free topic');
      db.seedNote(id: 'n-free', title: 'Free plain note');
      db.seedTopicNote('t-placed', 'Placed topic');
      db.seedNote(id: 'n-placed', title: 'Placed plain note');
      db.seedSmartFolder('f1', 'Projects');
      db.seedFolderMember('f1', 't-placed');
      db.seedFolderMember('f1', 'n-placed');

      final rows = db.unsortedNotes();
      final byId = {for (final r in rows) r.noteId: r};

      expect(byId.keys.toSet(), {'t-free', 'n-free'});
      expect(byId['t-free']!.title, 'Free topic');
      expect(byId['t-free']!.role, 'topic');
      expect(byId['n-free']!.title, 'Free plain note');
      expect(byId['n-free']!.role, isNull);
    });

    test('excludes daily notes even when they have no membership', () {
      final db = _v5();
      db.seedDailyNote('2026-10-03');
      db.seedTopicNote('t1', 'Topic');
      // A role-less note titled like a date is not a daily note.
      db.seedNote(id: 'n-iso', title: '2026-10-02');

      expect(db.unsortedNotes().map((r) => r.noteId).toSet(), {'t1', 'n-iso'});
    });

    test(
      'a note in any one folder is not unsorted even if it is in several',
      () {
        final db = _v5();
        db.seedTopicNote('t1', 'Shared topic');
        db.seedSmartFolder('f1', 'One');
        db.seedSmartFolder('f2', 'Two');
        db.seedFolderMember('f2', 't1');

        expect(db.unsortedNotes(), isEmpty);
      },
    );

    test(
      'treats a note with invalid frontmatter as role-less and unsorted',
      () {
        final db = _v5();
        db.seedNote(
          id: 'bad',
          title: 'Broken frontmatter',
          frontmatter: 'not json{',
        );

        final rows = db.unsortedNotes();

        expect(rows.map((r) => r.noteId), ['bad']);
        expect(rows.single.role, isNull);
      },
    );

    test('returns an empty list when every note is sorted or daily', () {
      final db = _v5();
      db.seedDailyNote('2026-10-03');

      expect(db.unsortedNotes(), isEmpty);
    });

    test('returns an empty list on a V4 vault without throwing', () {
      final db = _v4();
      db.seedTopicNote('t1', 'Roadmap');
      db.seedNote(id: 'n1', title: 'Plain');

      expect(db.unsortedNotes(), isEmpty);
    });

    test(
      'sees Smart Folder tables after the vault is migrated on the same handle',
      () {
        final db = _v4();
        db.seedTopicNote('t1', 'Roadmap');
        expect(db.unsortedNotes(), isEmpty);

        db.migrateToV5();

        expect(db.unsortedNotes().map((r) => r.noteId), ['t1']);
      },
    );
  });
}
