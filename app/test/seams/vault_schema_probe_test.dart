import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/vault_schema_banner.dart';
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
      currentVaultProvider.overrideWith(
        (_) => vaultPath == null ? null : LocalVaultRef(vaultPath),
      ),
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
      expect(db.schemaVersion(), requiredVaultSchemaVersion);
      db.addSchemaVersion(requiredVaultSchemaVersion + 1);
      expect(db.schemaVersion(), requiredVaultSchemaVersion + 1);
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

  group('VaultSchemaBanner', () {
    testWidgets('the outdated banner waits for the open call to finish', (
      tester,
    ) async {
      final release = Completer<MemexResult>();
      final cli = FakeMemexCli()..on('settings get', (_) => release.future);

      await pumpWorkspace(tester, db: FakeVaultDb.v4(), cli: cli);
      expect(find.byKey(const Key('vault-schema-outdated')), findsNothing);

      release.complete(
        FakeMemexCli.failure("error: unrecognized subcommand 'settings'\n"),
      );
      await pumpFrames(tester);
      expect(find.byKey(const Key('vault-schema-outdated')), findsOneWidget);
      expect(find.text(vaultSchemaOutdatedMessage), findsOneWidget);
    });
  });

  group('Schema V6 probes (#237)', () {
    test('requiredVaultSchemaVersion is 6', () {
      expect(requiredVaultSchemaVersion, 6);
    });

    test('VaultDb.v6TableNames lists exactly the tables schema V6 adds', () {
      expect(VaultDb.v6TableNames.toSet(), {
        'tag_corrections',
        'feedback',
        'vault_guide_revisions',
      });
      expect(VaultDb.v6TableNames, hasLength(3));
      expect(VaultDb.v6TableNames.toSet(), v6Tables.toSet());
      for (final t in VaultDb.v5TableNames) {
        expect(VaultDb.v6TableNames, isNot(contains(t)), reason: t);
      }

      final v6 = FakeVaultDb.v6();
      addTearDown(v6.close);
      expect(v6.hasTables(VaultDb.v6TableNames), isTrue);
      final v5 = FakeVaultDb.v5Only();
      addTearDown(v5.close);
      expect(v5.hasTables(VaultDb.v6TableNames), isFalse);
      expect(v5.hasTables(VaultDb.v5TableNames), isTrue);
    });

    test('hasColumns is true only when the table has every listed column', () {
      final v6 = FakeVaultDb.v6();
      addTearDown(v6.close);
      expect(v6.hasColumns('tags', ['origin', 'first_line']), isTrue);
      expect(v6.hasColumns('tags', ['note_id', 'tag', 'origin']), isTrue);
      expect(v6.hasColumns('tags', ['origin', 'origin']), isTrue);
      expect(v6.hasColumns('tags', const []), isTrue);
      expect(v6.hasColumns('tags', ['origin', 'no_such_column']), isFalse);
      expect(v6.hasColumns('notes', ['origin']), isFalse);
      expect(v6.hasColumns('no_such_table', ['origin']), isFalse);
      expect(
        v6.hasColumns('tag_corrections', ['note_title', 'cleared_at']),
        isTrue,
      );

      final v5 = FakeVaultDb.v5Only();
      addTearDown(v5.close);
      expect(v5.hasColumns('tags', ['note_id', 'tag']), isTrue);
      expect(v5.hasColumns('tags', ['origin']), isFalse);
      expect(v5.hasColumns('tags', ['first_line']), isFalse);
      expect(v5.hasColumns('tags', ['origin', 'first_line']), isFalse);
    });

    test(
      'hasColumns re-probes after the CLI adds the columns (no cached false)',
      () {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        expect(db.hasColumns('tags', v6TagColumns), isFalse);
        db.seedNote(
          id: '01J9V6000000000000000000P1',
          title: 'Kept',
          tags: ['work'],
        );

        db.migrateToV6(); // what `memex` does to a V5 vault on its first V6 open

        expect(db.hasColumns('tags', v6TagColumns), isTrue);
        expect(
          db.db
              .select('SELECT note_id, tag, origin FROM tags')
              .map((r) => [r['note_id'], r['tag'], r['origin']]),
          [
            ['01J9V6000000000000000000P1', 'work', 'person'],
          ],
        );
      },
    );

    test(
      'vaultV6ReadyProvider is false on a V5 vault and true on a V6 vault',
      () {
        final v5 = FakeVaultDb.v5Only();
        addTearDown(v5.close);
        final v6 = FakeVaultDb.v6();
        addTearDown(v6.close);

        expect(_container(db: v5).read(vaultV6ReadyProvider), isFalse);
        expect(_container(db: v6).read(vaultV6ReadyProvider), isTrue);
        expect(_container(db: null).read(vaultV6ReadyProvider), isFalse);
        // The V5 probe stays true on both: V6 is additive.
        expect(_container(db: v5).read(vaultV5ReadyProvider), isTrue);
        expect(_container(db: v6).read(vaultV5ReadyProvider), isTrue);
      },
    );

    test(
      'vaultV6ReadyProvider needs every V6 table even when the tags columns exist',
      () {
        final db = FakeVaultDb.v6();
        addTearDown(db.close);
        final c = _container(db: db);
        final sub = c.listen(vaultV6ReadyProvider, (_, _) {});
        addTearDown(sub.close);
        expect(db.hasColumns('tags', v6TagColumns), isTrue);
        expect(sub.read(), isTrue);

        db.db.execute('DROP TABLE vault_guide_revisions');
        c.read(vaultRevisionProvider.notifier).state++;
        expect(db.hasColumns('tags', v6TagColumns), isTrue);
        expect(sub.read(), isFalse);
      },
    );

    test('vaultV6ReadyProvider is true for a hosted vault', () {
      final c = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith(
            (_) => HostedVaultRef('srv-1', 'work'),
          ),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(vaultV6ReadyProvider), isTrue);
    });

    test(
      'vaultV6ReadyProvider needs the V6 tags columns as well as the V6 tables',
      () {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        final c = _container(db: db);
        final sub = c.listen(vaultV6ReadyProvider, (_, _) {});
        addTearDown(sub.close);
        expect(sub.read(), isFalse);

        // The V6 tables without the tags columns: still not ready.
        db.migrateToV6(tagColumns: false);
        c.read(vaultRevisionProvider.notifier).state++;
        expect(db.hasTables(v6Tables), isTrue, reason: 'fixture is V6');
        expect(sub.read(), isFalse);

        // The columns too: ready, on the next revision (never a cached false).
        db.migrateToV6();
        c.read(vaultRevisionProvider.notifier).state++;
        expect(sub.read(), isTrue);
      },
    );

    test(
      'vaultV6ReadyProvider flips to true once the open call migrates a V5 vault',
      () async {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        final release = Completer<void>();
        final cli = FakeMemexCli()
          ..on('settings get', (_) async {
            await release.future;
            db.migrateToV6();
            return FakeMemexCli.ok(settingsGetMaxDepthStdout);
          });
        final c = _container(db: db, cli: cli);
        final sub = c.listen(vaultV6ReadyProvider, (_, _) {});
        addTearDown(sub.close);

        expect(sub.read(), isFalse, reason: 'probed before the call returns');
        release.complete();
        final state = await c.read(vaultOpenProvider.future);
        expect(sub.read(), isTrue);
        expect(state.schemaOutdated, isFalse);
      },
    );

    test(
      'a V5 vault the open call cannot migrate is flagged outdated',
      () async {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        final c = _container(db: db, cli: _failingCli());

        final state = await c.read(vaultOpenProvider.future);

        expect(db.schemaVersion(), 5);
        expect(state.schemaOutdated, isTrue);
        expect(c.read(vaultV6ReadyProvider), isFalse);

        // A V6 vault with the same failing call is not.
        final v6 = FakeVaultDb.v6();
        addTearDown(v6.close);
        final c6 = _container(db: v6, cli: _failingCli());
        expect(
          (await c6.read(vaultOpenProvider.future)).schemaOutdated,
          isFalse,
        );
      },
    );

    testWidgets(
      'a V5 vault opened with an older memex shows the outdated-vault banner',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.failure(
              "error: unrecognized subcommand 'settings'\n",
            ),
          );
        final db = FakeVaultDb.v5Only();

        await pumpWorkspace(tester, db: db, cli: cli);
        await pumpFrames(tester);

        expect(db.schemaVersionForTest, 5);
        expect(find.byKey(const Key('vault-schema-outdated')), findsOneWidget);
        expect(find.text(vaultSchemaOutdatedMessage), findsOneWidget);
      },
    );
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
