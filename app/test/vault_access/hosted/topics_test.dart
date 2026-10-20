// WI #83 (V3): HostedTopicsAccess over HostedClient (D11a, D13, D17),
// against the `api_v1/topics` fixture rows replayed by
// `fake_vault_server.dart`.
//
// Pinned wire shapes (under `/vaults/<vault>/api/v1`):
//   reads:  GET /smart-folders -> {max_depth, folders:[{id,name,parent_id,
//             pinned}], members:[{folder_id,note_id,title,pinned}]}
//             (max_depth and unknown keys ignored: SmartFolderData has no
//             field for them)
//           GET /unsorted -> {notes:[{note_id,title,role}]}
//           GET /settings/{key} -> {vault_id,key,value} (key one path
//             segment)
//           GET /prompts/review -> {text}
//   writes: POST /smart-folders {name, parent_id?}
//           PATCH /smart-folders/{id} {name?, parent_id? | to_root: true,
//             pinned?}: to_root wins over parent_id; no to_root:false
//           DELETE /smart-folders/{id} (no body)
//           POST /smart-folders/{id}/members {note_id, pinned?}: pinned
//             null leaves the field out (the server pins)
//           PUT /settings/{key} {value}
//   A field is sent only when the CLI wrapper would pass its flag.
// Errors are MemexException.fromC1 with the CLI wrapper's operation label
// (folder new, folder update, folder rm, folder add, settings get,
// settings set, prompt review), C1 fields kept.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi83TopicsDir = '$apiV1FixturesDir/topics';
const _wi83Base = '/vaults/seed/api/v1';
const _wi83Design = '01M5DQAYZHJGKWXCJHR5FSDFA0';
const _wi83Systems = '01M5DQAYZHE33BZ4NA4H5YSBJD';
const _wi83Inbox = '01M5DQAYZHJTTW6PPF4P7GNCHN';
const _wi83PlayerLoop = '01M5DQAYZ3WP7H0NXZZV9M2315';
const _wi83Economy = '01M5DQAYZ47QW55S90ZF0A56AH';
const _wi83Pacing = '01M5DQAYZ4YAPYMEDWXP8WCNGJ';
const _wi83Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi83Broken = '01M5DQAYZ5RH88SRZGPY15XXVM';
const _wi83Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _wi83MaxDepth = 'smart_folder_max_depth';

class _Wi83Env {
  _Wi83Env(this.container, this.server, this.topics);

  final ProviderContainer container;
  final FakeVaultServer server;
  final HostedTopicsAccess topics;

  http.Request get last => server.requests.last;

  Object? get lastBody => jsonDecode(last.body);
}

_Wi83Env _env({bool rows = true, String vaultName = seedVaultName}) {
  final server = FakeVaultServer();
  if (rows) server.serveDomain('topics');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi83Env(
    container,
    server,
    HostedTopicsAccess(client: server.connect(container), vaultName: vaultName),
  );
}

/// The row of `topics/index.json` that answers [response].
FixtureRow _row(String response) =>
    loadFixtureRows(_wi83TopicsDir).firstWhere((r) => r.response == response);

Object? _requestJson(String response) =>
    jsonDecode(utf8.decode(_row(response).readRequestBytes()!));

Map<String, Object?> _c1(String response) =>
    (_row(response).readResponseJson()! as Map<String, Object?>)['error']!
        as Map<String, Object?>;

/// The C1 fields of a row: its error object without `code` and `message`.
Map<String, Object?> _c1Fields(String response) => {
  for (final e in _c1(response).entries)
    if (e.key != 'code' && e.key != 'message') e.key: e.value,
};

