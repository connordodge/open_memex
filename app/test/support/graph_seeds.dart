// WI #30 (A12): seed data for the Graph view tests. Raw inserts against the
// real V5 schema (FakeVaultDb); nothing here goes through production reads.
import 'fake_vault_db.dart';
import 'daily_seed.dart';

/// Link seeding (the `links` table exists from V1, so these work on V4 too).
extension GraphSeed on FakeVaultDb {
  /// One `links` row from [from] to [to] (null = a ghost link). Positions are
  /// assigned per source note so `UNIQUE (from_note_id, position)` holds.
  /// Returns the link id.
  String seedLink(
    String from,
    String? to, {
    String kind = 'references',
    String? label,
    String? id,
    String? linkText,
  }) {
    final position =
        (db.select('SELECT COUNT(*) AS n FROM links WHERE from_note_id = ?', [
                  from,
                ]).first['n']
                as num)
            .toInt();
    final linkId = id ?? 'link-$from-$position';
    db.execute(
      'INSERT INTO links (id, from_note_id, to_note_id, link_text, link_kind, '
      'label, position, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        linkId,
        from,
        to,
        linkText ?? (to ?? 'Nowhere'),
        kind,
        label,
        position,
        'inline_body',
      ],
    );
    return linkId;
  }
}

/// Ids of the shared Graph fixture ([seedGraphFixture]).
abstract final class G {
  // Daily notes.
  static const day0905 = 'day-0905';
  static const day0906 = 'day-0906';
  static const day0907 = 'day-0907';
  // Topic notes.
  static const alpha = 'topic-alpha';
  static const beta = 'topic-beta';
  static const gamma = 'topic-gamma';
  static const delta = 'topic-delta';
  static const epsilon = 'topic-epsilon';
  // Notes without a daily/topic role.
  static const loose = 'note-loose';
  static const badFrontmatter = 'note-bad-frontmatter';
  static const otherRole = 'note-other-role';
  // Smart Folders.
  static const projects = 'sf-projects'; // pinned, root
  static const research = 'sf-research'; // child of projects
  static const deep = 'sf-deep'; // child of research
  static const archive = 'sf-archive'; // root

  static const allNotes = <String>{
    day0905,
    day0906,
    day0907,
    alpha,
    beta,
    gamma,
    delta,
    epsilon,
    loose,
    badFrontmatter,
    otherRole,
  };
}

/// One edge as a comparable tuple.
typedef EdgeTuple = (String from, String to, String kind, String? label);

/// Every link in [seedGraphFixture] that has a target, as tuples.
const graphFixtureEdges = <EdgeTuple>{
  (G.alpha, G.beta, 'extends', 'builds on'),
  (G.beta, G.gamma, 'references', null),
  (G.gamma, G.delta, 'references', null),
  (G.epsilon, G.alpha, 'references', null),
  (G.epsilon, G.delta, 'contradicts', null),
  (G.alpha, G.day0905, 'from-day', null),
  (G.beta, G.day0905, 'from-day', null),
  (G.delta, G.day0906, 'from-day', null),
  (G.day0905, G.alpha, 'about', null),
  (G.day0905, G.gamma, 'about', null),
  (G.day0906, G.delta, 'about', null),
  (G.loose, G.day0905, 'references', null),
};

/// The shared Graph fixture.
///
/// Notes: daily 2026-09-05/06/07; topics Alpha, Beta, Gamma, Delta, Epsilon;
/// `Loose idea` (no role), `Bad frontmatter` (invalid JSON), `Other role`
/// (`role: journal`).
///
/// Smart Folders (pinned flag) and direct members (membership pinned flag):
/// - Projects (pinned): Alpha (pinned), Beta
///   - Research: Gamma
///     - Deep: Loose idea
/// - Archive: Delta, Beta (pinned)
///
/// Links: [graphFixtureEdges] plus a ghost link Alpha → `Nowhere`.
/// Footer chips: 2026-09-05 → Alpha, Gamma; 2026-09-06 → Delta.
void seedGraphFixture(FakeVaultDb db) {
  db.seedDailyNote('2026-09-05', id: G.day0905);
  db.seedDailyNote('2026-09-06', id: G.day0906);
  db.seedDailyNote('2026-09-07', id: G.day0907);
  db.seedTopicNote(G.alpha, 'Alpha');
  db.seedTopicNote(G.beta, 'Beta');
  db.seedTopicNote(G.gamma, 'Gamma');
  db.seedTopicNote(G.delta, 'Delta');
  db.seedTopicNote(G.epsilon, 'Epsilon');
  db.seedNote(id: G.loose, title: 'Loose idea');
  db.seedNote(
    id: G.badFrontmatter,
    title: 'Bad frontmatter',
    frontmatter: 'not json',
  );
  db.seedNote(id: G.otherRole, title: 'Other role', role: 'journal');

  db.seedSmartFolder(G.projects, 'Projects', pinned: true);
  db.seedSmartFolder(G.research, 'Research', parentId: G.projects);
  db.seedSmartFolder(G.deep, 'Deep', parentId: G.research);
  db.seedSmartFolder(G.archive, 'Archive');
  db.seedFolderMember(G.projects, G.alpha, pinned: true);
  db.seedFolderMember(G.projects, G.beta);
  db.seedFolderMember(G.research, G.gamma);
  db.seedFolderMember(G.deep, G.loose);
  db.seedFolderMember(G.archive, G.delta);
  db.seedFolderMember(G.archive, G.beta, pinned: true);

  for (final (from, to, kind, label) in graphFixtureEdges) {
    db.seedLink(from, to, kind: kind, label: label);
  }
  db.seedLink(G.alpha, null, linkText: 'Nowhere');

  db.seedFooterChip(G.day0905, G.alpha);
  db.seedFooterChip(G.day0905, G.gamma, origin: 'person');
  db.seedFooterChip(G.day0906, G.delta);
}

/// [count] topic notes `t00`…, titled `Topic 00`…, each linked to the next
/// in a ring plus a chord to the note five ahead. For the settle test.
void seedTopicRing(FakeVaultDb db, int count) {
  String id(int i) => 't${(i % count).toString().padLeft(2, '0')}';
  for (var i = 0; i < count; i++) {
    db.seedTopicNote(id(i), 'Topic ${i.toString().padLeft(2, '0')}');
  }
  for (var i = 0; i < count; i++) {
    db.seedLink(id(i), id(i + 1));
    if (i % 3 == 0) db.seedLink(id(i), id(i + 5), kind: 'extends');
  }
}
