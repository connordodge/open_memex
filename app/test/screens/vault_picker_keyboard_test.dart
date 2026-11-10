// WI #349 (Spec #347 req 18, L5): on the real vault picker, Tab reaches a
// local recent row's x and a server row's edit and remove, and Enter
// presses them: the x forgets the row, edit calls
// `PickerActions.editServer` for that server, remove opens the remove
// server confirm. Seams: test/support/vault_picker_harness.dart (recording
// picker actions, mock prefs, fake servers) and a real temp vault folder.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:path/path.dart' as p;

import '../support/font_fetch_hold.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi349_keyboard.dart';

void main() {
  holdFontFetches();

  testWidgets('Tab reaches a local recent row x and Enter forgets that row', (
    tester,
  ) async {
    final keep = createVaultFolder();
    final forget = createVaultFolder();
    final env = await pumpVaultPicker(
      tester,
      recents: [LocalVaultRef(keep.path), LocalVaultRef(forget.path)],
    );
    final x = find.byKey(const Key('recent-row-remove-1'));
    expect(x, findsOneWidget);

    await wi349TabTo(tester, x);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await wi97Settle(tester);

    expect(env.settings.recentRefs, [LocalVaultRef(keep.path)]);
    expect(find.text(p.basename(forget.path)), findsNothing);
    expect(find.text(p.basename(keep.path)), findsOneWidget);
    expect(env.opener.opened, isEmpty, reason: 'Enter on x opens nothing');
  });

  testWidgets(
    'Tab reaches a server row edit and Enter calls editServer for that server',
    (tester) async {
      final env = await pumpVaultPicker(
        tester,
        savedServers: const [wi97Nas, wi97Mini],
      );
      final edit = find.byKey(const Key('server-row-edit-srv-mini'));
      expect(edit, findsOneWidget);

      await wi349TabTo(tester, edit);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await wi97Settle(tester);

      expect(env.actions.calls, ['editServer srv-mini']);
    },
  );

  testWidgets(
    'Tab reaches a server row remove and Enter opens the remove server confirm',
    (tester) async {
      final env = await pumpVaultPicker(
        tester,
        savedServers: const [wi97Nas, wi97Mini],
      );
      final remove = find.byKey(const Key('server-row-remove-srv-nas'));
      expect(remove, findsOneWidget);
      expect(find.text('REMOVE SERVER'), findsNothing);

      await wi349TabTo(tester, remove);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await wi97Settle(tester);

      expect(find.text('REMOVE SERVER'), findsOneWidget);
      expect(find.text('remove nas?'), findsOneWidget);
      // Opening the confirm changes nothing yet.
      expect(env.settings.savedServers.map((s) => s.id), [
        'srv-nas',
        'srv-mini',
      ]);
      expect(env.actions.calls, isEmpty);
    },
  );
}
