import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

void main() {
  group('pumpWorkspace harness (AC15)', () {
    testWidgets(
      'pumpWorkspace renders the workspace with the fakes and a FakeClock',
      (tester) async {
        final db = FakeVaultDb()
          ..seedNote(
            id: '01J9AAAAAAAAAAAAAAAAAAAAAA',
            title: 'Player Loop',
            content: 'Fixed the jump arc.\n',
            role: 'topic',
          )
          ..seedNote(
            id: '01J9BBBBBBBBBBBBBBBBBBBBBB',
            title: 'Sleep',
            content: 'Sleep was bad.\n',
          );
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          );
        final clock = FakeClock(DateTime(2026, 10, 3, 9, 5));

        final h = await pumpWorkspace(tester, db: db, cli: cli, clock: clock);

        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byKey(const Key('notes-rail')), findsOneWidget);
        expect(
          find.byKey(const Key('note-list-item-01J9AAAAAAAAAAAAAAAAAAAAAA')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('note-list-item-01J9BBBBBBBBBBBBBBBBBBBBBB')),
          findsOneWidget,
        );
        expect(find.text('Player Loop'), findsWidgets);

        // The four seams are the fakes.
        expect(identical(h.read(vaultDbProvider), db), isTrue);
        expect(identical(h.read(memexCliProvider), cli), isTrue);
        expect(identical(h.read(clockProvider), clock), isTrue);
        expect(h.read(currentVaultProvider), h.vaultPath);
        expect(h.read(clockProvider).now(), DateTime(2026, 10, 3, 9, 5));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'pumpWorkspace defaults to a V5 FakeVaultDb, a FakeMemexCli and a FakeClock',
      (tester) async {
        final h = await pumpWorkspace(tester);

        expect(find.byType(Workspace), findsOneWidget);
        expect(h.db.schemaVersionForTest, 5);
        expect(h.cli.callsFor('settings get'), hasLength(1));
        expect(h.clock.now(), DateTime(2026, 10, 3, 9));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
