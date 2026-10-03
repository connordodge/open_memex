// WI #24 (A7): seed data for the Topics tree tests. Raw inserts against the
// real V5 schema (FakeVaultDb); nothing here goes through production reads.
import 'daily_seed.dart';
import 'fake_vault_db.dart';

/// Ids of the shared Topics fixture ([seedTopicsFixture]).
abstract final class TP {
  // Smart Folders.
  static const games = 'f-games'; // root, pinned
  static const design = 'f-design'; // child of games
  static const health = 'f-health'; // root, unpinned
  // Topic notes in folders.
  static const loop = 'topic-loop';
  static const economy = 'topic-economy';
  static const level = 'topic-level';
  static const sleep = 'topic-sleep';
  // Notes in no folder.
  static const looseNote = 'note-loose'; // role-less
  static const orphan = 'topic-orphan'; // role: topic
  static const daily = 'daily-2026-10-02'; // role: daily
}

extension TopicsSeed on FakeVaultDb {
  /// Two root folders and a subfolder, topic notes in several of them, and
  /// notes in no folder:
  ///
  /// - `Games` (pinned, root): members `Player Loop` (pinned) and `Economy`;
  ///   subfolder `Design`.
  /// - `Design` (under Games): members `Level Design` and `Player Loop`
  ///   (both unpinned).
  /// - `health` (unpinned, root, lower-case name): member `Sleep`.
  /// - Unsorted: the role-less `Loose thought` and the topic `Orphan topic`;
  ///   the daily note 2026-10-02 is in no folder and must never be listed.
  void seedTopicsFixture() {
    seedTopicNote(TP.loop, 'Player Loop');
    seedTopicNote(TP.economy, 'Economy');
    seedTopicNote(TP.level, 'Level Design');
    seedTopicNote(TP.sleep, 'Sleep');
    seedNote(id: TP.looseNote, title: 'Loose thought', content: 'x');
    seedTopicNote(TP.orphan, 'Orphan topic');
    seedDailyNote('2026-10-02');

    seedSmartFolder(TP.games, 'Games', pinned: true);
    seedSmartFolder(TP.design, 'Design', parentId: TP.games);
    seedSmartFolder(TP.health, 'health');

    seedFolderMember(TP.games, TP.loop, pinned: true);
    seedFolderMember(TP.games, TP.economy);
    seedFolderMember(TP.design, TP.level);
    seedFolderMember(TP.design, TP.loop);
    seedFolderMember(TP.health, TP.sleep);
  }
}
