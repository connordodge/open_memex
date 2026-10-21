import '../../cli/folder_cli.dart';
import '../../db/topics_reads.dart';
import '../../memex_cli.dart';
import '../topics_access.dart';
import 'hosted_client.dart';

/// [TopicsAccess] for a hosted vault (D11 V3, D11a, D13): every read and
/// write is one `/vaults/<vaultName>/api/v1` route through [client] (D17).
///
/// A write sends an optional field only when the `MemexCli` wrapper would
/// pass its flag, and labels its errors with the wrapper's operation
/// (`folder new`, `folder update`, `folder rm`, `folder add`, `settings get`,
/// `settings set`, `prompt review`), so a C1 error keeps its code and fields.
/// Writes leave `vaultRevisionProvider` to their call sites.
class HostedTopicsAccess implements TopicsAccess {
  HostedTopicsAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    required String operation,
    Object? body,
  }) => client.vaultRequest(
    method,
    vaultName,
    path,
    operation: operation,
    body: body,
  );

  static String _folder(String id) =>
      '/smart-folders/${Uri.encodeComponent(id)}';

  static String _setting(String key) => '/settings/${Uri.encodeComponent(key)}';

  static List<Map<String, Object?>> _rows(Object? list) =>
      (list as List).cast<Map<String, Object?>>();

  /// [parse]'s result, or a null-code [MemexException] like the CLI
  /// wrapper's when the response is not the contract shape.
  static T _parsed<T>(
    String operation,
    Map<String, Object?> json,
    T? Function(Map<String, Object?> json) parse,
  ) {
    final result = parse(json);
    if (result == null) {
      throw MemexException('$operation: could not parse output: $json');
    }
    return result;
  }

  // ---------- reads ----------

  /// `GET /smart-folders`. `max_depth` and unknown keys are ignored:
  /// [SmartFolderData] has no field for them.
  @override
  Future<SmartFolderData> smartFolders() async {
    final json = await _call(
      'GET',
      '/smart-folders',
      operation: 'smart folders',
    );
    return SmartFolderData(
      folders: [
        for (final r in _rows(json['folders']))
          SmartFolderRow(
            id: r['id'] as String,
            name: r['name'] as String,
            parentId: r['parent_id'] as String?,
            pinned: r['pinned'] as bool,
          ),
      ],
      members: [
        for (final r in _rows(json['members']))
          SmartFolderMemberRow(
            folderId: r['folder_id'] as String,
            noteId: r['note_id'] as String,
            title: r['title'] as String,
            pinned: r['pinned'] as bool,
          ),
      ],
    );
  }

  /// `GET /unsorted`.
  @override
  Future<List<UnsortedNoteRow>> unsortedNotes() async {
    final json = await _call('GET', '/unsorted', operation: 'unsorted notes');
    return [
      for (final r in _rows(json['notes']))
        UnsortedNoteRow(
          noteId: r['note_id'] as String,
          title: r['title'] as String,
          role: r['role'] as String?,
        ),
    ];
  }

  // ---------- writes (and CLI-served reads) ----------

  /// `POST /smart-folders {name[, parent_id]}`.
  @override
  Future<SmartFolderResult> createFolder({
    required String name,
    String? parentId,
  }) async {
    const op = 'folder new';
    final json = await _call(
      'POST',
      '/smart-folders',
      operation: op,
      body: {'name': name, 'parent_id': ?parentId},
    );
    return _parsed(op, json, _parseFolder);
  }

  /// `PATCH /smart-folders/{id}`: `to_root: true` wins over `parent_id`;
  /// `to_root: false` is never sent.
  @override
  Future<SmartFolderResult> updateFolder({
    required String id,
    String? name,
    String? parentId,
    bool toRoot = false,
    bool? pinned,
  }) async {
    const op = 'folder update';
    final json = await _call(
      'PATCH',
      _folder(id),
      operation: op,
      body: {
        'name': ?name,
        if (toRoot) 'to_root': true else 'parent_id': ?parentId,
        'pinned': ?pinned,
      },
    );
    return _parsed(op, json, _parseFolder);
  }

  /// `DELETE /smart-folders/{id}` (no body).
  @override
  Future<FolderDeleteResult> deleteFolder({required String id}) async {
    const op = 'folder rm';
    final json = await _call('DELETE', _folder(id), operation: op);
    return _parsed(op, json, (json) {
      if (json case {
        'vault_id': final String vaultId,
        'id': final String id,
        'deleted': final bool deleted,
      }) {
        return FolderDeleteResult(vaultId: vaultId, id: id, deleted: deleted);
      }
      return null;
    });
  }

  /// `POST /smart-folders/{id}/members {note_id[, pinned]}`: [pinned] null
  /// leaves the field out (the server pins, as the CLI does).
  @override
  Future<FolderMembershipResult> addToFolder({
    required String folderId,
    required String noteId,
    bool? pinned,
  }) async {
    const op = 'folder add';
    final json = await _call(
      'POST',
      '${_folder(folderId)}/members',
      operation: op,
      body: {'note_id': noteId, 'pinned': ?pinned},
    );
    return _parsed(op, json, (json) {
      if (json case {
        'vault_id': final String vaultId,
        'smart_folder_id': final String smartFolderId,
        'note_id': final String noteId,
        'pinned': final bool pinned,
        'role_set': final bool roleSet,
      }) {
        return FolderMembershipResult(
          vaultId: vaultId,
          smartFolderId: smartFolderId,
          noteId: noteId,
          pinned: pinned,
          roleSet: roleSet,
        );
      }
      return null;
    });
  }

  /// `GET /settings/{key}`: the integer `value`.
  @override
  Future<int> getSetting(String key) async {
    const op = 'settings get';
    return _value(op, await _call('GET', _setting(key), operation: op));
  }

  /// `PUT /settings/{key} {"value": n}`: the stored integer `value`.
  @override
  Future<int> setSetting(String key, int value) async {
    const op = 'settings set';
    final json = await _call(
      'PUT',
      _setting(key),
      operation: op,
      body: {'value': value},
    );
    return _value(op, json);
  }

  /// The integer `value` of a settings response, or a null-code
  /// [MemexException] like `SettingsCli`'s.
  static int _value(String operation, Map<String, Object?> json) {
    final value = json['value'];
    if (value is! int) {
      throw MemexException(
        '$operation: could not parse value from output: $json',
      );
    }
    return value;
  }

  /// `GET /prompts/review`: the raw `text`, unchanged.
  @override
  Future<String> reviewPrompt() async {
    const op = 'prompt review';
    final json = await _call('GET', '/prompts/review', operation: op);
    final text = json['text'];
    if (text is! String) {
      throw MemexException('$op: could not parse output: $json');
    }
    return text;
  }
}

/// The `memex folder new|update` object, or null for any other shape.
SmartFolderResult? _parseFolder(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'id': final String id,
    'name': final String name,
    'parent_id': final String? parentId,
    'pinned': final bool pinned,
    'depth': final int depth,
    'created_at': final int createdAt,
    'updated_at': final int updatedAt,
  }) {
    return SmartFolderResult(
      vaultId: vaultId,
      id: id,
      name: name,
      parentId: parentId,
      pinned: pinned,
      depth: depth,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
  return null;
}
