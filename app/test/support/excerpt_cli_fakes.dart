import 'dart:convert';

import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// C2.4 stdout sample of `memex excerpt rm`, verbatim (D19; #10's Rust CLI
/// test asserts the same literal).
const excerptRmC24Sample =
    '{"vault_id":"01HV…","topic_note_id":"01J9…","version":5}';

/// `excerpt rm` handlers for [FakeMemexCli] (C2.4, WI #27).
extension ExcerptCliFakes on FakeMemexCli {
  /// Behaves like `memex excerpt rm` against [db]: finds the first line of
  /// the `--topic-note-id` note whose content (trailing spaces and `\r`
  /// ignored) is exactly the token `![[<date>#^<from>]]` or
  /// `![[<date>#^<from>..^<to>]]` built from `--date` and `--block-ids`,
  /// deletes that line (with its `\n`), sets the note's version to
  /// [newVersion] (default: current + 1) and answers the C2.4 shape with that
  /// version. A missing note or token answers C1 `not_found`.
  void onExcerptRmRemoves(FakeVaultDb db, {int? newVersion}) {
    on('excerpt rm', (call) {
      final topicId = call.flag('topic-note-id')!;
      final date = call.flag('date')!;
      final ids = call.flag('block-ids')!.split(',');
      final token = ids.length == 1
          ? '![[$date#^${ids[0]}]]'
          : '![[$date#^${ids[0]}..^${ids[1]}]]';
      final rows = db.db.select(
        'SELECT content_md, version FROM notes WHERE id = ?',
        [topicId],
      );
      if (rows.isEmpty) {
        return FakeMemexCli.error('not_found', 'note $topicId not found');
      }
      final body = rows.first['content_md'] as String;
      final current = (rows.first['version'] as num).toInt();
      var start = 0;
      int? lineStart;
      int? lineEnd;
      while (start < body.length) {
        final nl = body.indexOf('\n', start);
        final end = nl < 0 ? body.length : nl + 1;
        final content = body
            .substring(start, nl < 0 ? body.length : nl)
            .replaceFirst(RegExp(r'[ \r]+$'), '');
        if (content == token) {
          lineStart = start;
          lineEnd = end;
          break;
        }
        start = end;
      }
      if (lineStart == null) {
        return FakeMemexCli.error('not_found', 'no such transclusion: $token');
      }
      final next = newVersion ?? current + 1;
      db.db.execute(
        'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
        [
          body.substring(0, lineStart) + body.substring(lineEnd!),
          next,
          topicId,
        ],
      );
      return FakeMemexCli.ok(
        '${jsonEncode({'vault_id': '01HV0000000000000000000000', 'topic_note_id': topicId, 'version': next})}\n',
      );
    });
  }

  /// `excerpt rm` fails with the C1 error [code] / [message] and leaves the
  /// vault untouched.
  void onExcerptRmFails(String code, String message) {
    on('excerpt rm', (_) => FakeMemexCli.error(code, message));
  }
}
