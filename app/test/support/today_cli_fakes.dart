import 'dart:async';
import 'dart:convert';

import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// Id the fake `memex add --role daily` prints for a created daily note
/// (the C1/C2.1 sample id).
const createdDailyId = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';

/// C2.1 stdout of `memex add --role daily` (first line `Created note` or, for
/// a Q2 adoption, `Adopted note`).
String addDailyStdout(String noteId, String date, {bool adopted = false}) =>
    '${adopted ? 'Adopted' : 'Created'} note\n'
    '  note_id: $noteId\n'
    '  title:   $date\n';

/// FakeMemexCli handlers for the virtual Today flow (#22, D20). Each handler
/// mirrors what the real CLI does to the vault on the [FakeVaultDb], so the
/// app's direct SQLite reads see the result.
extension TodayCliFakes on FakeMemexCli {
  /// `memex add --role daily`: inserts a `role: daily` note titled `--title`
  /// with the stdin person text normalised to the canonical daily body (C3),
  /// version 1, and prints the C2.1 `Created note` block. When [gate] is
  /// given the CLI call does not answer until the gate completes.
  void onAddDailyCreates(
    FakeVaultDb db, {
    String id = createdDailyId,
    Completer<void>? gate,
  }) {
    on('add', (call) async {
      if (gate != null) await gate.future;
      final date = call.flag('title')!;
      final person = splitDailyBody(call.stdinBody ?? '').person;
      db.seedNote(
        id: id,
        title: date,
        content: assembleDailyBody(person, const []),
        role: 'daily',
        version: 1,
        createdAt: 1759474800000,
      );
      return FakeMemexCli.ok(addDailyStdout(id, date));
    });
  }

  /// `memex add` answers with [result] and leaves the vault untouched.
  void onAddReturns(MemexResult result) {
    on('add', (_) => result);
  }

  /// `memex update`: checks `--expected-version` against the row (C1
  /// `version_conflict` on mismatch), writes stdin as the new content, bumps
  /// the version and prints the update JSON.
  void onUpdateWrites(FakeVaultDb db) {
    on('update', (call) {
      final id = call.flag('note-id')!;
      final expected = int.parse(call.flag('expected-version')!);
      final rows = db.db.select('SELECT version FROM notes WHERE id = ?', [id]);
      if (rows.isEmpty) {
        return FakeMemexCli.error('not_found', 'note $id not found');
      }
      final current = (rows.first['version'] as num).toInt();
      if (current != expected) {
        return FakeMemexCli.error(
          'version_conflict',
          'version conflict: expected $expected, current $current',
          {'expected': expected, 'current': current},
        );
      }
      final next = current + 1;
      db.db.execute(
        'UPDATE notes SET content_md = ?, version = ?, updated_at = ? '
        'WHERE id = ?',
        [call.stdinBody ?? '', next, 1759478400000, id],
      );
      return FakeMemexCli.ok(
        jsonEncode({
          'vault_id': '01HV0000000000000000000000',
          'note_id': id,
          'version': next,
          'updated_at': 1759478400000,
        }),
      );
    });
  }
}
