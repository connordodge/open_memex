import '../../db/tags_reads.dart';
import '../../memex_cli.dart';
import '../tags_access.dart';
import 'hosted_client.dart';

/// [TagsAccess] for a hosted vault: every read and write is one
/// `/vaults/<vaultName>/api/v1` route through [client] (D17), frozen in #242
/// (T4b). Each `{tag}` is percent-encoded into its path segment. A response
/// that is not the contract shape throws a null-code [MemexException]. Writes
/// leave `vaultRevisionProvider` to their call sites.
class HostedTagsAccess implements TagsAccess {
  HostedTagsAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    required String operation,
  }) => client.vaultRequest(method, vaultName, path, operation: operation);

  /// Every element of `json[key]` through [parse]; a null-code
  /// [MemexException] labelled [operation] when it is not a list or [parse]
  /// rejects an element.
  static List<T> _rows<T>(
    String operation,
    Map<String, Object?> json,
    String key,
    T? Function(Map row) parse,
  ) {
    final list = json[key];
    if (list is List) {
      final rows = <T>[];
      for (final r in list) {
        final row = r is Map ? parse(r) : null;
        if (row == null) break;
        rows.add(row);
      }
      if (rows.length == list.length) return rows;
    }
    throw MemexException('$operation: could not parse output: $json');
  }

  static TagRow? _tagRow(Map r) {
    if (r case {
      'tag': final String tag,
      'note_count': final int noteCount,
      'system': final bool system,
    }) {
      return TagRow(tag: tag, noteCount: noteCount, system: system);
    }
    return null;
  }

  static TagNoteRow? _noteRow(Map r) {
    if (r case {
      'note_id': final String noteId,
      'title': final String title,
      'updated_at': final int updatedAt,
    }) {
      if ((r['role'], r['first_line']) case (
        final String? role,
        final String? firstLine,
      )) {
        return TagNoteRow(
          noteId: noteId,
          title: title,
          role: role,
          firstLine: firstLine,
          updatedAt: updatedAt,
        );
      }
    }
    return null;
  }

  /// `GET /tags`.
  @override
  Future<List<TagRow>> allTags() async {
    const op = 'tags';
    final json = await _call('GET', '/tags', operation: op);
    return _rows(op, json, 'tags', _tagRow);
  }

  /// `GET /tags/{tag}/notes`.
  @override
  Future<List<TagNoteRow>> notesForTag(String tag) async {
    const op = 'tag notes';
    final json = await _call(
      'GET',
      '/tags/${Uri.encodeComponent(tag)}/notes',
      operation: op,
    );
    return _rows(op, json, 'notes', _noteRow);
  }

  /// `DELETE /notes/{note_id}/tags/{tag}` (no body).
  @override
  Future<TagRmResult> removeTag(String noteId, String tag) async {
    const op = 'tag rm';
    final json = await _call(
      'DELETE',
      '/notes/${Uri.encodeComponent(noteId)}/tags/${Uri.encodeComponent(tag)}',
      operation: op,
    );
    final result = parseTagRmResult(json);
    if (result == null) {
      throw MemexException('$op: could not parse output: $json');
    }
    return result;
  }
}
