// WI #30 (A12) with #22's virtual Today note: its tab chip reads its ISO
// date, and its note menu offers no Open graph item (the unsaved note is in
// no graph yet). Implementer tests, launched through #22's TodayRobot.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../robots/today_robot.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

void main() {
  testWidgets('the virtual Today tab chip reads its ISO date', (tester) async {
    final r = TodayRobot(tester);
    await r.launch(db: FakeVaultDb.v5(), cli: FakeMemexCli());
    r.expectVirtualToday('2026-10-03');

    final chip = find.byKey(const Key('tab-note-virtual-today:2026-10-03'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.text('2026-10-03')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chip, matching: find.text('note')),
      findsNothing,
    );
  });

  testWidgets(
    'the note menu has no Open graph item for the virtual Today note',
    (tester) async {
      final r = TodayRobot(tester);
      await r.launch(db: FakeVaultDb.v5(), cli: FakeMemexCli());
      r.expectVirtualToday('2026-10-03');

      await r.openNoteMenu();

      expect(find.byKey(const Key('note-menu')), findsOneWidget);
      expect(find.byKey(const Key('note-menu-delete')), findsOneWidget);
      expect(find.byKey(const Key('note-menu-open-graph')), findsNothing);
    },
  );
}
