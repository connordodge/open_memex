// WI #83 (V3), verify-mode pins: contracts of HostedTopicsAccess that the
// implementer handoff listed as unpinned.
//
// - A 2xx response that is not the contract shape throws a null-code
//   MemexException whose message starts with the call's operation label,
//   for every call (the CLI wrappers' "could not parse output").
// - The two reads with no CLI wrapper label their errors `smart folders`
//   and `unsorted notes`.
// - A non-string frontmatter role fails the local unsortedNotes read, as
//   GET /unsorted answers 500 for it (parity of failure; the Rust half is
//   api_topics.rs get_unsorted_answers_500_on_a_non_string_role).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';
import 'package:open_memex_app/src/vault_access/local/topics.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';

const _wi83cBase = '/vaults/seed/api/v1';
const _wi83cInbox = '01M5DQAYZHJTTW6PPF4P7GNCHN';
const _wi83cLoose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi83cMaxDepth = 'smart_folder_max_depth';

(FakeVaultServer, HostedTopicsAccess) _wi83cEnv() {
  final server = FakeVaultServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return (
    server,
    HostedTopicsAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
  );
}

Future<Object?> _wi83cOutcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// One hosted call: its operation label, route, success status and call.
typedef _Wi83cCall = (
  String label,
  String method,
  String path,
  int status,
  Future<Object?> Function(HostedTopicsAccess t) call,
);

final List<_Wi83cCall> _wi83cWrites = [
  (
    'folder new',
    'POST',
    '/smart-folders',
    201,
    (t) => t.createFolder(name: 'Mechanics'),
  ),
  (
    'folder update',
    'PATCH',
    '/smart-folders/$_wi83cInbox',
    200,
    (t) => t.updateFolder(id: _wi83cInbox, name: 'Later'),
  ),
  (
    'folder rm',
    'DELETE',
    '/smart-folders/$_wi83cInbox',
    200,
    (t) => t.deleteFolder(id: _wi83cInbox),
  ),
  (
    'folder add',
    'POST',
    '/smart-folders/$_wi83cInbox/members',
    200,
    (t) => t.addToFolder(folderId: _wi83cInbox, noteId: _wi83cLoose),
  ),
  (
    'settings get',
    'GET',
    '/settings/$_wi83cMaxDepth',
    200,
    (t) => t.getSetting(_wi83cMaxDepth),
  ),
  (
    'settings set',
    'PUT',
    '/settings/$_wi83cMaxDepth',
    200,
    (t) => t.setSetting(_wi83cMaxDepth, 3),
  ),
  ('prompt review', 'GET', '/prompts/review', 200, (t) => t.reviewPrompt()),
];

final List<_Wi83cCall> _wi83cReads = [
  ('smart folders', 'GET', '/smart-folders', 200, (t) => t.smartFolders()),
  ('unsorted notes', 'GET', '/unsorted', 200, (t) => t.unsortedNotes()),
];

/// Bodies no topics call accepts: not an object, an empty object, and an
/// object of the right keys with every value the wrong type.
const List<String> _wi83cCommonBadBodies = [
  '[]',
  '"text"',
  '{}',
  '{"error": "not a C1 object"}',
];

/// Per-call bodies that are close to the contract shape but wrong.
final Map<String, List<Object?>> _wi83cNearMisses = {
  'folder new': [
    {
      'vault_id': 'v',
      'id': 'f',
      'name': 'n',
      'parent_id': null,
      'pinned': 'yes',
      'depth': 1,
      'created_at': 1,
      'updated_at': 1,
    },
  ],
  'folder update': [
    {
      'vault_id': 'v',
      'id': 'f',
      'name': 'n',
      'parent_id': null,
      'pinned': true,
      'depth': '1',
      'created_at': 1,
      'updated_at': 1,
    },
  ],
  'folder rm': [
    {'vault_id': 'v', 'id': 'f', 'deleted': 'true'},
    {'vault_id': 'v', 'id': 'f'},
  ],
  'folder add': [
    {'vault_id': 'v', 'smart_folder_id': 'f', 'note_id': 'n', 'pinned': true},
    {
      'vault_id': 'v',
      'smart_folder_id': 'f',
      'note_id': 'n',
      'pinned': true,
      'role_set': 1,
    },
  ],
  'settings get': [
    {'vault_id': 'v', 'key': _wi83cMaxDepth, 'value': '2'},
    {'vault_id': 'v', 'key': _wi83cMaxDepth, 'value': 2.5},
    {'vault_id': 'v', 'key': _wi83cMaxDepth},
  ],
  'settings set': [
    {'vault_id': 'v', 'key': _wi83cMaxDepth, 'value': null},
  ],
  'prompt review': [
    {'text': 5},
    {'text': null},
  ],
  'smart folders': [
    {'max_depth': 2, 'members': []},
    {
      'max_depth': 2,
      'folders': [
        {'id': 5, 'name': 'n', 'parent_id': null, 'pinned': true},
      ],
      'members': [],
    },
    {
      'max_depth': 2,
      'folders': [],
      'members': [
        {'folder_id': 'f', 'note_id': 'n', 'title': 't'},
      ],
    },
  ],
  'unsorted notes': [
    {'notes': null},
    {
      'notes': [
        {'note_id': 'n', 'title': 't', 'role': 5},
      ],
    },
    {
      'notes': [
        {'note_id': 1, 'title': 't', 'role': null},
      ],
    },
  ],
};

