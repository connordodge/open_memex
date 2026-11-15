// WI #13 (Spec #7 A1, D14, D16): `HostedNotesAccess`'s agent-edit seam over
// `fake_vault_server.dart` (a MockClient, no network). Routes under
// `/vaults/<vault>/api/v1`:
//   GET  /notes/{note_id}                    gains `agent_read_only` (missing
//                                            on a v0.3.x server: false)
//   GET  /notes/{note_id}/revisions          {vault_id, revisions: [...]}
//   PUT  /notes/{note_id}/agent-read-only    {agent_read_only: bool}
//   POST /notes/{note_id}/revisions/{revision_id}/restore   (no body)
// One request per call. A server error is a `MemexException` (C1 code and
// message, labelled like the CLI wrapper: `read-only set`, `read-only
// clear`, `revisions list`, `revisions restore`).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/notes.dart';

import '../support/fake_clock.dart';
import '../support/fake_vault_server.dart';

const _wi13Vault = 'My Vault';
const _wi13Base = '/vaults/My%20Vault/api/v1';
const _wi13Note = '01JHOSTEDAGENTEDITS0000013';
const _wi13VaultId = '01HV0000000000000000000013';

class _Wi13Env {
  _Wi13Env(this.server, this.notes);
  final FakeVaultServer server;
  final HostedNotesAccess notes;
}

_Wi13Env _wi13Hosted() {
  final server = FakeVaultServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return _Wi13Env(
    server,
    HostedNotesAccess(client: server.connect(container), vaultName: _wi13Vault),
  );
}

/// The `memex get` object of [_wi13Note], with [extra] merged in.
Map<String, Object?> _wi13GetObject([Map<String, Object?> extra = const {}]) =>
    {
      'vault_id': _wi13VaultId,
      'note_id': _wi13Note,
      'title': 'Pricing notes',
      'content_md': 'Pricing.',
      'frontmatter': <String, Object?>{},
      'version': 4,
      'created_at': 1759500000000,
      'updated_at': 1759500100000,
      'tags': <String>[],
      'footer_tags': <String>[],
      ...extra,
    };

/// [future]'s value or the error it threw.
Future<Object?> _wi13Outcome(Future<Object?> future) async {
  try {
    return await future;
  } catch (e) {
    return e;
  }
}

