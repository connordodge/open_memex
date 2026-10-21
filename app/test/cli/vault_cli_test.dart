// WI #92 (D19): the `memex vault check` wrapper and its outcome classifier.
// #75's exit-code contract: 0 safe, 1 one C1 line (`network_filesystem` for a
// network drive), 2 only for clap's usage error (an older memex without
// `vault check`). A statfs error is reported as an error, never as
// `network_filesystem`.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/vault_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';

import '../support/fake_memex_cli.dart';

const _vault = '/tmp/om92 vault/My Memex';

/// clap's answer when `vault` is not a known subcommand (exit 2).
const _clapUsageError =
    "error: unrecognized subcommand 'vault'\n\n"
    'Usage: memex <COMMAND>\n\n'
    "For more information, try '--help'.\n";

String _c1Line(String code, String message) => jsonEncode({
  'error': {'code': code, 'message': message},
});

Future<VaultCheckResult> _check(MemexResult result) async {
  final cli = FakeMemexCli()..on('vault check', (_) => result);
  return cli.checkVault(_vault);
}

void main() {
  group('vault check call', () {
    test(
      'checkVault runs memex vault check --vault with the path as one argument',
      () async {
        final cli = FakeMemexCli()..on('vault check', (_) => FakeMemexCli.ok());

        await cli.checkVault(_vault);

        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, ['vault', 'check', '--vault', _vault]);
        expect(cli.calls.single.stdinBody, isNull);
      },
    );

    test(
      'a spawn failure is binary not found and checkVault does not throw',
      () async {
        final cli = FakeMemexCli()
          ..on(
            'vault check',
            (_) => throw const ProcessException(
              'fake-memex',
              ['vault', 'check'],
              'No such file or directory',
              2,
            ),
          );

        final result = await cli.checkVault(_vault);

        expect(result.status, VaultCheckStatus.binaryNotFound);
        expect(cli.callsFor('vault check'), hasLength(1));
      },
    );
  });

  group('outcome classifier', () {
    // Only exit 0 is safe; only exit 2 is too old; only exit 1 with the C1
    // code network_filesystem is the network-drive refusal.
    for (final (name, result, status) in [
      ('vault check exit 0 is safe', FakeMemexCli.ok(), VaultCheckStatus.safe),
      (
        'vault check exit 0 with output on stdout is safe',
        FakeMemexCli.ok('{"ok":true}\n'),
        VaultCheckStatus.safe,
      ),
      (
        'vault check exit 1 with C1 network_filesystem is a network drive',
        FakeMemexCli.error(
          'network_filesystem',
          'the vault folder is on a network filesystem',
        ),
        VaultCheckStatus.networkFilesystem,
      ),
      (
        'vault check exit 1 with log lines before the C1 network_filesystem line is a network drive',
        FakeMemexCli.failure(
          'warn: probing /Volumes/home\n'
          '${_c1Line('network_filesystem', 'network filesystem (smbfs)')}\n',
        ),
        VaultCheckStatus.networkFilesystem,
      ),
      (
        'vault check exit 2 with a clap usage error is too old',
        FakeMemexCli.failure(_clapUsageError, exitCode: 2),
        VaultCheckStatus.memexTooOld,
      ),
      (
        'vault check exit 2 with empty stderr is too old',
        FakeMemexCli.failure('', exitCode: 2),
        VaultCheckStatus.memexTooOld,
      ),
      (
        'vault check exit 2 with a C1 network_filesystem line is still too old',
        FakeMemexCli.failure(
          '${_c1Line('network_filesystem', 'network filesystem')}\n',
          exitCode: 2,
        ),
        VaultCheckStatus.memexTooOld,
      ),
    ]) {
      test(name, () async {
        final r = await _check(result);
        expect(r.status, status);
      });
    }

    // Every other failure: today's open error, carrying the one C1 parse.
    for (final (name, result, code) in [
      (
        'vault check exit 1 with C1 not_found is a failure',
        FakeMemexCli.error('not_found', 'no such folder'),
        'not_found',
      ),
      (
        'vault check exit 1 with a statfs error is a failure and never a network drive',
        FakeMemexCli.error('io', 'statfs failed: permission denied'),
        'io',
      ),
      (
        'vault check exit 1 with a C1 code other than network_filesystem whose message names it is a failure',
        FakeMemexCli.error('internal', 'network_filesystem probe crashed'),
        'internal',
      ),
      (
        'vault check exit 1 with non-JSON stderr is a failure',
        FakeMemexCli.failure('thread main panicked: network_filesystem\n'),
        null,
      ),
      (
        'vault check exit 1 with a JSON line without an error object is a failure',
        FakeMemexCli.failure('{"code":"network_filesystem"}\n'),
        null,
      ),
      (
        'vault check exit 3 with C1 network_filesystem is a failure',
        FakeMemexCli.failure(
          '${_c1Line('network_filesystem', 'network filesystem')}\n',
          exitCode: 3,
        ),
        'network_filesystem',
      ),
      (
        'vault check exit 101 from a panic is a failure',
        FakeMemexCli.failure('panicked at src/main.rs\n', exitCode: 101),
        null,
      ),
      (
        'vault check killed by a signal is a failure',
        FakeMemexCli.failure('', exitCode: -9),
        null,
      ),
    ]) {
      test(name, () async {
        final r = await _check(result);
        expect(r.status, VaultCheckStatus.failed);
        expect(r.error, isNotNull);
        expect(r.error!.code, code);
        expect(
          r.error!.message,
          MemexException.fromCliFailure('vault check', result).message,
        );
      });
    }
  });
}