Future<void> _wi83cExpectBadShapesThrow(List<_Wi83cCall> calls) async {
  for (final (label, method, path, status, call) in calls) {
    final bodies = [
      ..._wi83cCommonBadBodies,
      for (final b in _wi83cNearMisses[label]!) jsonEncode(b),
    ];
    for (final body in bodies) {
      final (server, topics) = _wi83cEnv();
      server.route(method, '$_wi83cBase$path', status: status, body: body);
      final e = await _wi83cOutcome(call(topics));
      final why = '$label on $body';
      expect(e, isA<MemexException>(), reason: why);
      e as MemexException;
      expect(e.code, isNull, reason: why);
      expect(e.message, startsWith(label), reason: why);
    }
  }
}

void main() {
  test(
    'every hosted topics write and settings or prompt call throws a null-code MemexException on a bad response shape',
    () => _wi83cExpectBadShapesThrow(_wi83cWrites),
  );

  test(
    'hosted smartFolders and unsortedNotes throw a null-code MemexException on a bad response shape',
    () => _wi83cExpectBadShapesThrow(_wi83cReads),
  );

  test(
    'hosted smartFolders and unsortedNotes label their errors smart folders and unsorted notes',
    () async {
      for (final (label, method, path, _, call) in _wi83cReads) {
        final (server, topics) = _wi83cEnv();
        server.route(
          method,
          '$_wi83cBase$path',
          status: 500,
          json: {
            'error': {
              'code': 'internal',
              'message': 'disk on fire',
              'detail': 7,
            },
          },
        );
        final e = await _wi83cOutcome(call(topics));
        expect(e, isA<MemexException>(), reason: label);
        e as MemexException;
        expect(e.message, '$label failed: disk on fire', reason: label);
        expect(e.code, 'internal', reason: label);
        expect(e.fields, {'detail': 7}, reason: label);

        final (server2, topics2) = _wi83cEnv();
        server2.route(
          method,
          '$_wi83cBase$path',
          status: 502,
          body: '<html>bad gateway</html>',
          contentType: 'text/html',
        );
        final e2 = await _wi83cOutcome(call(topics2));
        expect(e2, isA<MemexException>(), reason: label);
        e2 as MemexException;
        expect(e2.message, '$label failed: HTTP 502', reason: label);
        expect(e2.code, isNull, reason: label);
      }
    },
  );

  test(
    'a non-string frontmatter role fails the local unsortedNotes read as GET unsorted does',
    () async {
      for (final role in ['5', 'true', '2.5']) {
        final db = seededFakeVaultDb();
        addTearDown(db.close);
        db.db.execute('UPDATE notes SET frontmatter = ? WHERE id = ?', [
          '{"role": $role}',
          _wi83cLoose,
        ]);
        final local = LocalTopicsAccess(vaultPath: '/unused/wi83c', db: db);
        expect(
          await _wi83cOutcome(local.unsortedNotes()),
          isA<Error>(),
          reason: 'role $role: the local read throws, never drops the row',
        );
      }
      // Control: a string role on the same note is read and kept.
      final db = seededFakeVaultDb();
      addTearDown(db.close);
      db.db.execute('UPDATE notes SET frontmatter = ? WHERE id = ?', [
        '{"role": "topic"}',
        _wi83cLoose,
      ]);
      final rows = await LocalTopicsAccess(
        vaultPath: '/unused/wi83c',
        db: db,
      ).unsortedNotes();
      expect(rows.where((r) => r.noteId == _wi83cLoose).map((r) => r.role), [
        'topic',
      ]);
    },
  );
}
