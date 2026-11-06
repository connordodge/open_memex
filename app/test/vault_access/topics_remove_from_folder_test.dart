// WI #259 (F7) AC7: TopicsAccess.removeFromFolder on local and hosted vaults.
// Local wraps `memex folder remove` (FolderCli.removeFromFolder, C2.10);
// hosted is `DELETE /smart-folders/{folder_id}/members/{note_id}` and
// returns the same object as the CLI.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';
import 'package:open_memex_app/src/vault_access/local/topics.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/vault_access_shapes.dart';

const _vault = '/tmp/om-259-vault';
const _base = '/vaults/seed/api/v1';

const _removed = {
  'vault_id': 'V1',
  'smart_folder_id': 'FOLDER1',
  'note_id': 'NOTE1',
  'removed': true,
};

const _removedShape = {
  'FolderMemberRemoveResult': ['V1', 'FOLDER1', 'NOTE1', true],
};

HostedTopicsAccess _hosted(FakeVaultServer server) {
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  return HostedTopicsAccess(
    client: server.connect(container),
    vaultName: 'seed',
  );
}

void main() {
  group('local', () {
    test(
      'local removeFromFolder runs folder remove with the vault, folder id and note id',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'folder remove',
            (_) => FakeMemexCli.ok('${jsonEncode(_removed)}\n'),
          );
        final topics = LocalTopicsAccess(vaultPath: _vault, cli: cli);

        final r = await topics.removeFromFolder(
          folderId: 'FOLDER1',
          noteId: 'NOTE1',
        );

        expect(cli.calls.single.args, [
          'folder',
          'remove',
          '--vault',
          _vault,
          '--id',
          'FOLDER1',
          '--note-id',
          'NOTE1',
        ]);
        expect(vaultAccessShape(r), _removedShape);
      },
    );

    test(
      'local removeFromFolder reads the result from stdout, not constants',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'folder remove',
            (_) => FakeMemexCli.ok(
              '${jsonEncode({..._removed, 'removed': false, 'note_id': 'OTHER'})}\n',
            ),
          );
        final topics = LocalTopicsAccess(vaultPath: _vault, cli: cli);

        final r = await topics.removeFromFolder(
          folderId: 'FOLDER1',
          noteId: 'OTHER',
        );

        expect(vaultAccessShape(r), {
          'FolderMemberRemoveResult': ['V1', 'FOLDER1', 'OTHER', false],
        });
      },
    );

    test('local removeFromFolder throws StateError with no CLI', () async {
      final topics = LocalTopicsAccess(vaultPath: _vault);

      await expectLater(
        () => topics.removeFromFolder(folderId: 'F', noteId: 'N'),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'local removeFromFolder throws the MemexException with its C1 code',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'folder remove',
            (_) => FakeMemexCli.error('not_found', 'no member'),
          );
        final topics = LocalTopicsAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          topics.removeFromFolder(folderId: 'F', noteId: 'N'),
          throwsA(
            isA<MemexException>().having((e) => e.code, 'code', 'not_found'),
          ),
        );
      },
    );
  });

  group('hosted', () {
    test(
      'hosted removeFromFolder sends DELETE smart-folders folder members note with no body and decodes the result',
      () async {
        final server = FakeVaultServer()
          ..route(
            'DELETE',
            '$_base/smart-folders/FOLDER1/members/NOTE1',
            json: _removed,
          );

        final r = await _hosted(
          server,
        ).removeFromFolder(folderId: 'FOLDER1', noteId: 'NOTE1');

        final req = server.requests.single;
        expect(req.method, 'DELETE');
        expect(req.url.path, '$_base/smart-folders/FOLDER1/members/NOTE1');
        expect(req.url.query, isEmpty);
        expect(req.body, isEmpty);
        expect(req.headers['authorization'], 'Bearer $fakeServerToken');
        expect(vaultAccessShape(r), _removedShape);
      },
    );

    test(
      'hosted removeFromFolder sends both ids as one encoded segment each',
      () async {
        final server = FakeVaultServer()
          ..route(
            'DELETE',
            '$_base/smart-folders/a%2Fb/members/c%20d',
            json: _removed,
          );

        await _hosted(server).removeFromFolder(folderId: 'a/b', noteId: 'c d');

        expect(server.requests.single.url.pathSegments.sublist(4), [
          'smart-folders',
          'a/b',
          'members',
          'c d',
        ]);
      },
    );

    test(
      'hosted removeFromFolder throws the C1 error labelled folder remove',
      () async {
        final server = FakeVaultServer()
          ..route(
            'DELETE',
            '$_base/smart-folders/F/members/N',
            status: 404,
            json: {
              'error': {'code': 'not_found', 'message': 'no member'},
            },
          );

        await expectLater(
          _hosted(server).removeFromFolder(folderId: 'F', noteId: 'N'),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', 'not_found')
                .having(
                  (e) => e.message,
                  'message',
                  startsWith('folder remove failed'),
                ),
          ),
        );
      },
    );

    test(
      'hosted removeFromFolder throws with a null code for a response that is not the Contract shape',
      () async {
        for (final bad in <Map<String, Object?>>[
          {},
          {'vault_id': 'V1', 'smart_folder_id': 'F', 'note_id': 'N'},
          {'vault_id': 'V1', 'smart_folder_id': 'F', 'removed': true},
          {..._removed, 'removed': 'yes'},
        ]) {
          final server = FakeVaultServer()
            ..route('DELETE', '$_base/smart-folders/F/members/N', json: bad);

          await expectLater(
            _hosted(server).removeFromFolder(folderId: 'F', noteId: 'N'),
            throwsA(
              isA<MemexException>().having((e) => e.code, 'code', isNull),
            ),
            reason: '$bad',
          );
        }
      },
    );
  });
}
