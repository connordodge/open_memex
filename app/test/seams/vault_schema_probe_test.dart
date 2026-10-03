import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

const _vault = '/tmp/om-fake-vault';

ProviderContainer _container({
  required VaultDb? db,
  MemexCli? cli,
  String? vaultPath = _vault,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vaultPath),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

FakeMemexCli _okCli({int value = 2}) => FakeMemexCli()
  ..on('settings get', (_) {
    return FakeMemexCli.ok(
      '{"vault_id":"01HV0000000000000000000000",'
      '"key":"smart_folder_max_depth","value":$value}',
    );
  });

FakeMemexCli _failingCli() => FakeMemexCli()
  ..on(
    'settings get',
    (_) => FakeMemexCli.failure("error: unrecognized subcommand 'settings'\n"),
  );

void main() {
  group('VaultDb schema probes', () {
    test('VaultDb.v5TableNames lists exactly the tables schema V5 adds', () {
      expect(VaultDb.v5TableNames.toSet(), v5Tables.toSet());
      expect(VaultDb.v5TableNames, hasLength(v5Tables.length));
    });

    test('hasTables counts each distinct name once and is true for none', () {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      expect(db.hasTables(['notes', 'notes']), isTrue);
      expect(db.hasTables(['smart_folders', 'smart_folders']), isFalse);
      expect(db.hasTables(const []), isTrue);
    });

    test('schemaVersion reads MAX(schema_version) fresh on every call', () {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      expect(db.schemaVersion(), 4);
      db.migrateToV5();
      expect(db.schemaVersion(), 5);
      db.addSchemaVersion(6);
      expect(db.schemaVersion(), 6);
    });

    test('schemaVersion is 0 without a schema_version table', () {
      final raw = sqlite3.openInMemory();
      final db = VaultDb.fromDatabase(raw);
      addTearDown(db.close);
      expect(db.schemaVersion(), 0);
      raw.execute('CREATE TABLE schema_version (version INTEGER PRIMARY KEY)');
      expect(db.schemaVersion(), 0, reason: 'empty table');
    });
  });

  group('vaultOpenProvider', () {
    test('keeps the smart_folder_max_depth value from the open call', () async {
      final db = FakeVaultDb.v5();
      addTearDown(db.close);
      final cli = _okCli(value: 3);
      final c = _container(db: db, cli: cli);

      final state = await c.read(vaultOpenProvider.future);

      expect(state.smartFolderMaxDepth, 3);
      expect(state.schemaOutdated, isFalse);
      expect(c.read(vaultRevisionProvider), 1);
    });

    test(
      'a failed call leaves the depth null and flags a V4 vault outdated',
      () async {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        final c = _container(db: db, cli: _failingCli());

        final state = await c.read(vaultOpenProvider.future);

        expect(state.smartFolderMaxDepth, isNull);
        expect(state.schemaOutdated, isTrue);
        expect(c.read(vaultRevisionProvider), 0);
      },
    );

    test(
      'a successful call that leaves the vault below V5 still flags it',
      () async {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        final c = _container(db: db, cli: _okCli());

        final state = await c.read(vaultOpenProvider.future);

        expect(state.smartFolderMaxDepth, 2);
        expect(state.schemaOutdated, isTrue);
      },
    );

    test('with no vault database it makes no call and flags nothing', () async {
      final cli = _okCli();
      final c = _container(db: null, cli: cli);

      final state = await c.read(vaultOpenProvider.future);

      expect(state.schemaOutdated, isFalse);
      expect(state.smartFolderMaxDepth, isNull);
      expect(cli.calls, isEmpty);
      expect(c.read(vaultRevisionProvider), 0);
    });

    test(
      'with no open vault path it makes no call and flags nothing',
      () async {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        final cli = _okCli();
        final c = _container(db: db, cli: cli, vaultPath: null);

        final state = await c.read(vaultOpenProvider.future);

        expect(state.schemaOutdated, isFalse);
        expect(cli.calls, isEmpty);
      },
    );
  });

  group('vaultV5ReadyProvider', () {
    test('is false on a V4 vault the open call could not migrate', () async {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      final c = _container(db: db, cli: _failingCli());
      final sub = c.listen(vaultV5ReadyProvider, (_, _) {});
      addTearDown(sub.close);

      expect(sub.read(), isFalse);
      await c.read(vaultOpenProvider.future);
      expect(sub.read(), isFalse);
    });

    test(
      'flips to true once the open call migrates the vault (no stale false)',
      () async {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        final release = Completer<void>();
        final cli = FakeMemexCli()
          ..on('settings get', (_) async {
            await release.future;
            db.migrateToV5();
            return FakeMemexCli.ok(settingsGetMaxDepthStdout);
          });
        final c = _container(db: db, cli: cli);
        final sub = c.listen(vaultV5ReadyProvider, (_, _) {});
        addTearDown(sub.close);

        expect(sub.read(), isFalse, reason: 'probed before the call returns');
        release.complete();
        await c.read(vaultOpenProvider.future);
        expect(sub.read(), isTrue);
      },
    );

    test('is true on a V5 vault and false with no vault database', () {
      final db = FakeVaultDb.v5();
      addTearDown(db.close);
      expect(_container(db: db).read(vaultV5ReadyProvider), isTrue);
      expect(_container(db: null).read(vaultV5ReadyProvider), isFalse);
    });
  });

  group('C1 error details', () {
    test(
      'MemexException.fields holds only the rule fields, not code or message',
      () {
        final e = MemexException.fromCliFailure(
          'add',
          FakeMemexCli.error('daily_note_exists', 'exists', {
            'date': '2026-10-03',
            'existing_id': '01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
          }),
        );
        expect(e.fields, {
          'date': '2026-10-03',
          'existing_id': '01J9Z8Y7X6W5V4T3S2R1Q0P9N8',
        });
        expect(e.message, 'add failed: exists');
      },
    );

    test('a C1 line without a message falls back to the code', () {
      final e = MemexException.fromCliFailure(
        'add',
        FakeMemexCli.failure('{"error":{"code":"internal"}}\n'),
      );
      expect(e.code, 'internal');
      expect(e.message, 'add failed: internal');
      expect(e.fields, isEmpty);
    });

    test(
      'a legacy version conflict from any wrapper is a version conflict',
      () {
        final e = MemexException.fromCliFailure(
          'canvas rename',
          FakeMemexCli.failure('Error: version conflict: expected 1\n'),
        );
        expect(e.kind, MemexErrorKind.versionConflict);
        expect(e.code, isNull);
      },
    );

    test('getSetting rejects stdout without an integer value', () async {
      for (final stdout in [
        'not json',
        '{"key":"smart_folder_max_depth","value":"2"}',
        '[2]',
      ]) {
        final cli = FakeMemexCli()
          ..on('settings get', (_) => FakeMemexCli.ok(stdout));
        await expectLater(
          cli.getSetting(_vault, smartFolderMaxDepthKey),
          throwsA(
            isA<MemexException>()
                .having((e) => e.code, 'code', isNull)
                .having((e) => e.message, 'message', contains(stdout)),
          ),
          reason: stdout,
        );
      }
    });

    test('the harness settings stdout parses through getSetting', () async {
      final cli = FakeMemexCli()
        ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));
      expect(await cli.getSetting(_vault, smartFolderMaxDepthKey), 2);
    });
  });
}
