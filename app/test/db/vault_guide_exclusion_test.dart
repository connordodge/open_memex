// WI #262 (F10) AC5: the Vault Guide (`role: guide`) is absent from the app's
// direct Unsorted and Graph reads. Everything else those reads returned
// before (role-less notes, notes with broken frontmatter, other roles) stays.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';

FakeVaultDb _db() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  return db;
}

/// A vault with a guide next to every kind of note the reads must keep.
FakeVaultDb _vaultWithGuide() {
  final db = _db();
  db.seedNote(id: 'guide', title: 'Vault Guide', role: 'guide');
  db.seedTopicNote('topic-free', 'Free topic');
  db.seedNote(id: 'plain', title: 'Plain note');
  db.seedDailyNote('2026-10-02', id: 'day');
  return db;
}

void main() {
  group('unsortedNotes leaves the guide out (AC5)', () {
    test('the guide note is not an Unsorted row', () {
      final db = _vaultWithGuide();

      final ids = db.unsortedNotes().map((r) => r.noteId).toSet();

      expect(ids, isNot(contains('guide')));
    });

    test('topic and role-less notes still are Unsorted rows', () {
      final db = _vaultWithGuide();

      final ids = db.unsortedNotes().map((r) => r.noteId).toSet();

      expect(ids, {'topic-free', 'plain'});
      final roles = {for (final r in db.unsortedNotes()) r.noteId: r.role};
      expect(roles, {'topic-free': 'topic', 'plain': null});
    });

    test('a note whose role only starts with guide is still listed', () {
      final db = _vaultWithGuide();
      db.seedNote(id: 'guided', title: 'Guided tour', role: 'guided');
      db.seedNote(id: 'upper', title: 'Upper', role: 'Guide');

      final ids = db.unsortedNotes().map((r) => r.noteId).toSet();

      expect(ids, containsAll(['guided', 'upper']));
      expect(ids, isNot(contains('guide')));
    });

    test('a vault with only the guide has an empty Unsorted list', () {
      final db = _db();
      db.seedNote(id: 'guide', title: 'Vault Guide', role: 'guide');

      expect(db.unsortedNotes(), isEmpty);
    });
  });

  group('graph reads leave the guide out (AC5)', () {
    test('graphNotes does not list the guide note', () {
      final db = _vaultWithGuide();

      final ids = db.graphNotes().map((n) => n.id).toList();

      expect(ids, isNot(contains('guide')));
    });

    test('graphNotes keeps every other note, in id order', () {
      final db = _vaultWithGuide();
      db.seedNote(id: 'odd', title: 'Odd role', role: 'guided');

      final ids = db.graphNotes().map((n) => n.id).toList();

      expect(ids, ['day', 'odd', 'plain', 'topic-free']);
    });

    test('graphNotes keeps the role of the notes it lists', () {
      final db = _vaultWithGuide();

      final roles = {for (final n in db.graphNotes()) n.id: n.role};

      expect(roles, {'day': 'daily', 'plain': null, 'topic-free': 'topic'});
    });

    test('graphLinks drops a link from the guide to a note', () {
      final db = _vaultWithGuide();
      db.seedLink('guide', 'topic-free');

      expect(db.graphLinks(), isEmpty);
    });

    test('graphLinks drops a link from a note to the guide', () {
      final db = _vaultWithGuide();
      db.seedLink('topic-free', 'guide');

      expect(db.graphLinks(), isEmpty);
    });

    test('graphLinks keeps links between the other notes', () {
      final db = _vaultWithGuide();
      db.seedLink('topic-free', 'plain', id: 'keep');
      db.seedLink('guide', 'plain', id: 'gone-1');
      db.seedLink('plain', 'guide', id: 'gone-2');

      final links = db.graphLinks();

      expect(links.map((l) => '${l.from}>${l.to}'), ['topic-free>plain']);
    });
  });
}
