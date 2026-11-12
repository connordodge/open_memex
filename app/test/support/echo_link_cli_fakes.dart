// WI #429 (391-A4): FakeMemexCli handlers for an echo's `link`. Each mirrors
// what the real CLI does to the vault on the [FakeVaultDb], so the app's
// direct SQLite reads see the result:
// - `memex add-link` with kind `references` adds `[[<to title>]]` at the end
//   of the source note's `## Auto-added links` section, creating it at the
//   bottom of the body when absent (crates/memex-mcp/src/md_links.rs),
//   records the link row and bumps the source note's version;
// - `memex echoes` answers fixed echoes per note, minus every note already
//   linked to it in either direction (a link row or a footer chip), as the
//   real `echoes()` excludes linked notes.
import 'dart:async';
import 'dart:convert';

import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';

/// [content] after `add_link` appended `[[<targetTitle>]]` to a body with no
/// `## Auto-added links` section yet (md_links.rs `insert_into_auto_added`).
String wi429WithAutoAddedLink(String content, String targetTitle) {
  var out = content;
  while (out.endsWith('\n')) {
    out = out.substring(0, out.length - 1);
  }
  return '$out\n\n## Auto-added links\n\n[[$targetTitle]]\n';
}

/// [content] after `add_link` (kind `references`) added `[[<targetTitle>]]`,
/// as md_links.rs `insert_into_auto_added` does it for a body with no Note
/// footer: at the end of an existing `## Auto-added links` section (up to the
/// next `# `, `## ` or `###` line), else in a new section at the bottom
/// ([wi429WithAutoAddedLink]).
String wi429InsertAutoAddedLink(String content, String targetTitle) {
  final lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final start = lines.indexWhere((l) => l.trim() == '## Auto-added links');
  if (start < 0) return wi429WithAutoAddedLink(content, targetTitle);
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    final l = lines[i];
    if (l.startsWith('# ') || l.startsWith('## ') || l.startsWith('###')) {
      end = i;
      break;
    }
  }
  final out = StringBuffer(lines.sublist(0, end).join('\n'))..write('\n');
  if (start + 1 == end) out.write('\n');
  out.write('[[$targetTitle]]\n');
  if (end < lines.length) {
    out
      ..write(lines.sublist(end).join('\n'))
      ..write('\n');
  }
  return out.toString();
}

/// One echo row as `memex echoes` prints it (V4 shape).
Map<String, Object?> wi429EchoRow({
  required String noteId,
  required String title,
  String? role,
  String? day,
  String passage = 'A passage.',
  int? startByte = 0,
  int updatedAt = 1759000000000,
}) => {
  'note_id': noteId,
  'note_title': title,
  'note_role': role,
  'day': day,
  'passage': passage,
  'start_byte': startByte,
  'note_updated_at': updatedAt,
};

extension EchoLinkCliFakes on FakeMemexCli {
  /// `memex add-link --from F --to T --kind K`: `not_found` for a missing
  /// note; otherwise appends the auto-added link to F's body (kind
  /// `references`), inserts the link row, bumps F's version and prints the
  /// add-link JSON with F's new `note_version`. While [gate] is set, the
  /// call waits for it before it writes anything; while [afterWrite] is set,
  /// it waits for that after the write is applied and before it answers.
  void onAddLinkWrites(
    FakeVaultDb db, {
    Completer<void>? Function()? gate,
    Completer<void>? Function()? afterWrite,
  }) {
    on('add-link', (call) async {
      final held = gate?.call();
      if (held != null) await held.future;
      final from = call.flag('from')!;
      final to = call.flag('to')!;
      final kind = call.flag('kind') ?? 'references';
      final source = db.db.select(
        'SELECT content_md, version FROM notes WHERE id = ?',
        [from],
      );
      final target = db.db.select('SELECT title FROM notes WHERE id = ?', [to]);
      if (source.isEmpty || target.isEmpty) {
        return FakeMemexCli.error('not_found', 'note not found');
      }
      final title = target.first['title'] as String;
      final body = source.first['content_md'] as String;
      final next = (source.first['version'] as num).toInt() + 1;
      final position =
          (db.db.select(
                    'SELECT COUNT(*) AS n FROM links WHERE from_note_id = ?',
                    [from],
                  ).first['n']
                  as num)
              .toInt();
      final linkId = 'link-$from-$to';
      db.db.execute(
        'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
        [
          kind == 'references' ? wi429InsertAutoAddedLink(body, title) : body,
          next,
          from,
        ],
      );
      db.db.execute(
        'INSERT INTO links (id, from_note_id, to_note_id, link_text, '
        'link_kind, position, source) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [linkId, from, to, title, kind, position, 'auto_added'],
      );
      final answered = afterWrite?.call();
      if (answered != null) await answered.future;
      return FakeMemexCli.ok(
        '${jsonEncode({'link_id': linkId, 'from': from, 'to': to, 'kind': kind, 'source': 'auto_added', 'was_existing': false, 'note_version': next})}\n',
      );
    });
  }

  /// `memex echoes --note-id N`: the rows [byNote] lists for N (none when
  /// absent), minus every echo already linked to N either way (a `links` row
  /// or a footer chip), with `pending: 0`.
  void onEchoesExcludingLinked(
    FakeVaultDb db,
    Map<String, List<Map<String, Object?>>> byNote,
  ) {
    on('echoes', (call) {
      final noteId = call.flag('note-id')!;
      bool linked(String other) =>
          db.db.select(
            'SELECT 1 FROM links WHERE (from_note_id = ? AND to_note_id = ?) '
            'OR (from_note_id = ? AND to_note_id = ?)',
            [noteId, other, other, noteId],
          ).isNotEmpty ||
          db.db.select(
            'SELECT 1 FROM footer_chips WHERE (daily_note_id = ? AND '
            'topic_note_id = ?) OR (daily_note_id = ? AND topic_note_id = ?)',
            [noteId, other, other, noteId],
          ).isNotEmpty;
      final rows = [
        for (final row in byNote[noteId] ?? const <Map<String, Object?>>[])
          if (!linked(row['note_id']! as String)) row,
      ];
      return FakeMemexCli.ok(
        '${jsonEncode({'echoes': rows, 'pending': 0, 'reason': null})}\n',
      );
    });
  }
}
