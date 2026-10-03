// WI #26 (A14): FakeMemexCli handlers for creating topic notes and recording
// footer chips. Each handler mirrors what the real CLI does to the vault on
// the [FakeVaultDb], so the app's direct SQLite reads see the result.
import 'dart:convert';

import 'package:open_memex_app/src/editor/segments.dart';

import 'daily_seed.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'today_cli_fakes.dart';

/// Id the fake `memex add --role topic` gives the created topic note.
const createdTopicId = '01J9Z8Y7X6W5V4T3S2R1Q0TOPC';

/// Id the fake `memex add` (no role) gives a created role-less note.
const createdPlainId = '01J9Z8Y7X6W5V4T3S2R1Q0PLN1';

/// C2.3 sample stdout of `memex footer add`.
const footerAddSample =
    '{"vault_id":"01HV0000000000000000000000","daily_note_id":"01J9Z8Y7X6W5V4T3S2R1Q0P9N8","topic_note_id":"01J9Z8Y7X6W5V4T3S2R1Q0TOPC","origin":"person","version":7}';

extension FooterCliFakes on FakeMemexCli {
  /// `memex add` dispatching on `--role`: `daily` creates the daily note
  /// (id [dailyId]), `topic` creates a `role: topic` note (id [topicId]) and
  /// no role creates a role-less note (id [plainId]). A title already used
  /// by a note in [db] fails with the C1 `title_conflict` (for `--role daily`
  /// with `daily_note_exists`).
  void onAddCreates(
    FakeVaultDb db, {
    String dailyId = createdDailyId,
    String topicId = createdTopicId,
    String plainId = createdPlainId,
  }) {
    on('add', (call) {
      final title = call.flag('title') ?? '';
      final role = call.flag('role');
      final taken = db.db.select('SELECT id FROM notes WHERE title = ?', [
        title,
      ]);
      if (taken.isNotEmpty) {
        return FakeMemexCli.error(
          role == 'daily' ? 'daily_note_exists' : 'title_conflict',
          'a note titled "$title" already exists',
          {'existing_id': taken.first['id']},
        );
      }
      switch (role) {
        case 'daily':
          final person = splitDailyBody(call.stdinBody ?? '').person;
          db.seedNote(
            id: dailyId,
            title: title,
            content: assembleDailyBody(person, const []),
            role: 'daily',
            version: 1,
          );
          return FakeMemexCli.ok(addDailyStdout(dailyId, title));
        case 'topic':
          db.seedTopicNote(topicId, title);
          return FakeMemexCli.ok(addDailyStdout(topicId, title));
        default:
          db.seedNote(id: plainId, title: title, content: call.stdinBody ?? '');
          return FakeMemexCli.ok(addDailyStdout(plainId, title));
      }
    });
  }

  /// `memex footer add`: `not_found` for a missing note, `role_rule` unless
  /// the daily id is a `role: daily` note and the topic id a `role: topic`
  /// note, otherwise inserts a `person` chip (upgrading an `excerpt` chip),
  /// bumps the daily note's version and answers the C2.3 shape.
  void onFooterAdd(FakeVaultDb db) {
    on('footer add', (call) {
      final dailyId = call.flag('daily-note-id');
      final topicId = call.flag('topic-note-id');
      String? roleOf(String? id) {
        final rows = db.db.select(
          'SELECT frontmatter FROM notes WHERE id = ?',
          [id],
        );
        if (rows.isEmpty) return '<missing>';
        final fm = jsonDecode(rows.first['frontmatter'] as String);
        return fm is Map ? fm['role'] as String? : null;
      }

      final dailyRole = roleOf(dailyId);
      final topicRole = roleOf(topicId);
      if (dailyRole == '<missing>' || topicRole == '<missing>') {
        return FakeMemexCli.error('not_found', 'note not found');
      }
      if (dailyRole != 'daily' || topicRole != 'topic') {
        return FakeMemexCli.error(
          'role_rule',
          'footer chips link a daily note to a topic note',
        );
      }
      final existing = db.db.select(
        'SELECT origin FROM footer_chips WHERE daily_note_id = ? '
        'AND topic_note_id = ?',
        [dailyId, topicId],
      );
      if (existing.isEmpty) {
        db.seedFooterChip(dailyId!, topicId!, origin: 'person');
      } else {
        db.db.execute(
          "UPDATE footer_chips SET origin = 'person' WHERE daily_note_id = ? "
          'AND topic_note_id = ?',
          [dailyId, topicId],
        );
      }
      db.db.execute('UPDATE notes SET version = version + 1 WHERE id = ?', [
        dailyId,
      ]);
      final version =
          (db.db.select('SELECT version FROM notes WHERE id = ?', [
                    dailyId,
                  ]).first['version']
                  as num)
              .toInt();
      return FakeMemexCli.ok(
        jsonEncode({
          'vault_id': '01HV0000000000000000000000',
          'daily_note_id': dailyId,
          'topic_note_id': topicId,
          'origin': 'person',
          'version': version,
        }),
      );
    });
  }
}
