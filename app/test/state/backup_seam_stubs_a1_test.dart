// WI #321 (A0, D19): the stubs A1 (#322) fills. A1 replaces each stub and
// deletes this whole file (a TEST-CHANGE in its PR): the neutral-value tests
// here are the stubs' contract only. One file per filler, so no two fillers
// edit the same file or its imports.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/cli/backup_cli.dart';
import 'package:open_memex_app/src/state/backup_messages.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_names.dart';
import 'package:open_memex_app/src/state/backup_state_reader.dart';
import 'package:open_memex_app/src/vault_access/hosted/backup.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';

void main() {
  group('stubs filled by A1 (#322)', () {
    test('CliBackupRunner stub has no result to give until A1 fills it', () {
      const runner = CliBackupRunner(null);
      expect(
        () => runner.backup(
          vaultPath: '/v',
          destination: '/d',
          keep: 30,
          ifChanged: true,
        ),
        throwsA(isA<UnimplementedError>()),
      );
      expect(
        () => runner.restore(from: '/f.memex.zip', to: '/t'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('backupRunnerProvider declares a CliBackupRunner stub', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(backupRunnerProvider), isA<CliBackupRunner>());
    });

    test('FileBackupStateReader stub reads null', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final reader = container.read(backupStateReaderProvider);
      expect(reader, isA<FileBackupStateReader>());
      expect(await reader.read(vaultPath: '/v', destination: '/d'), isNull);
    });

    test('backup messages stubs return their neutral values', () {
      final at = DateTime.utc(2026, 11, 9, 9);
      expect(
        backupFailureMessage(
          code: 'backup_failed',
          message: 'm',
          automatic: true,
          failedAt: at,
          now: at,
        ),
        const BackupMessage(title: '', detail: '', short: ''),
      );
      expect(
        backupTooOldMessage(),
        const BackupMessage(title: '', detail: '', short: ''),
      );
      expect(
        backupBinaryNotFoundMessage(),
        const BackupMessage(title: '', detail: '', short: ''),
      );
      expect(
        restoreFailureMessage(
          RestoreFailure(code: 'backup_invalid', message: 'm'),
          name: 'Notes',
          parent: '/p',
        ),
        '',
      );
      expect(backupWhen(at, at), '');
      expect(backupSize(1), '');
    });

    test('backup names stubs return their neutral values', () {
      expect(
        parseBackupFileName(
          'Notes-20261109T090000Z-01HV0000000000000000000000.memex.zip',
        ),
        isNull,
      );
      expect(suggestedRestoreName('Notes.memex.zip'), '');
    });

    test('hostedBackupApiProvider declares a null stub', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(hostedBackupApiProvider), isNull);
    });

    test(
      'ClientHostedBackupApi stub has no result to give until A1 fills it',
      () {
        // A client over an HTTP client that fails the test if anything is sent:
        // the stub must not reach the network.
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final client = container.read(
          Provider<HostedClient>(
            (ref) => HostedClient(
              ref,
              serverId: 's1',
              serverName: 'nas',
              serverUrl: 'http://nas.invalid',
              accessToken: 'token',
              httpClient: MockClient((http.Request request) async {
                fail('the stub sent ${request.method} ${request.url}');
              }),
            ),
          ),
        );
        final api = ClientHostedBackupApi(client: client, vaultName: 'seed');
        expect(api, isA<HostedBackupApi>());
        expect(api.vaultName, 'seed');
        expect(identical(api.client, client), isTrue);
        expect(() => api.status(), throwsA(isA<UnimplementedError>()));
        expect(() => api.start(), throwsA(isA<UnimplementedError>()));
      },
    );
  });
}
