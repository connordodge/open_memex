// WI #261 (F9): the harness behind the Comment and Feedback tests of the
// Activity tab. The workspace runs on a real V6 `FakeVaultDb` (reads) and a
// stateful `FakeMemexCli` that plays the vault server for `feedback add`,
// `feedback edit` and `feedback rm` by writing the database, so what a test
// sees on screen is what a real write would leave behind. A recording
// `RecordingFeedbackAccess` sits behind `vaultAccessProvider` (D21) so a test
// can count the calls the app made.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import 'activity_seeds.dart';
import 'app_harness.dart';
import 'daily_seed.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'feedback_seeds.dart';
import 'review_fakes.dart';
import 'topics_access_doubles.dart';

/// The daily note every harness vault holds, with the two entries of
/// [seedCommentVault].
const commentNoteId = 'daily-2026-09-05';

/// The older entry (reviewed day 2026-09-02) and the newer one (2026-09-04).
const olderEntryId = 'ac-1';
const olderEntryDay = '2026-09-02';
const newerEntryId = 'ac-2';
const newerEntryDay = '2026-09-04';

int _ms(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch;

/// A V6 vault with the daily note [commentNoteId] and two agent entries,
/// seeded newest-last on purpose (the tab sorts them newest first).
FakeVaultDb seedCommentVault([FakeVaultDb? into]) {
  final db = into ?? FakeVaultDb.v6();
  db.seedDailyNote('2026-09-05', id: commentNoteId);
  db.seedAgentChange(
    olderEntryId,
    commentNoteId,
    day: olderEntryDay,
    createdAt: _ms(2026, 9, 3, 8, 5),
    bullets: ['Filed 2 blocks into Player Loop'],
  );
  db.seedAgentChange(
    newerEntryId,
    commentNoteId,
    day: newerEntryDay,
    createdAt: _ms(2026, 9, 6, 7, 40),
    bullets: ['Filed 1 block into Player Feel'],
  );
  return db;
}

/// A `memex` fake that serves `feedback add|edit|rm` from [db]: an add
/// inserts an open person comment (id `fb-new-<n>`), an edit rewrites the text
/// of an Open row (a Handled row answers `feedback_handled`, a missing one
/// `not_found`), a remove deletes the row. Also answers `settings get`.
FakeMemexCli commentCli(FakeVaultDb db) {
  var made = 0;
  String out(Object? json) => '${jsonEncode(json)}\n';
  return FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..on('feedback add', (call) {
      final id = 'fb-new-${++made}';
      db.seedFeedback(
        id,
        noteId: call.flag('note-id'),
        day: call.flag('date'),
        agentChangeId: call.flag('change-id'),
        text: call.flag('text'),
        createdAt: 50000 + made,
      );
      return FakeMemexCli.ok(
        out(
          feedbackJson(
            id: id,
            overrides: {
              'note_id': call.flag('note-id'),
              'day': call.flag('date'),
              'agent_change_id': call.flag('change-id'),
              'text': call.flag('text'),
            },
          ),
        ),
      );
    })
    ..on('feedback edit', (call) {
      final id = call.flag('id')!;
      final rows = db.db.select('SELECT status FROM feedback WHERE id = ?', [
        id,
      ]);
      if (rows.isEmpty) {
        return FakeMemexCli.error('not_found', 'no such feedback');
      }
      if (rows.first['status'] == 'handled') {
        return FakeMemexCli.error('feedback_handled', 'already handled');
      }
      db.db.execute(
        'UPDATE feedback SET text = ?, updated_at = updated_at + 1 '
        'WHERE id = ?',
        [call.flag('text'), id],
      );
      return FakeMemexCli.ok(
        out(feedbackJson(id: id, overrides: {'text': call.flag('text')})),
      );
    })
    ..on('feedback rm', (call) {
      final id = call.flag('id')!;
      db.db.execute('DELETE FROM feedback WHERE id = ?', [id]);
      return FakeMemexCli.ok(out({'vault_id': 'V', 'id': id}));
    });
}

/// What a test drives: the pumped workspace on the Activity tab of one note.
class ActivityRig {
  ActivityRig(this.tester, this.h, this.doubles, this.cli);

  final WidgetTester tester;
  final WorkspaceHarness h;
  final AccessDoubles doubles;
  final FakeMemexCli cli;

  FakeVaultDb get db => h.db;

  /// The recording feedback double of the open vault.
  RecordingFeedbackAccess get feedback => doubles.feedbackAt(h.vaultPath);

  /// The calls of [method] the app made on the feedback double.
  List<RecordedCall> calls(String method) => feedback.callsTo(method);

  Finder key(String k) => find.byKey(Key(k));

  Finder get field => key('comment-field');

  Future<void> settle() => pumpFrames(tester);

  /// Taps the element under [k]; fails by assertion when it is missing.
  Future<void> tap(String k) async {
    expect(key(k), findsOneWidget, reason: 'no widget with Key $k');
    await tester.ensureVisible(key(k));
    await tester.tap(key(k));
    await settle();
  }

  /// Opens the Comment input of entry [entryId].
  Future<void> openComment(String entryId) async {
    await tap('activity-comment-$entryId');
    expect(field, findsOneWidget, reason: 'Comment did not open the input');
  }

  Future<void> type(String text) async {
    expect(field, findsOneWidget, reason: 'the comment input is not open');
    await tester.enterText(field, text);
    await tester.pump();
  }

  Future<void> save() => tap('comment-save');

  Future<void> cancel() => tap('comment-cancel');

  /// The text in the comment input.
  String fieldText() {
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
      matchRoot: true,
    );
    return tester.widget<EditableText>(editable).controller.text;
  }

  /// Every Text under [k] (including [k] itself), top to bottom, joined with
  /// newlines.
  String textUnder(String k) {
    final texts = find.descendant(
      of: key(k),
      matching: find.byType(Text),
      matchRoot: true,
    );
    expect(texts, findsWidgets, reason: 'no text under Key $k');
    return [
      for (final w in tester.widgetList<Text>(texts))
        w.data ?? w.textSpan?.toPlainText() ?? '',
    ].join('\n');
  }

  /// The text of a Feedback row.
  String rowText(String id) => textUnder('feedback-$id');

  /// The status line of a Feedback row: `Open` or `Handled: <reply>`.
  String status(String id) => textUnder('feedback-status-$id').trim();

  double top(String k) {
    expect(key(k), findsOneWidget, reason: 'no widget with Key $k');
    return tester.getTopLeft(key(k)).dy;
  }

  double bottom(String k) {
    expect(key(k), findsOneWidget, reason: 'no widget with Key $k');
    return tester.getBottomLeft(key(k)).dy;
  }

  /// The agent handles Feedback [id] behind the app's back (a database
  /// write, no revision bump).
  void agentHandles(String id, String reply) {
    db.db.execute(
      "UPDATE feedback SET status = 'handled', reply = ?, handled_at = 60000 "
      'WHERE id = ?',
      [reply, id],
    );
  }
}

/// Pumps the workspace on [db] (default [seedCommentVault]), opens
/// [noteId] and shows its Activity tab.
Future<ActivityRig> pumpActivityRig(
  WidgetTester tester, {
  FakeVaultDb? db,
  String noteId = commentNoteId,
  FakeMemexCli? cli,
}) async {
  final database = db ?? seedCommentVault();
  final fakeCli = cli ?? commentCli(database);
  final doubles = AccessDoubles();
  final h = await pumpWorkspace(
    tester,
    db: database,
    cli: fakeCli,
    overrides: [doubles.override],
  );
  await openNoteTab(tester, h, noteId);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state =
      RightPanelTab.activity;
  await pumpFrames(tester);
  return ActivityRig(tester, h, doubles, fakeCli);
}

/// Bumps the vault revision once, as a poll of the vault would.
void bumpRevision(ActivityRig rig) {
  rig.h.container.read(vaultRevisionProvider.notifier).state++;
}
