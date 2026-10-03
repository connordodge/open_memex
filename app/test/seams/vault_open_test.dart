import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

const _bannerKey = Key('vault-schema-outdated');
const _bannerText =
    'This vault needs a newer memex. Update the memex binary, then reopen the vault.';

/// `settings get` as an older `memex` without the subcommand answers it.
FakeCliHandler _olderMemex() =>
    (_) => FakeMemexCli.failure(
      "error: unrecognized subcommand 'settings'\n",
      exitCode: 2,
    );

void _expectBanner() {
  expect(find.byKey(_bannerKey), findsOneWidget);
  expect(
    find.descendant(
      of: find.byKey(_bannerKey),
      matching: find.text(_bannerText),
    ),
    findsOneWidget,
  );
}

void _expectNoBanner() {
  expect(find.byKey(_bannerKey), findsNothing);
  expect(find.text(_bannerText), findsNothing);
}

void main() {
  group('vault open runs settings get once (AC12)', () {
    testWidgets(
      'opening a vault calls settings get --key smart_folder_max_depth exactly once and bumps vaultRevisionProvider',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );

        final h = await pumpWorkspace(tester, cli: cli);

        final calls = cli.callsFor('settings get');
        expect(calls, hasLength(1));
        expect(calls.single.args, [
          'settings',
          'get',
          '--vault',
          h.vaultPath,
          '--key',
          'smart_folder_max_depth',
        ]);
        expect(h.read(vaultRevisionProvider), 1);
        expect(cli.calls, hasLength(1), reason: 'no other CLI call on open');

        // Later revision bumps and rebuilds do not re-run the migration call.
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        h.container.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        expect(cli.callsFor('settings get'), hasLength(1));
        expect(h.read(vaultRevisionProvider), 3);
      },
    );

    testWidgets(
      'a failed settings get on open does not bump vaultRevisionProvider',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.error('internal', 'database is locked'),
          );

        final h = await pumpWorkspace(tester, cli: cli);

        expect(cli.callsFor('settings get'), hasLength(1));
        expect(h.read(vaultRevisionProvider), 0);
      },
    );
  });

  group('outdated-vault banner (AC13)', () {
    testWidgets(
      'a V4 vault whose settings get fails shows the vault-schema-outdated banner',
      (tester) async {
        final cli = FakeMemexCli()..on('settings get', _olderMemex());
        final db = FakeVaultDb.v4();

        await pumpWorkspace(tester, db: db, cli: cli);

        expect(db.schemaVersionForTest, 4);
        _expectBanner();
      },
    );

    testWidgets(
      'a V4 vault shows the banner when no memex binary is configured',
      (tester) async {
        await pumpWorkspace(
          tester,
          db: FakeVaultDb.v4(),
          memexConfigured: false,
        );
        _expectBanner();
      },
    );

    testWidgets(
      'a V4 vault shows the banner when the memex binary cannot be started',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => throw const ProcessException(
              'fake-memex',
              ['settings', 'get'],
              'No such file or directory',
              2,
            ),
          );
        await pumpWorkspace(tester, db: FakeVaultDb.v4(), cli: cli);
        _expectBanner();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a V5 vault shows no banner even when settings get fails', (
      tester,
    ) async {
      final cli = FakeMemexCli()..on('settings get', _olderMemex());
      await pumpWorkspace(tester, db: FakeVaultDb.v5(), cli: cli);
      expect(cli.callsFor('settings get'), hasLength(1));
      _expectNoBanner();
    });

    testWidgets(
      'a V5 vault shows no banner when no memex binary is configured',
      (tester) async {
        await pumpWorkspace(
          tester,
          db: FakeVaultDb.v5(),
          memexConfigured: false,
        );
        _expectNoBanner();
      },
    );

    testWidgets('a vault newer than V5 shows no outdated banner', (
      tester,
    ) async {
      final db = FakeVaultDb.v5()..addSchemaVersion(6);
      final cli = FakeMemexCli()..on('settings get', _olderMemex());
      await pumpWorkspace(tester, db: db, cli: cli);
      _expectNoBanner();
    });

    testWidgets('a V5 vault whose settings get succeeds shows no banner', (
      tester,
    ) async {
      await pumpWorkspace(tester);
      _expectNoBanner();
    });
  });

  group('V4 vault migrated by the CLI on open (AC14)', () {
    testWidgets(
      'a V4 vault migrated by settings get shows no banner and the re-probe sees the V5 tables',
      (tester) async {
        final db = FakeVaultDb.v4();
        final cli = FakeMemexCli()
          ..on('settings get', (_) {
            db.migrateToV5(); // the CLI migrates the vault the app has open
            return FakeMemexCli.ok(settingsGetMaxDepthStdout);
          });

        // The app may probe before the migration call returns.
        expect(db.hasTables(v5Tables), isFalse);

        final h = await pumpWorkspace(tester, db: db, cli: cli);

        expect(cli.callsFor('settings get'), hasLength(1));
        expect(db.schemaVersionForTest, 5);
        expect(h.read(vaultRevisionProvider), 1);
        expect(db.hasTables(v5Tables), isTrue);
        _expectNoBanner();
      },
    );
  });
}
