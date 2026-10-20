// WI #87 (W3, verify): + New topic on a day with no daily note creates that
// note first. When the footer call then throws VaultUnreachableException the
// guard snackbar shows, no tab opens, and the revision is still bumped once:
// the daily note exists and the Days list and today note must see it.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/footer_cli_fakes.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';

void main() {
  testWidgets(
    'a + New topic whose footer call is unreachable after the daily note was just created shows the snackbar opens no tab and still bumps the revision',
    (tester) async {
      final db = FakeVaultDb.v5();
      final cli = FakeMemexCli()
        ..onAddCreates(db)
        ..onFooterAdd(db);
      final doubles = AccessDoubles();
      final r = await launchTopics(tester, doubles, db: db, cli: cli);
      final bumps = RevisionCounter(r.h);
      final tabsBefore = r.h.read(tabsProvider).tabs.length;
      doubles
          .dailyAt(r.h.vaultPath)
          .failNext(
            'addFooterChip',
            const VaultUnreachableException(
              serverName: 'nas',
              mayHaveCommitted: false,
            ),
          );

      await r.tap(r.byKey('topics-new-topic'));
      await r.tester.enterText(r.byKey('new-topic-title-field'), 'Player Loop');
      await r.tester.pump();
      await r.tap(r.byKey('new-topic-confirm'));

      expect(find.text("couldn't reach nas. try again."), findsOneWidget);
      expect(r.anyError, findsNothing);
      expect(r.h.read(tabsProvider).tabs, hasLength(tabsBefore));
      expect(bumps.bumps, 1, reason: 'the daily note was created on the way');
    },
  );
}
