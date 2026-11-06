// WI #259 (F7): seeds and wire samples for Feedback, tag Corrections and Vault
// Guide revisions. DB seeds are raw inserts against the real V6 schema
// fixture, so nothing here trusts production read code to build its input.
// The JSON samples are the Contract of #256 (`### Contract`).
import 'dart:convert';

import 'package:open_memex_app/src/db/feedback_reads.dart';

import 'fake_vault_db.dart';

/// Raw inserts into `feedback`, `tag_corrections` and
/// `vault_guide_revisions` (V6). Insert order is the rowid order, so tests
/// can seed out of display order on purpose. No foreign keys are enforced
/// on the in-memory handle.
extension FeedbackSeed on FakeVaultDb {
  /// One `feedback` row. [correction] is stored as `correction_json`;
  /// [correctionJson] stores raw text instead (a malformed value).
  void seedFeedback(
    String id, {
    String kind = 'comment',
    String source = 'person',
    String? noteId,
    String? day,
    String? agentChangeId,
    String? text,
    Map<String, Object?>? correction,
    String? correctionJson,
    String status = 'open',
    String? reply,
    int? tagCorrectionId,
    int createdAt = 1000,
    int? updatedAt,
    int? handledAt,
  }) {
    db.execute(
      'INSERT INTO feedback (id, kind, source, note_id, day, agent_change_id, '
      'text, correction_json, status, reply, tag_correction_id, created_at, '
      'updated_at, handled_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        kind,
        source,
        noteId,
        day,
        agentChangeId,
        text,
        correctionJson ?? (correction == null ? null : jsonEncode(correction)),
        status,
        reply,
        tagCorrectionId,
        createdAt,
        updatedAt ?? createdAt,
        handledAt,
      ],
    );
  }

  /// One `tag_corrections` row; returns its AUTOINCREMENT id (`tag-<id>`).
  int seedTagCorrection({
    String? noteId,
    String noteTitle = 'A note',
    String tag = 'gardening',
    int createdAt = 1000,
    int? clearedAt,
  }) {
    db.execute(
      'INSERT INTO tag_corrections (note_id, note_title, tag, kind, '
      'created_at, cleared_at) VALUES (?, ?, ?, ?, ?, ?)',
      [noteId, noteTitle, tag, 'removed', createdAt, clearedAt],
    );
    return db.lastInsertRowId;
  }

  /// One `vault_guide_revisions` row.
  void seedGuideRevision(
    String id, {
    String noteId = 'guide-note',
    String previousMd = 'old guide',
    int previousVersion = 1,
    int newVersion = 2,
    String? agentChangeId,
    int createdAt = 1000,
  }) {
    db.execute(
      'INSERT INTO vault_guide_revisions (id, note_id, previous_md, '
      'previous_version, new_version, agent_change_id, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        noteId,
        previousMd,
        previousVersion,
        newVersion,
        agentChangeId,
        createdAt,
      ],
    );
  }
}

/// A Contract `Feedback` object (#256) with [overrides] applied last; an
/// override of null keeps the key with a null value.
Map<String, Object?> feedbackJson({
  String id = '01J9FB000000000000000000A1',
  Map<String, Object?> overrides = const {},
}) => {
  'id': id,
  'kind': 'comment',
  'source': 'person',
  'note_id': '01J9NOTE00000000000000000A',
  'day': '2026-11-05',
  'agent_change_id': '01J9CHG000000000000000000A',
  'text': 'This bullet is wrong',
  'correction': null,
  'status': 'open',
  'reply': null,
  'created_at': 1762300000000,
  'updated_at': 1762300000500,
  'handled_at': null,
  ...overrides,
};

/// The eight Contract `correction` objects by kind (#256).
const correctionSamples = <String, Map<String, Object?>>{
  'excerpt_moved': {
    'kind': 'excerpt_moved',
    'date': '2026-11-05',
    'block_id': 'b7k2m9',
    'preview': 'Tune the loop',
    'from_topic_note_id': '01J9TOPICFROM0000000000001',
    'from_title': 'Player Loop',
    'to_topic_note_id': '01J9TOPICTO000000000000002',
    'to_title': 'Economy',
  },
  'excerpt_removed': {
    'kind': 'excerpt_removed',
    'date': '2026-11-05',
    'block_ids': ['b7k2m9', 'c3d4e5'],
    'preview': 'Two blocks about pacing',
    'topic_note_id': '01J9TOPICFROM0000000000001',
    'title': 'Player Loop',
  },
  'excerpt_added': {
    'kind': 'excerpt_added',
    'date': '2026-11-06',
    'block_id': 'd4e5f6',
    'preview': 'Add a gold sink',
    'topic_note_id': '01J9TOPICTO000000000000002',
    'title': 'Economy',
  },
  'membership_removed': {
    'kind': 'membership_removed',
    'note_id': '01J9NOTE00000000000000000A',
    'note_title': 'Pacing',
    'smart_folder_id': '01J9FOLDER00000000000000A1',
    'folder_name': 'Design',
  },
  'folder_renamed': {
    'kind': 'folder_renamed',
    'smart_folder_id': '01J9FOLDER00000000000000A1',
    'old_name': 'Design',
    'new_name': 'Game design',
  },
  'folder_moved': {
    'kind': 'folder_moved',
    'smart_folder_id': '01J9FOLDER00000000000000A1',
    'name': 'Design',
    'old_parent_id': null,
    'new_parent_id': '01J9FOLDER00000000000000B2',
  },
  'folder_deleted': {
    'kind': 'folder_deleted',
    'smart_folder_id': '01J9FOLDER00000000000000A1',
    'name': 'Design',
  },
  'tag_removed': {
    'kind': 'tag_removed',
    'tag': 'gardening',
    'note_id': '01J9NOTE00000000000000000A',
    'note_title': 'Pacing',
  },
};

