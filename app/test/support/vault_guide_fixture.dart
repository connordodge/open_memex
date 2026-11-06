// WI #262 (F10): shared fixture for the Vault Guide UI tests. A Topics vault
// with a `role: guide` note, a FakeMemexCli that plays `memex guide get` and
// `memex guide restore` against the FakeVaultDb, and a launcher that serves
// recording domain doubles and a TabsRecorder.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../robots/topics_robot.dart';
import 'activity_seeds.dart';
import 'app_harness.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'feedback_seeds.dart';
import 'folder_cli_fakes.dart';
import 'recording_tabs.dart';
import 'today_cli_fakes.dart';
import 'topics_access_doubles.dart';
import 'topics_seed.dart';

/// The Vault Guide note's id in [guideDb].
const guideNoteId = 'guide-note-0001';

/// Its title and starting body and version.
const guideNoteTitle = 'Vault Guide';
const guideBody = 'current guide text';
const guideVersion = 3;

/// What revision `rev-1` held before the agent change `ac-1` overwrote it.
const guidePreviousBody = 'older guide text';

/// The Topics fixture plus the Vault Guide note (`role: guide`).
///
/// With [v6] false the vault is exactly at schema V5 (no guide tables).
FakeVaultDb guideDb({bool v6 = true}) {
  final db = v6 ? FakeVaultDb.v5() : FakeVaultDb.v5Only();
  db.seedTopicsFixture();
  db.seedNote(
    id: guideNoteId,
    title: guideNoteTitle,
    content: guideBody,
    role: 'guide',
    version: guideVersion,
    updatedAt: 1759500005000,
  );
  return db;
}

const _guideVault = '01HV0000000000000000000000';

/// `memex guide get|restore` against a [FakeVaultDb].
extension GuideCliFakes on FakeMemexCli {
  /// `guide get`: answers the guide note row. `guide restore`: replaces the
  /// guide's text with the revision's `previous_md`, bumps the version, keeps
  /// the replaced text as a new revision (as the server does) and answers
  /// `{vault_id, note_id, version}`.
  void onGuide(FakeVaultDb db) {
    on('guide get', (_) {
      final rows = db.db.select(
        "SELECT id, version, content_md FROM notes WHERE json_extract(frontmatter, '\$.role') = 'guide'",
      );
      final row = rows.first;
      return FakeMemexCli.ok(
        '${jsonEncode({'vault_id': _guideVault, 'note_id': row['id'], 'version': row['version'], 'content_md': row['content_md']})}\n',
      );
    });
    on('guide restore', (call) {
      final revisionId = call.flag('revision-id')!;
      final revs = db.db.select(
        'SELECT note_id, previous_md FROM vault_guide_revisions WHERE id = ?',
        [revisionId],
      );
      if (revs.isEmpty) {
        return FakeMemexCli.error('not_found', 'revision $revisionId');
      }
      final noteId = revs.first['note_id'] as String;
      final restored = revs.first['previous_md'] as String;
      final note = db.db.select(
        'SELECT version, content_md FROM notes WHERE id = ?',
        [noteId],
      ).first;
      final current = (note['version'] as num).toInt();
      db.db.execute(
        'UPDATE notes SET content_md = ?, version = ?, updated_at = ? '
        'WHERE id = ?',
        [restored, current + 1, 1759600000000, noteId],
      );
      db.db.execute(
        'INSERT INTO vault_guide_revisions (id, note_id, previous_md, '
        'previous_version, new_version, agent_change_id, created_at) '
        'VALUES (?, ?, ?, ?, ?, NULL, ?)',
        [
          'rev-kept-$current',
          noteId,
          note['content_md'],
          current,
          current + 1,
          1759600000000,
        ],
      );
      return FakeMemexCli.ok(
        '${jsonEncode({'vault_id': _guideVault, 'note_id': noteId, 'version': current + 1})}\n',
      );
    });
  }
}

/// Seeds the guide's Activity: `ac-1` (newest) has revision `rev-1`, `ac-2`
/// has none. A third revision `rev-orphan` has no agent change.
extension GuideActivitySeed on FakeVaultDb {
  void seedGuideActivity() {
    seedAgentChange(
      'ac-2',
      guideNoteId,
      day: '2026-10-01',
      createdAt: DateTime(2026, 10, 1, 9, 0).millisecondsSinceEpoch,
      bullets: ['Read the guide'],
    );
    seedAgentChange(
      'ac-1',
      guideNoteId,
      day: '2026-10-02',
      createdAt: DateTime(2026, 10, 2, 9, 0).millisecondsSinceEpoch,
      bullets: ['Rewrote the guide'],
    );
    seedGuideRevision(
      'rev-1',
      noteId: guideNoteId,
      previousMd: guidePreviousBody,
      previousVersion: 2,
      newVersion: guideVersion,
      agentChangeId: 'ac-1',
      createdAt: 2000,
    );
    seedGuideRevision(
      'rev-orphan',
      noteId: guideNoteId,
      previousMd: 'orphan text',
      agentChangeId: null,
      createdAt: 1500,
    );
  }
}

/// Everything a Vault Guide test needs after [launchGuideWorkspace].
class GuideEnv {
  GuideEnv(this.h, this.cli, this.db, this.doubles, this.tabs);

  final WorkspaceHarness h;
  final FakeMemexCli cli;
  final FakeVaultDb db;
  final AccessDoubles doubles;
  final TabsRecorder tabs;

  RecordingFeedbackAccess get feedback => doubles.feedbackAt(h.vaultPath);
  RecordingTopicsAccess get topics => doubles.topicsAt(h.vaultPath);
}

/// Pumps the workspace on [db] with the folder, update and guide servers
/// installed on a fresh CLI, recording doubles and a [TabsRecorder]; the
/// sidebar is in Topics mode. [memexConfigured] false leaves the app with no
/// CLI. [extraOverrides] go last.
Future<GuideEnv> launchGuideWorkspace(
  WidgetTester tester, {
  FakeVaultDb? db,
  AccessDoubles? doubles,
  bool memexConfigured = true,
  bool topicsMode = true,
  List<Override> extraOverrides = const [],
}) async {
  final database = db ?? guideDb();
  final cli = FakeMemexCli();
  FolderCliFake(database).install(cli);
  cli
    ..onUpdateWrites(database)
    ..onGuide(database);
  final access = doubles ?? AccessDoubles();
  final tabs = TabsRecorder();
  final h = await pumpWorkspace(
    tester,
    db: database,
    cli: cli,
    memexConfigured: memexConfigured,
    surfaceSize: const Size(1600, 1400),
    overrides: [access.override, tabs.override, ...extraOverrides],
  );
  if (topicsMode) {
    final robot = TopicsRobot(tester)..h = h;
    await robot.chooseTopics();
  }
  return GuideEnv(h, cli, database, access, tabs);
}

/// Opens the right panel's Activity tab.
Future<void> showActivityTab(WidgetTester tester, WorkspaceHarness h) async {
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state =
      RightPanelTab.activity;
  await pumpFrames(tester);
}