Future<Object?> _outcome(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// A `memex folder new|update` object as the CLI prints it.
Map<String, Object?> _folderJson({
  required String id,
  required String name,
  String? parentId,
  required bool pinned,
  required int depth,
}) => {
  'vault_id': seedVaultId(),
  'id': id,
  'name': name,
  'parent_id': parentId,
  'pinned': pinned,
  'depth': depth,
  'created_at': 1760000720000,
  'updated_at': 1792539488433,
};

void main() {
  group('reads', () {
    test(
      'hosted smartFolders sends GET smart-folders and decodes every folder and membership',
      () async {
        final env = _env();
        final data = await env.topics.smartFolders();
        expect(env.last.method, 'GET');
        expect(env.last.url.path, '$_wi83Base/smart-folders');
        expect(env.last.url.query, isEmpty);
        expect(env.last.headers['authorization'], 'Bearer $fakeServerToken');
        expect(vaultAccessShape(data.folders), [
          {
            'SmartFolderRow': [_wi83Systems, 'Systems', _wi83Design, false],
          },
          {
            'SmartFolderRow': [_wi83Design, 'Design', null, true],
          },
          {
            'SmartFolderRow': [_wi83Inbox, 'Inbox', null, false],
          },
        ]);
        expect(vaultAccessShape(data.members), [
          {
            'SmartFolderMemberRow': [
              _wi83Systems,
              _wi83Economy,
              'Economy Design',
              false,
            ],
          },
          {
            'SmartFolderMemberRow': [
              _wi83Systems,
              _wi83Pacing,
              'Pacing Notes',
              false,
            ],
          },
          {
            'SmartFolderMemberRow': [
              _wi83Design,
              _wi83PlayerLoop,
              'Player Loop',
              true,
            ],
          },
        ]);
      },
    );

    test(
      'hosted smartFolders ignores max_depth and unknown response keys',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'GET',
          '$_wi83Base/smart-folders',
          json: {
            'max_depth': 4,
            'future_field': true,
            'folders': [
              {
                'id': 'f1',
                'name': 'Root',
                'parent_id': null,
                'pinned': true,
                'colour': 'red',
              },
              {'id': 'f2', 'name': 'Child', 'parent_id': 'f1', 'pinned': false},
            ],
            'members': [
              {
                'folder_id': 'f2',
                'note_id': 'n1',
                'title': 'A Note',
                'pinned': true,
                'role': 'topic',
              },
            ],
          },
        );
        final data = await env.topics.smartFolders();
        expect(vaultAccessShape(data), {
          'SmartFolderData': [
            [
              {
                'SmartFolderRow': ['f1', 'Root', null, true],
              },
              {
                'SmartFolderRow': ['f2', 'Child', 'f1', false],
              },
            ],
            [
              {
                'SmartFolderMemberRow': ['f2', 'n1', 'A Note', true],
              },
            ],
          ],
        });
      },
    );

    test('hosted smartFolders decodes an empty vault', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi83Base/smart-folders',
        json: {'max_depth': 2, 'folders': [], 'members': []},
      );
      final data = await env.topics.smartFolders();
      expect(data.folders, isEmpty);
      expect(data.members, isEmpty);
    });

    test(
      'hosted unsortedNotes sends GET unsorted and decodes null roles',
      () async {
        final env = _env();
        final rows = await env.topics.unsortedNotes();
        expect(env.last.method, 'GET');
        expect(env.last.url.path, '$_wi83Base/unsorted');
        expect(env.last.url.query, isEmpty);
        expect(vaultAccessShape(rows), [
          {
            'UnsortedNoteRow': [_wi83Loose, 'Loose Thought', null],
          },
          {
            'UnsortedNoteRow': [_wi83Broken, 'Broken Frontmatter', null],
          },
        ]);
      },
    );

    test('hosted unsortedNotes keeps a topic role', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi83Base/unsorted',
        json: _row('unsorted_after_writes.json').readResponseJson(),
      );
      expect(vaultAccessShape(await env.topics.unsortedNotes()), [
        {
          'UnsortedNoteRow': [_wi83Economy, 'Economy Design', 'topic'],
        },
        {
          'UnsortedNoteRow': [_wi83Broken, 'Broken Frontmatter', null],
        },
      ]);
    });

    test(
      'hosted topics reads throw the C1 error of a failed response',
      () async {
        final env = _env(rows: false);
        for (final path in ['smart-folders', 'unsorted']) {
          env.server.route(
            'GET',
            '$_wi83Base/$path',
            status: 500,
            json: {
              'error': {'code': 'internal', 'message': 'disk on fire'},
            },
          );
        }
        for (final read in [
          env.topics.smartFolders,
          env.topics.unsortedNotes,
        ]) {
          final e = await _outcome(read());
          expect(e, isA<MemexException>());
          expect((e! as MemexException).code, 'internal');
        }
      },
    );
  });

  group('settings', () {
    test('hosted getSetting sends the key and returns the value', () async {
      final env = _env();
      expect(await env.topics.getSetting(_wi83MaxDepth), 2);
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi83Base/settings/$_wi83MaxDepth');
      expect(env.last.url.query, isEmpty);
    });

    test('hosted getSetting sends the key as one path segment', () async {
      final env = _env(rows: false);
      env.server.route(
        'GET',
        '$_wi83Base/settings/a%2Fb%20c',
        json: {'vault_id': seedVaultId(), 'key': 'a/b c', 'value': 1},
      );
      expect(await env.topics.getSetting('a/b c'), 1);
      expect(env.last.url.pathSegments.last, 'a/b c');
      expect(
        env.last.url.pathSegments.length,
        Uri.parse('$_wi83Base/settings/x').pathSegments.length,
      );
    });

    test(
      'hosted getSetting on an unknown key throws setting_invalid as settings get',
      () async {
        final env = _env();
        final e = await _outcome(env.topics.getSetting('unknown_key'));
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'setting_invalid');
        expect(
          e.message,
          'settings get failed: ${_c1('settings_get_unknown_key.json')['message']}',
        );
      },
    );

    test(
      'hosted setSetting puts the value and returns the stored value',
      () async {
        final env = _env();
        expect(await env.topics.setSetting(_wi83MaxDepth, 3), 3);
        expect(env.last.method, 'PUT');
        expect(env.last.url.path, '$_wi83Base/settings/$_wi83MaxDepth');
        expect(env.lastBody, _requestJson('settings_set.json'));
        expect(env.lastBody, {'value': 3});
        expect(await env.topics.setSetting(_wi83MaxDepth, 2), 2);
        expect(env.lastBody, _requestJson('settings_set_2.json'));
      },
    );

    test(
      'hosted setSetting out of range throws setting_invalid as settings set',
      () async {
        final env = _env();
        final e = await _outcome(env.topics.setSetting(_wi83MaxDepth, 6));
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'setting_invalid');
        expect(
          e.message,
          'settings set failed: ${_c1('settings_set_out_of_range.json')['message']}',
        );
        final e2 = await _outcome(env.topics.setSetting('unknown_key', 3));
        expect((e2! as MemexException).code, 'setting_invalid');
      },
    );

    test(
      'hosted setSetting with a non-integer value in the reply throws',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'PUT',
          '$_wi83Base/settings/$_wi83MaxDepth',
          json: {'vault_id': seedVaultId(), 'key': _wi83MaxDepth, 'value': '3'},
        );
        expect(
          await _outcome(env.topics.setSetting(_wi83MaxDepth, 3)),
          isA<MemexException>(),
        );
      },
    );
  });

  group('reviewPrompt', () {
    test('hosted reviewPrompt returns the text unchanged', () async {
      final env = _env();
      final text = await env.topics.reviewPrompt();
      expect(env.last.method, 'GET');
      expect(env.last.url.path, '$_wi83Base/prompts/review');
      final want =
          (_row('prompt_review.json').readResponseJson()! as Map)['text']
              as String;
      expect(text, want);
      expect(text, startsWith('# Review daily notes\n'));
      expect(text.endsWith('\n') && !text.endsWith('\n\n'), isTrue);
    });
  });

  group('createFolder', () {
    test('hosted createFolder posts the name and parses the folder', () async {
      final env = _env(rows: false);
      env.server.route(
        'POST',
        '$_wi83Base/smart-folders',
        status: 201,
        json: {
          ..._folderJson(
            id: '01M5DTVW3W6AMFEGYRFVZKVP2A',
            name: 'Mechanics',
            pinned: true,
            depth: 1,
          ),
          'created_at': 1792539488379,
          'updated_at': 1792539488380,
        },
      );
      final r = await env.topics.createFolder(name: 'Mechanics');
      expect(env.last.method, 'POST');
      expect(env.last.url.path, '$_wi83Base/smart-folders');
      expect(env.lastBody, _requestJson('folder_new.json'));
      expect((env.lastBody! as Map).containsKey('parent_id'), isFalse);
      expect(vaultAccessShape(r), {
        'SmartFolderResult': [
          seedVaultId(),
          '01M5DTVW3W6AMFEGYRFVZKVP2A',
          'Mechanics',
          null,
          true,
          1,
          1792539488379,
          1792539488380,
        ],
      });
    });

    test('hosted createFolder sends parent_id when given', () async {
      final env = _env(rows: false);
      env.server.route(
        'POST',
        '$_wi83Base/smart-folders',
        status: 201,
        json: _folderJson(
          id: '01M5DTVW49QVNVE5BX1YBTSV8B',
          name: 'Combat',
          parentId: _wi83Design,
          pinned: true,
          depth: 2,
        ),
      );
      final r = await env.topics.createFolder(
        name: 'Combat',
        parentId: _wi83Design,
      );
      expect(env.lastBody, _requestJson('folder_new_child.json'));
      expect([r.parentId, r.depth, r.pinned], [_wi83Design, 2, true]);
    });

    test(
      'hosted createFolder past max_depth throws depth_exceeded with max_depth and required_depth',
      () async {
        final env = _env();
        final e = await _outcome(
          env.topics.createFolder(name: 'Too Deep', parentId: _wi83Systems),
        );
        expect(env.lastBody, _requestJson('folder_new_depth_exceeded.json'));
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'depth_exceeded');
        expect(e.fields, {'max_depth': 2, 'required_depth': 3});
        expect(e.fields['required_depth'], isA<int>());
        expect(
          e.message,
          'folder new failed: ${_c1('folder_new_depth_exceeded.json')['message']}',
        );
        expect(e.kind, MemexErrorKind.other);
      },
    );

    test(
      'a hosted createFolder failure reads exactly like the CLI failure on the same body',
      () async {
        for (final (call, response) in [
          (
            (_Wi83Env env) => env.topics.createFolder(
              name: 'Too Deep',
              parentId: _wi83Systems,
            ),
            'folder_new_depth_exceeded.json',
          ),
          (
            (_Wi83Env env) => env.topics.createFolder(name: 'design'),
            'folder_new_name_conflict.json',
          ),
          (
            (_Wi83Env env) =>
                env.topics.createFolder(name: 'Orphan', parentId: _wi83Unknown),
            'folder_new_parent_not_found.json',
          ),
        ]) {
          final env = _env();
          final e = await _outcome(call(env));
          final body = _row(response).readResponseJson();
          final cli = MemexException.fromCliFailure(
            'folder new',
            MemexResult(
              exitCode: 1,
              stdout: '',
              stderr: '${jsonEncode(body)}\n',
            ),
          );
          expect(e, isA<MemexException>(), reason: response);
          e as MemexException;
          expect(e.message, cli.message, reason: response);
          expect(e.code, cli.code, reason: response);
          expect(e.fields, cli.fields, reason: response);
          expect(e.kind, cli.kind, reason: response);
        }
      },
    );
  });

  group('updateFolder', () {
    test('hosted updateFolder sends only the fields given', () async {
      final env = _env(rows: false);
      env.server.route(
        'PATCH',
        '$_wi83Base/smart-folders/$_wi83Inbox',
        json: _folderJson(
          id: _wi83Inbox,
          name: 'Later',
          pinned: true,
          depth: 1,
        ),
      );
      await env.topics.updateFolder(id: _wi83Inbox, name: 'Later');
      expect(env.last.method, 'PATCH');
      expect(env.last.url.path, '$_wi83Base/smart-folders/$_wi83Inbox');
      expect(env.lastBody, _requestJson('folder_update_rename.json'));

      await env.topics.updateFolder(id: _wi83Inbox, pinned: false);
      expect(env.lastBody, _requestJson('folder_update_unpin.json'));

      await env.topics.updateFolder(id: _wi83Inbox, pinned: true);
      expect(env.lastBody, _requestJson('folder_update_pin.json'));

      await env.topics.updateFolder(id: _wi83Inbox, parentId: _wi83Design);
      expect(env.lastBody, _requestJson('folder_update_move.json'));

      await env.topics.updateFolder(id: _wi83Inbox, toRoot: true);
      expect(env.lastBody, _requestJson('folder_update_to_root.json'));

      await env.topics.updateFolder(
        id: _wi83Inbox,
        name: 'Later',
        parentId: _wi83Design,
        pinned: false,
      );
      expect(env.lastBody, {
        'name': 'Later',
        'parent_id': _wi83Design,
        'pinned': false,
      });

      await env.topics.updateFolder(id: _wi83Inbox);
      expect(env.lastBody, <String, Object?>{});
    });

    test(
      'hosted updateFolder with toRoot and parentId sends only to_root',
      () async {
        final env = _env(rows: false);
        env.server.route(
          'PATCH',
          '$_wi83Base/smart-folders/$_wi83Inbox',
          json: _folderJson(
            id: _wi83Inbox,
            name: 'Later',
            pinned: true,
            depth: 1,
          ),
        );
        await env.topics.updateFolder(
          id: _wi83Inbox,
          toRoot: true,
          parentId: _wi83Design,
        );
        expect(env.lastBody, {'to_root': true});
        await env.topics.updateFolder(
          id: _wi83Inbox,
          toRoot: true,
          parentId: _wi83Design,
          pinned: true,
        );
        expect(env.lastBody, {'to_root': true, 'pinned': true});
      },
    );

    test('hosted updateFolder parses the folder update object', () async {
      final env = _env(rows: false);
      env.server.route(
        'PATCH',
        '$_wi83Base/smart-folders/$_wi83Inbox',
        json: _folderJson(
          id: _wi83Inbox,
          name: 'Later',
          parentId: _wi83Design,
          pinned: false,
          depth: 2,
        ),
      );
      final r = await env.topics.updateFolder(
        id: _wi83Inbox,
        parentId: _wi83Design,
      );
      expect(vaultAccessShape(r), {
        'SmartFolderResult': [
          seedVaultId(),
          _wi83Inbox,
          'Later',
          _wi83Design,
          false,
          2,
          1760000720000,
          1792539488433,
        ],
      });
    });

    test(
      'hosted updateFolder errors carry the CLI codes and fields as folder update',
      () async {
        final env = _env();
        for (final (call, response, code) in [
          (
            () => env.topics.updateFolder(
              id: _wi83Design,
              parentId: _wi83Systems,
            ),
            'folder_update_cycle.json',
            'folder_cycle',
          ),
          (
            () =>
                env.topics.updateFolder(id: _wi83Design, parentId: _wi83Inbox),
            'folder_update_depth_exceeded.json',
            'depth_exceeded',
          ),
          (
            () => env.topics.updateFolder(id: _wi83Inbox, name: 'Design'),
            'folder_update_name_conflict.json',
            'name_conflict',
          ),
          (
            () => env.topics.updateFolder(id: _wi83Unknown, name: 'Nowhere'),
            'folder_update_not_found.json',
            'not_found',
          ),
        ]) {
          final e = await _outcome(call());
          expect(env.lastBody, _requestJson(response), reason: response);
          expect(e, isA<MemexException>(), reason: response);
          e as MemexException;
          expect(e.code, code, reason: response);
          expect(e.fields, _c1Fields(response), reason: response);
          expect(
            e.message,
            'folder update failed: ${_c1(response)['message']}',
            reason: response,
          );
        }
      },
    );
  });

  group('deleteFolder', () {
    test(
      'hosted deleteFolder sends DELETE and parses the result then not_found',
      () async {
        final env = _env();
        final r = await env.topics.deleteFolder(id: _wi83Systems);
        expect(env.last.method, 'DELETE');
        expect(env.last.url.path, '$_wi83Base/smart-folders/$_wi83Systems');
        expect(env.last.url.query, isEmpty);
        expect(env.last.bodyBytes, isEmpty, reason: 'no body');
        expect(vaultAccessShape(r), {
          'FolderDeleteResult': [seedVaultId(), _wi83Systems, true],
        });

        final e = await _outcome(env.topics.deleteFolder(id: _wi83Systems));
        expect(e, isA<MemexException>());
        e as MemexException;
        expect(e.code, 'not_found');
        expect(
          e.message,
          'folder rm failed: ${_c1('folder_rm_not_found.json')['message']}',
        );
      },
    );
  });

  group('addToFolder', () {
    test(
      'hosted addToFolder without pinned leaves pinned out and parses the membership',
      () async {
        final env = _env();
        final r = await env.topics.addToFolder(
          folderId: _wi83Inbox,
          noteId: _wi83Loose,
        );
        expect(env.last.method, 'POST');
        expect(
          env.last.url.path,
          '$_wi83Base/smart-folders/$_wi83Inbox/members',
        );
        expect(env.lastBody, _requestJson('folder_add.json'));
        expect(env.lastBody, {'note_id': _wi83Loose});
        expect(vaultAccessShape(r), {
          'FolderMembershipResult': [
            seedVaultId(),
            _wi83Inbox,
            _wi83Loose,
            true,
            true,
          ],
        });
      },
    );

    test('hosted addToFolder sends pinned when given', () async {
      final env = _env();
      final r = await env.topics.addToFolder(
        folderId: _wi83Inbox,
        noteId: _wi83Pacing,
        pinned: false,
      );
      expect(env.lastBody, _requestJson('folder_add_unpinned.json'));
      expect([r.pinned, r.roleSet], [false, false]);

      final env2 = _env(rows: false);
      env2.server.route(
        'POST',
        '$_wi83Base/smart-folders/$_wi83Inbox/members',
        json: _row('folder_add.json').readResponseJson(),
      );
      await env2.topics.addToFolder(
        folderId: _wi83Inbox,
        noteId: _wi83Loose,
        pinned: true,
      );
      expect(env2.lastBody, {'note_id': _wi83Loose, 'pinned': true});
    });

    test(
      'hosted addToFolder of an unknown note or folder throws not_found as folder add',
      () async {
        final env = _env();
        for (final (call, response) in [
          (
            () => env.topics.addToFolder(
              folderId: _wi83Inbox,
              noteId: _wi83Unknown,
            ),
            'folder_add_note_not_found.json',
          ),
          (
            () => env.topics.addToFolder(
              folderId: _wi83Unknown,
              noteId: _wi83Broken,
            ),
            'folder_add_folder_not_found.json',
          ),
        ]) {
          final e = await _outcome(call());
          expect(e, isA<MemexException>(), reason: response);
          e as MemexException;
          expect(e.code, 'not_found', reason: response);
          expect(
            e.message,
            'folder add failed: ${_c1(response)['message']}',
            reason: response,
          );
        }
      },
    );
  });

  test(
    'every hosted topics call labels its errors with the CLI operation',
    () async {
      final env = _env(rows: false);
      const fire = {
        'error': {'code': 'internal', 'message': 'disk on fire'},
      };
      for (final (method, path) in [
        ('POST', '/smart-folders'),
        ('PATCH', '/smart-folders/$_wi83Inbox'),
        ('DELETE', '/smart-folders/$_wi83Inbox'),
        ('POST', '/smart-folders/$_wi83Inbox/members'),
        ('GET', '/settings/$_wi83MaxDepth'),
        ('PUT', '/settings/$_wi83MaxDepth'),
        ('GET', '/prompts/review'),
      ]) {
        env.server.route(method, '$_wi83Base$path', status: 500, json: fire);
      }
      for (final (label, call) in <(String, Future<Object?> Function())>[
        ('folder new', () => env.topics.createFolder(name: 'Mechanics')),
        ('folder update', () => env.topics.updateFolder(id: _wi83Inbox)),
        ('folder rm', () => env.topics.deleteFolder(id: _wi83Inbox)),
        (
          'folder add',
          () =>
              env.topics.addToFolder(folderId: _wi83Inbox, noteId: _wi83Loose),
        ),
        ('settings get', () => env.topics.getSetting(_wi83MaxDepth)),
        ('settings set', () => env.topics.setSetting(_wi83MaxDepth, 3)),
        ('prompt review', env.topics.reviewPrompt),
      ]) {
        final e = await _outcome(call());
        expect(e, isA<MemexException>(), reason: label);
        e as MemexException;
        expect(e.message, '$label failed: disk on fire', reason: label);
        expect(e.code, 'internal', reason: label);
      }
    },
  );

  test('hosted topics calls go under the given vault name', () async {
    final env = _env(rows: false, vaultName: 'work');
    env.server.route(
      'GET',
      '/vaults/work/api/v1/settings/$_wi83MaxDepth',
      json: {'vault_id': seedVaultId(), 'key': _wi83MaxDepth, 'value': 4},
    );
    env.server.route(
      'GET',
      '/vaults/work/api/v1/unsorted',
      json: {'notes': []},
    );
    expect(await env.topics.getSetting(_wi83MaxDepth), 4);
    expect(await env.topics.unsortedNotes(), isEmpty);
    for (final r in env.server.requests) {
      expect(r.url.pathSegments.take(4), ['vaults', 'work', 'api', 'v1']);
      expect(r.headers['authorization'], 'Bearer $fakeServerToken');
    }
  });

  test(
    'hosted topics writes leave the vault revision to the call sites',
    () async {
      final env = _env();
      final before = env.container.read(vaultRevisionProvider);
      await env.topics.setSetting(_wi83MaxDepth, 3);
      await env.topics.addToFolder(folderId: _wi83Inbox, noteId: _wi83Loose);
      await env.topics.deleteFolder(id: _wi83Systems);
      expect(env.container.read(vaultRevisionProvider), before);
    },
  );
}