void main() {
  test(
    'hosted note read decodes agent_read_only and a missing field as false',
    () async {
      final env = _wi13Hosted();
      for (final flag in [true, false]) {
        env.server.route(
          'GET',
          '$_wi13Base/notes/$_wi13Note',
          json: _wi13GetObject({'agent_read_only': flag}),
        );
        final note = await env.notes.getNote(_wi13Note);
        expect(note!.agentReadOnly, flag, reason: 'agent_read_only: $flag');
        expect(note.version, 4);
      }
      // A v0.3.x server sends no `agent_read_only`.
      env.server.route(
        'GET',
        '$_wi13Base/notes/$_wi13Note',
        json: _wi13GetObject(),
      );
      expect((await env.notes.getNote(_wi13Note))!.agentReadOnly, isFalse);
    },
  );

  test(
    'hosted noteRevisions reads GET notes revisions in the order the server lists them',
    () async {
      final env = _wi13Hosted();
      env.server.route(
        'GET',
        '$_wi13Base/notes/$_wi13Note/revisions',
        json: {
          'vault_id': _wi13VaultId,
          'revisions': [
            {
              'id': 'rev-3',
              'agent_change_id': null,
              'created_at': 1759500300000,
            },
            {
              'id': 'rev-2',
              'agent_change_id': 'chg-2',
              'created_at': 1759500200000,
            },
          ],
        },
      );
      final rows = await env.notes.noteRevisions(_wi13Note);
      expect(env.server.requests, hasLength(1));
      final req = env.server.requests.single;
      expect(req.method, 'GET');
      expect(req.url.path, '$_wi13Base/notes/$_wi13Note/revisions');
      expect([for (final r in rows) r.id], ['rev-3', 'rev-2']);
      expect([for (final r in rows) r.agentChangeId], [null, 'chg-2']);
      expect(
        [for (final r in rows) r.createdAt],
        [1759500300000, 1759500200000],
      );
    },
  );

  test(
    'hosted setAgentReadOnly sends one PUT agent-read-only with the flag',
    () async {
      final env = _wi13Hosted();
      for (final on in [true, false]) {
        env.server.route(
          'PUT',
          '$_wi13Base/notes/$_wi13Note/agent-read-only',
          json: {
            'vault_id': _wi13VaultId,
            'note_id': _wi13Note,
            'agent_read_only': on,
          },
        );
        final before = env.server.requests.length;
        final out = await env.notes.setAgentReadOnly(_wi13Note, on);
        expect(env.server.requests.length - before, 1, reason: 'on: $on');
        final req = env.server.requests.last;
        expect(req.method, 'PUT');
        expect(req.url.path, '$_wi13Base/notes/$_wi13Note/agent-read-only');
        expect(jsonDecode(req.body), {'agent_read_only': on});
        expect(out.vaultId, _wi13VaultId);
        expect(out.noteId, _wi13Note);
        expect(out.agentReadOnly, on);
      }
    },
  );

  test(
    'hosted restoreNoteRevision sends one POST to the revision restore route with no body',
    () async {
      final env = _wi13Hosted();
      env.server.route(
        'POST',
        '$_wi13Base/notes/$_wi13Note/revisions/rev-2/restore',
        json: {
          'vault_id': _wi13VaultId,
          'note_id': _wi13Note,
          'version': 6,
          'content_md': 'Pricing, before the agent.',
        },
      );
      final out = await env.notes.restoreNoteRevision(
        noteId: _wi13Note,
        revisionId: 'rev-2',
      );
      expect(env.server.requests, hasLength(1));
      final req = env.server.requests.single;
      expect(req.method, 'POST');
      expect(
        req.url.path,
        '$_wi13Base/notes/$_wi13Note/revisions/rev-2/restore',
      );
      expect(req.body, isEmpty);
      expect(out.vaultId, _wi13VaultId);
      expect(out.noteId, _wi13Note);
      expect(out.version, 6);
      expect(out.contentMd, 'Pricing, before the agent.');
    },
  );

  test(
    'hosted agent edit calls surface server errors as MemexException with code and message',
    () async {
      final cases =
          <
            ({
              String method,
              String path,
              int status,
              String code,
              String operation,
              Future<Object?> Function(HostedNotesAccess n) call,
            })
          >[
            (
              method: 'PUT',
              path: '$_wi13Base/notes/$_wi13Note/agent-read-only',
              status: 422,
              code: 'role_rule',
              operation: 'read-only set',
              call: (n) => n.setAgentReadOnly(_wi13Note, true),
            ),
            (
              method: 'PUT',
              path: '$_wi13Base/notes/$_wi13Note/agent-read-only',
              status: 404,
              code: 'not_found',
              operation: 'read-only clear',
              call: (n) => n.setAgentReadOnly(_wi13Note, false),
            ),
            (
              method: 'GET',
              path: '$_wi13Base/notes/$_wi13Note/revisions',
              status: 404,
              code: 'not_found',
              operation: 'revisions list',
              call: (n) => n.noteRevisions(_wi13Note),
            ),
            (
              method: 'POST',
              path: '$_wi13Base/notes/$_wi13Note/revisions/gone/restore',
              status: 404,
              code: 'not_found',
              operation: 'revisions restore',
              call: (n) =>
                  n.restoreNoteRevision(noteId: _wi13Note, revisionId: 'gone'),
            ),
          ];
      for (final c in cases) {
        final env = _wi13Hosted();
        env.server.route(
          c.method,
          c.path,
          status: c.status,
          json: {
            'error': {'code': c.code, 'message': 'refused by the server'},
          },
        );
        final e = await _wi13Outcome(c.call(env.notes));
        expect(e, isA<MemexException>(), reason: c.operation);
        e as MemexException;
        expect(e.code, c.code, reason: c.operation);
        expect(e.message, '${c.operation} failed: refused by the server');
        expect(env.server.requests, hasLength(1), reason: c.operation);
      }
    },
  );
}
