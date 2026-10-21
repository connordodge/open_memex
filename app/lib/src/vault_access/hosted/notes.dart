import 'dart:convert';

import '../../cli/note_cli.dart';
import '../../db.dart';
import '../../memex_cli.dart';
import '../notes_access.dart';
import 'hosted_client.dart';

/// [NotesAccess] for a hosted vault (D11 V1, D13): every read and write is
/// one `/vaults/<vaultName>/api/v1` route through [client] (D17).
///
/// A write sends an optional field only when the `MemexCli` wrapper would
/// pass its flag, and labels its errors with the wrapper's operation (`add`,
/// `update`, `rm`, `add-link`, `update-link`; reads use `get`). Writes leave
/// `vaultRevisionProvider` to their call sites.
class HostedNotesAccess implements NotesAccess {
  HostedNotesAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
  }) => client.vaultRequest(
    method,
    vaultName,
    path,
    operation: operation,
    query: query,
    body: body,
  );

  static String _note(String id) => '/notes/${Uri.encodeComponent(id)}';

  static List<Map<String, Object?>> _rows(Object? list) =>
      (list as List).cast<Map<String, Object?>>();

  static int _int(Object? n) => (n as num).toInt();

  // ---------- reads ----------

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) async {
    final json = await _call(
      'GET',
      '/notes',
      operation: 'get',
      query: {'limit': '$limit'},
    );
    return [
      for (final r in _rows(json['notes']))
        NoteListItem(
          id: r['id'] as String,
          title: r['title'] as String,
          snippet: r['snippet'] as String,
          version: _int(r['version']),
          updatedAt: _int(r['updated_at']),
        ),
    ];
  }

  /// The `memex get` object as today's [Note]. A frontmatter object is
  /// re-encoded as JSON text; a string is the stored text the server could
  /// not parse, kept as is (like `VaultDb.getNote`). Null only for
  /// `not_found`.
  @override
  Future<Note?> getNote(String id) async {
    final Map<String, Object?> json;
    try {
      json = await _call('GET', _note(id), operation: 'get');
    } on MemexException catch (e) {
      if (e.code == 'not_found') return null;
      rethrow;
    }
    final frontmatter = json['frontmatter'];
    return Note(
      id: json['note_id'] as String,
      title: json['title'] as String,
      contentMd: json['content_md'] as String,
      frontmatter: frontmatter is String
          ? frontmatter
          : jsonEncode(frontmatter),
      version: _int(json['version']),
      createdAt: _int(json['created_at']),
      updatedAt: _int(json['updated_at']),
      tags: (json['tags'] as List).cast<String>(),
    );
  }

  @override
  Future<List<NoteTitle>> allTitles({int limit = 1000}) async {
    final json = await _call(
      'GET',
      '/titles',
      operation: 'get',
      query: {'limit': '$limit'},
    );
    return [
      for (final r in _rows(json['titles']))
        NoteTitle(
          id: r['id'] as String,
          title: r['title'] as String,
          updatedAt: _int(r['updated_at']),
        ),
    ];
  }

  static List<LinkRow> _links(Map<String, Object?> json) => [
    for (final r in _rows(json['links']))
      LinkRow(
        id: r['id'] as String,
        fromNoteId: r['from_note_id'] as String,
        toNoteId: r['to_note_id'] as String?,
        linkText: r['link_text'] as String,
        kind: r['kind'] as String,
        label: r['label'] as String?,
        position: _int(r['position']),
        source: r['source'] as String,
      ),
  ];

  @override
  Future<List<LinkRow>> linksOutFor(String noteId) async => _links(
    await _call('GET', '${_note(noteId)}/links/out', operation: 'get'),
  );

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) async =>
      _links(
        await _call(
          'GET',
          '${_note(noteId)}/links/in',
          operation: 'get',
          query: kind == null ? null : {'kind': kind},
        ),
      );

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async {
    final json = await _call(
      'POST',
      '/titles/lookup',
      operation: 'get',
      body: {'ids': ids},
    );
    return (json['titles'] as Map).cast<String, String>();
  }

  @override
  Future<List<String>> distinctLinkKinds() async {
    final json = await _call('GET', '/link-kinds', operation: 'get');
    return (json['kinds'] as List).cast<String>();
  }

  // ---------- writes ----------

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) async {
    final json = await _call(
      'POST',
      '/notes',
      operation: 'add',
      body: {
        if (title != null && title.isNotEmpty) 'title': title,
        // Match the local argv (`--tags tags.join(',')`, clap value_delimiter
        // ','): a tag containing a comma is stored as several tags.
        if (tags.isNotEmpty) 'tags': tags.join(',').split(','),
        'role': ?role,
        'content_md': contentMd,
      },
    );
    return json['note_id'] as String;
  }

  @override
  Future<NoteUpdateResult> updateNote({
    required String noteId,
    required int expectedVersion,
    String? title,
    required String contentMd,
    bool noRenameLinks = false,
  }) async {
    final json = await _call(
      'PATCH',
      _note(noteId),
      operation: 'update',
      body: {
        'expected_version': expectedVersion,
        if (title != null && title.isNotEmpty) 'title': title,
        'content_md': contentMd,
        if (noRenameLinks) 'no_rename_links': true,
      },
    );
    return NoteUpdateResult(
      noteId: json['note_id'] as String,
      version: _int(json['version']),
      updatedAt: _int(json['updated_at']),
    );
  }

  @override
  Future<NoteDeleteResult> deleteNote({
    required String noteId,
    required int expectedVersion,
  }) async {
    final json = await _call(
      'DELETE',
      _note(noteId),
      operation: 'rm',
      query: {'expected_version': '$expectedVersion'},
    );
    return NoteDeleteResult(
      vaultId: json['vault_id'] as String,
      noteId: json['note_id'] as String,
      deleted: json['deleted'] as bool,
    );
  }

  @override
  Future<AddLinkResult> addLink({
    required String fromNoteId,
    required String toNoteId,
    String kind = 'references',
    String? label,
  }) async {
    final json = await _call(
      'POST',
      '/links',
      operation: 'add-link',
      body: {
        'from': fromNoteId,
        'to': toNoteId,
        'kind': kind,
        if (label != null && label.isNotEmpty) 'label': label,
      },
    );
    return AddLinkResult(
      linkId: json['link_id'] as String?,
      fromNoteId: json['from'] as String,
      toNoteId: json['to'] as String,
      kind: json['kind'] as String,
      source: json['source'] as String,
      wasExisting: json['was_existing'] as bool,
      noteVersion: _int(json['note_version']),
    );
  }

  @override
  Future<UpdateLinkResult> updateLink({
    required String linkId,
    String? kind,
    String? label,
    bool clearLabel = false,
  }) async {
    final json = await _call(
      'PATCH',
      '/links/${Uri.encodeComponent(linkId)}',
      operation: 'update-link',
      body: {
        if (kind != null && kind.isNotEmpty) 'kind': kind,
        if (label != null && !clearLabel) 'label': label,
        if (clearLabel) 'clear_label': true,
      },
    );
    return UpdateLinkResult(
      linkId: json['link_id'] as String,
      fromNoteId: json['from_note_id'] as String,
      toNoteId: json['to_note_id'] as String?,
      kind: json['kind'] as String,
      label: json['label'] as String?,
      source: json['source'] as String,
      position: _int(json['position']),
    );
  }
}