/// The `vaultAccessShape` of each [correctionSamples] kind, decoded.
const correctionShapes = <String, Object?>{
  'excerpt_moved': {
    'ExcerptMovedCorrection': [
      '2026-11-05',
      'b7k2m9',
      'Tune the loop',
      '01J9TOPICFROM0000000000001',
      'Player Loop',
      '01J9TOPICTO000000000000002',
      'Economy',
    ],
  },
  'excerpt_removed': {
    'ExcerptRemovedCorrection': [
      '2026-11-05',
      ['b7k2m9', 'c3d4e5'],
      'Two blocks about pacing',
      '01J9TOPICFROM0000000000001',
      'Player Loop',
    ],
  },
  'excerpt_added': {
    'ExcerptAddedCorrection': [
      '2026-11-06',
      'd4e5f6',
      'Add a gold sink',
      '01J9TOPICTO000000000000002',
      'Economy',
    ],
  },
  'membership_removed': {
    'MembershipRemovedCorrection': [
      '01J9NOTE00000000000000000A',
      'Pacing',
      '01J9FOLDER00000000000000A1',
      'Design',
    ],
  },
  'folder_renamed': {
    'FolderRenamedCorrection': [
      '01J9FOLDER00000000000000A1',
      'Design',
      'Game design',
    ],
  },
  'folder_moved': {
    'FolderMovedCorrection': [
      '01J9FOLDER00000000000000A1',
      'Design',
      null,
      '01J9FOLDER00000000000000B2',
    ],
  },
  'folder_deleted': {
    'FolderDeletedCorrection': ['01J9FOLDER00000000000000A1', 'Design'],
  },
  'tag_removed': {
    'TagRemovedCorrection': [
      'gardening',
      '01J9NOTE00000000000000000A',
      'Pacing',
    ],
  },
};

/// Whether [c] is the subclass the Contract names for [kind].
bool correctionMatchesKind(String kind, FeedbackCorrection? c) =>
    switch (kind) {
      'excerpt_moved' => c is ExcerptMovedCorrection,
      'excerpt_removed' => c is ExcerptRemovedCorrection,
      'excerpt_added' => c is ExcerptAddedCorrection,
      'membership_removed' => c is MembershipRemovedCorrection,
      'folder_renamed' => c is FolderRenamedCorrection,
      'folder_moved' => c is FolderMovedCorrection,
      'folder_deleted' => c is FolderDeletedCorrection,
      'tag_removed' => c is TagRemovedCorrection,
      _ => false,
    };

/// A Contract `Filing` object (#256).
Map<String, Object?> filingJson() => {
  'vault_id': '01J9VAULT00000000000000000',
  'date': '2026-11-05',
  'note_id': '01J9DAILY0000000000000000A',
  'reviewed': true,
  'topics': [
    {
      'topic_note_id': '01J9TOPICFROM0000000000001',
      'title': 'Player Loop',
      'blocks': [
        {'id': 'b7k2m9', 'text': 'Tune the loop'},
        {'id': 'c3d4e5', 'text': 'Second block'},
      ],
    },
    {
      'topic_note_id': '01J9TOPICTO000000000000002',
      'title': 'Economy',
      'blocks': <Object?>[],
    },
  ],
  'not_filed': [
    {'id': 'e5f6a7', 'text': 'Unfiled thought'},
  ],
};

/// The `vaultAccessShape` of [filingJson] decoded.
const filingShape = {
  'Filing': [
    '01J9VAULT00000000000000000',
    '2026-11-05',
    '01J9DAILY0000000000000000A',
    true,
    [
      {
        'FilingTopic': [
          '01J9TOPICFROM0000000000001',
          'Player Loop',
          [
            {
              'FilingBlock': ['b7k2m9', 'Tune the loop'],
            },
            {
              'FilingBlock': ['c3d4e5', 'Second block'],
            },
          ],
        ],
      },
      {
        'FilingTopic': ['01J9TOPICTO000000000000002', 'Economy', <Object?>[]],
      },
    ],
    [
      {
        'FilingBlock': ['e5f6a7', 'Unfiled thought'],
      },
    ],
  ],
};
