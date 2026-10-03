import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

import 'app_harness.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// Stand-ins for the server's review bookkeeping (D9) in app tests.
class ReviewFakes {
  ReviewFakes._();

  /// A `memex update` handler for `FakeMemexCli.on('update', ...)`: writes
  /// the new body (stdin) into [db], bumps `notes.version` and, when the
  /// daily person section changed, bumps `day_reviews.content_version`, as
  /// the real server does. Answers with the CLI's `{note_id, version,
  /// updated_at}` JSON, or a `version_conflict` error on a stale
  /// `--expected-version`.
  static FakeCliHandler onUpdate(FakeVaultDb db) => (call) {
    final noteId = call.flag('note-id')!;
    final expected = int.parse(call.flag('expected-version')!);
    final rows = db.db.select(
      'SELECT content_md, version FROM notes WHERE id = ?',
      [noteId],
    );
    if (rows.isEmpty) {
      return FakeMemexCli.error('not_found', 'no such note', {'id': noteId});
    }
    final current = (rows.first['version'] as num).toInt();
    if (current != expected) {
      return FakeMemexCli.error('version_conflict', 'stale version');
    }
    final oldBody = rows.first['content_md'] as String;
    final newBody = call.stdinBody ?? '';
    final personChanged =
        splitDailyBody(oldBody).person != splitDailyBody(newBody).person;
    final next = current + 1;
    const updatedAt = 1759600000000;
    db.db.execute(
      'UPDATE notes SET content_md = ?, version = ?, updated_at = ? '
      'WHERE id = ?',
      [newBody, next, updatedAt, noteId],
    );
    if (personChanged) {
      db.db.execute(
        'UPDATE day_reviews SET content_version = content_version + 1 '
        'WHERE note_id = ?',
        [noteId],
      );
    }
    return FakeMemexCli.ok(
      jsonEncode({'note_id': noteId, 'version': next, 'updated_at': updatedAt}),
    );
  };
}

/// Open [noteId] in the pumped workspace as the active note tab.
Future<void> openNoteTab(
  WidgetTester tester,
  WorkspaceHarness h,
  String noteId,
) async {
  h.container.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
  await pumpFrames(tester);
}
