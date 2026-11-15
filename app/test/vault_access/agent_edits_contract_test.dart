// WI #13 (Spec #7 A1): the frozen D14 wire contracts as a Dart in-test table
// (no fixture files; R4 #12 builds the CLI and API to the same JSON in
// parallel). Each sample is decoded twice, once as `memex` stdout through
// `AgentEditsCli` and once as the vault server's body through
// `HostedNotesAccess`, and both must give the same values. Fields a later
// server adds are ignored.
//
//   read-only set|clear, PUT …/agent-read-only  -> {vault_id, note_id, agent_read_only}
//   revisions list, GET …/revisions             -> {vault_id, revisions: [{id, agent_change_id|null, created_at}]}
//   revisions restore, POST …/restore           -> {vault_id, note_id, version, content_md}
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/note_edits_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/notes.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';

const _wi13Vault = 'seed';
const _wi13Base = '/vaults/seed/api/v1';
const _wi13Note = '01JCONTRACTAGENTEDITS00013';
const _wi13VaultId = '01HV0000000000000000000013';

HostedNotesAccess _wi13Hosted(FakeVaultServer server) {
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return HostedNotesAccess(
    client: server.connect(container),
    vaultName: _wi13Vault,
  );
}

/// One D14 sample: [json] is what both the CLI prints and the server
/// answers; [viaCli] and [viaHosted] decode it; [shape] reduces a result to
/// comparable values.
typedef _Wi13Row = ({
  String name,
  String method,
  String path,
  String subcommand,
  Map<String, Object?> json,
  Future<Object> Function(FakeMemexCli cli) viaCli,
  Future<Object> Function(HostedNotesAccess hosted) viaHosted,
  Object? Function(Object result) shape,
  Object? expected,
});

Object? _wi13ReadOnlyShape(Object r) {
  r as AgentReadOnlyResult;
  return [r.vaultId, r.noteId, r.agentReadOnly];
}

Object? _wi13RestoreShape(Object r) {
  r as NoteRevisionRestoreResult;
  return [r.vaultId, r.noteId, r.version, r.contentMd];
}

Object? _wi13RevisionsShape(Object r) => [
  for (final x in r as List) [x.id, x.agentChangeId, x.createdAt],
];

final _wi13Table = <_Wi13Row>[
  (
    name: 'read-only set',
    method: 'PUT',
    path: '$_wi13Base/notes/$_wi13Note/agent-read-only',
    subcommand: 'read-only set',
    json: {
      'vault_id': _wi13VaultId,
      'note_id': _wi13Note,
      'agent_read_only': true,
    },
    viaCli: (cli) => cli.setAgentReadOnly(
      vaultPath: '/vaults/My Vault',
      noteId: _wi13Note,
      on: true,
    ),
    viaHosted: (h) => h.setAgentReadOnly(_wi13Note, true),
    shape: _wi13ReadOnlyShape,
    expected: [_wi13VaultId, _wi13Note, true],
  ),
  (
    name: 'read-only clear',
    method: 'PUT',
    path: '$_wi13Base/notes/$_wi13Note/agent-read-only',
    subcommand: 'read-only clear',
    json: {
      'vault_id': _wi13VaultId,
      'note_id': _wi13Note,
      'agent_read_only': false,
    },
    viaCli: (cli) => cli.setAgentReadOnly(
      vaultPath: '/vaults/My Vault',
      noteId: _wi13Note,
      on: false,
    ),
    viaHosted: (h) => h.setAgentReadOnly(_wi13Note, false),
    shape: _wi13ReadOnlyShape,
    expected: [_wi13VaultId, _wi13Note, false],
  ),
  (
    name: 'revisions list',
    method: 'GET',
    path: '$_wi13Base/notes/$_wi13Note/revisions',
    subcommand: 'revisions list',
    json: {
      'vault_id': _wi13VaultId,
      'revisions': [
        {
          'id': 'rev-2',
          'agent_change_id': 'chg-2',
          'created_at': 1759500200000,
          'later_field': 'ignored',
        },
        {'id': 'rev-1', 'agent_change_id': null, 'created_at': 1759500100000},
      ],
    },
    viaCli: (cli) =>
        cli.noteRevisions(vaultPath: '/vaults/My Vault', noteId: _wi13Note),
    viaHosted: (h) => h.noteRevisions(_wi13Note),
    shape: _wi13RevisionsShape,
    expected: [
      ['rev-2', 'chg-2', 1759500200000],
      ['rev-1', null, 1759500100000],
    ],
  ),
  (
    name: 'revisions list empty',
    method: 'GET',
    path: '$_wi13Base/notes/$_wi13Note/revisions',
    subcommand: 'revisions list',
    json: {'vault_id': _wi13VaultId, 'revisions': <Object?>[]},
    viaCli: (cli) =>
        cli.noteRevisions(vaultPath: '/vaults/My Vault', noteId: _wi13Note),
    viaHosted: (h) => h.noteRevisions(_wi13Note),
    shape: _wi13RevisionsShape,
    expected: <Object?>[],
  ),
  (
    name: 'revisions restore',
    method: 'POST',
    path: '$_wi13Base/notes/$_wi13Note/revisions/rev-2/restore',
    subcommand: 'revisions restore',
    json: {
      'vault_id': _wi13VaultId,
      'note_id': _wi13Note,
      'version': 7,
      'content_md': '- Pricing\n',
      'later_field': 1,
    },
    viaCli: (cli) => cli.restoreNoteRevision(
      vaultPath: '/vaults/My Vault',
      revisionId: 'rev-2',
    ),
    viaHosted: (h) =>
        h.restoreNoteRevision(noteId: _wi13Note, revisionId: 'rev-2'),
    shape: _wi13RestoreShape,
    expected: [_wi13VaultId, _wi13Note, 7, '- Pricing\n'],
  ),
];

void main() {
  test(
    'the CLI and the hosted route decode every frozen D14 sample to the same values',
    () async {
      for (final row in _wi13Table) {
        final cli = FakeMemexCli()
          ..on(row.subcommand, (_) => FakeMemexCli.ok(jsonEncode(row.json)));
        final viaCli = row.shape(await row.viaCli(cli));
        expect(cli.calls, hasLength(1), reason: row.name);

        final server = FakeVaultServer()
          ..route(row.method, row.path, json: row.json);
        final viaHosted = row.shape(await row.viaHosted(_wi13Hosted(server)));
        expect(server.requests, hasLength(1), reason: row.name);

        expect(viaCli, row.expected, reason: '${row.name}: CLI');
        expect(viaHosted, row.expected, reason: '${row.name}: hosted');
      }
    },
  );
}
