// WI #70 (W0a) AC4–AC6: vaultAccessProvider over the real test setups the
// existing suites use (D13): CLI null with a database, database null with a
// CLI, and no open vault.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/fake_vault_db.dart';
import '../support/vault_access_reads.dart';
import '../support/vault_access_shapes.dart';
import '../support/vault_access_writes.dart';

const _vault = '/tmp/om-70-vault';

ProviderContainer _container({
  String? vault = _vault,
  VaultDb? db,
  MemexCli? cli,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

FakeVaultDb _seeded() {
  final db = seedVaultAccessFixture(FakeVaultDb.v5());
  addTearDown(db.close);
  return db;
}

void main() {
  group('AC4 no CLI', () {
    test(
      'with no CLI every local read returns the database data and writes are unavailable',
      () async {
        final db = _seeded();
        final c = _container(db: db, cli: null);

        final access = c.read(vaultAccessProvider);
        expect(access, isA<LocalVaultAccess>());
        expect(access!.canWrite, isFalse);
        for (final rc in vaultAccessReadCases) {
          expect(
            vaultAccessShape(await rc.viaAccess(access)),
            equals(vaultAccessShape(rc.viaDb(db))),
            reason: rc.name,
          );
        }
      },
    );

    test(
      'with no CLI every write throws a StateError and runs nothing',
      () async {
        final db = _seeded();
        final access = _container(db: db, cli: null).read(vaultAccessProvider)!;

        for (final wc in vaultAccessWriteCases) {
          await expectLater(
            Future.sync(() => wc.viaAccess(access)),
            throwsA(isA<StateError>()),
            reason: wc.name,
          );
        }
        // The database is untouched.
        expect(
          vaultAccessShape(await access.notes.listNotes()),
          equals(vaultAccessShape(db.listNotes())),
        );
      },
    );
  });

  group('AC4 no CLI contracts', () {
    test(
      'with no CLI each write throws a StateError saying the CLI is not available',
      () async {
        final db = _seeded();
        final access = _container(db: db, cli: null).read(vaultAccessProvider)!;

        for (final wc in vaultAccessWriteCases) {
          Object? caught;
          try {
            await wc.viaAccess(access);
          } catch (e) {
            caught = e;
          }
          expect(caught, isA<StateError>(), reason: wc.name);
          expect(
            (caught! as StateError).message,
            'The memex CLI is not available.',
            reason: wc.name,
          );
        }
      },
    );
  });

  group('AC5 no database contracts', () {
    test(
      'with no database revision is the constant no-database value',
      () async {
        final cli = vaultAccessSampleCli();
        final access = _container(
          db: null,
          cli: cli,
        ).read(vaultAccessProvider)!;

        expect(LocalVaultAccess.noDatabaseRevision, 'no-database');
        expect(await access.revision(), LocalVaultAccess.noDatabaseRevision);
        // Constant: a write through the CLI does not change it.
        await access.notes.addNote(contentMd: 'x');
        expect(await access.revision(), 'no-database');
        expect(cli.calls, hasLength(1), reason: 'revision never shells out');
      },
    );

    test(
      'with no database schemaVersion is the required version and never outdated',
      () async {
        final access = _container(
          db: null,
          cli: null,
        ).read(vaultAccessProvider)!;

        final version = await access.schemaVersion();
        expect(version, requiredVaultSchemaVersion);
        expect(version, 5);
        expect(version < requiredVaultSchemaVersion, isFalse);
      },
    );
  });

  group('AC5 no database', () {
    test('with no database local writes still run through the CLI', () async {
      final cli = vaultAccessSampleCli();
      final access = _container(db: null, cli: cli).read(vaultAccessProvider);

      expect(access, isNotNull);
      expect(access!.canWrite, isTrue);
      for (final wc in vaultAccessWriteCases) {
        cli.calls.clear();
        final today = vaultAccessSampleCli();
        final expected = await wc.viaCli(today, _vault);
        final got = await wc.viaAccess(access);
        expect(
          [for (final call in cli.calls) call.args],
          equals([for (final call in today.calls) call.args]),
          reason: wc.name,
        );
        expect(
          vaultAccessShape(got),
          equals(vaultAccessShape(expected)),
          reason: wc.name,
        );
      }
    });

    test(
      'with no database reads return empty values and writes still run',
      () async {
        final cli = vaultAccessSampleCli();
        final access = _container(
          db: null,
          cli: cli,
        ).read(vaultAccessProvider)!;

        for (final rc in vaultAccessReadCases) {
          if (rc.emptyShape == unpinnedWithoutDb) continue;
          expect(
            vaultAccessShape(await rc.viaAccess(access)),
            equals(rc.emptyShape),
            reason: rc.name,
          );
        }
        // Reads never shell out to make up for the missing database.
        expect(cli.calls, isEmpty);
        // And a write in the same setup still goes through the CLI.
        expect(
          await access.notes.addNote(contentMd: 'x'),
          '01J9Z8Y7X6W5V4T3S2R1Q0AB70',
        );
        expect(cli.callsFor('add'), hasLength(1));
      },
    );
  });

  group('AC6 no open vault', () {
    test(
      'vaultAccessProvider is null with no open vault and set once one opens',
      () {
        final db = _seeded();
        final cli = vaultAccessSampleCli();
        final c = ProviderContainer(
          overrides: [
            vaultDbProvider.overrideWithValue(db),
            memexCliProvider.overrideWithValue(cli),
            // A real StateProvider so the test can open a vault.
            currentVaultProvider.overrideWith((_) => null),
          ],
        );
        addTearDown(c.dispose);

        expect(c.read(vaultAccessProvider), isNull);

        c.read(currentVaultProvider.notifier).state = _vault;
        expect(c.read(vaultAccessProvider), isA<LocalVaultAccess>());

        c.read(currentVaultProvider.notifier).state = null;
        expect(c.read(vaultAccessProvider), isNull);
      },
    );

    test(
      'vaultAccessProvider rebuilds when the CLI handle changes so canWrite flips',
      () async {
        final cliState = StateProvider<MemexCli?>((_) => null);
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => _vault),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWith((ref) => ref.watch(cliState)),
          ],
        );
        addTearDown(c.dispose);

        expect(c.read(vaultAccessProvider)!.canWrite, isFalse);

        final cli = vaultAccessSampleCli();
        c.read(cliState.notifier).state = cli;
        final access = c.read(vaultAccessProvider)!;
        expect(access.canWrite, isTrue);
        await access.notes.addNote(contentMd: 'x');
        expect(cli.callsFor('add'), hasLength(1), reason: 'the new CLI runs');

        c.read(cliState.notifier).state = null;
        expect(c.read(vaultAccessProvider)!.canWrite, isFalse);
      },
    );

    test(
      'vaultAccessProvider rebuilds when the database handle changes so reads come from the new one',
      () async {
        final dbA = FakeVaultDb.v5();
        addTearDown(dbA.close);
        final dbB = _seeded();
        final dbState = StateProvider<VaultDb?>((_) => dbA);
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => _vault),
            vaultDbProvider.overrideWith((ref) => ref.watch(dbState)),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);

        expect(await c.read(vaultAccessProvider)!.notes.listNotes(), isEmpty);

        c.read(dbState.notifier).state = dbB;
        final fromB = await c.read(vaultAccessProvider)!.notes.listNotes();
        expect(fromB, isNotEmpty);
        expect(
          vaultAccessShape(fromB),
          equals(vaultAccessShape(dbB.listNotes())),
        );

        c.read(dbState.notifier).state = null;
        expect(
          await c.read(vaultAccessProvider)!.revision(),
          LocalVaultAccess.noDatabaseRevision,
        );
      },
    );

    test('vaultAccessProvider writes target the current vault path', () async {
      final cli = vaultAccessSampleCli();
      final c = ProviderContainer(
        overrides: [
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(cli),
          currentVaultProvider.overrideWith((_) => '/tmp/om-70-first'),
        ],
      );
      addTearDown(c.dispose);

      await c.read(vaultAccessProvider)!.topics.createFolder(name: 'A');
      c.read(currentVaultProvider.notifier).state = '/tmp/om-70-second';
      await c.read(vaultAccessProvider)!.topics.createFolder(name: 'B');

      expect(
        [for (final call in cli.calls) call.flag('vault')],
        ['/tmp/om-70-first', '/tmp/om-70-second'],
      );
    });
  });
}
