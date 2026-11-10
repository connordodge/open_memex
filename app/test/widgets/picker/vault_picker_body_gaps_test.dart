// WI #362 (design pack 362, board A1/A2): the vertical rhythm of the picker
// body's lists. An eyebrow sits 10 px above its first row (no gap is added
// before the first row), and rows in a list are 6 px apart. Pinned for the
// RECENT and the SERVERS lists on the full-screen picker.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';

import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/vault_picker_harness.dart';

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(Key(key)));

void main() {
  holdFontFetches();

  testWidgets(
    'the first recent row is 10 below the RECENT eyebrow and rows are 6 apart',
    (tester) async {
      await pumpVaultPicker(
        tester,
        recents: const [
          HostedVaultRef(fakeServerId, 'one'),
          HostedVaultRef(fakeServerId, 'two'),
          HostedVaultRef(fakeServerId, 'three'),
        ],
      );

      final eyebrow = tester.getRect(find.text('RECENT'));
      final rows = [for (var i = 0; i < 3; i++) _rect(tester, 'recent-row-$i')];
      expect(rows[0].top, closeTo(eyebrow.bottom + 10, 0.01));
      expect(rows[1].top, closeTo(rows[0].bottom + 6, 0.01));
      expect(rows[2].top, closeTo(rows[1].bottom + 6, 0.01));
    },
  );

  testWidgets(
    'the first server row is 10 below the SERVERS header and rows are 6 apart',
    (tester) async {
      await pumpVaultPicker(tester, savedServers: const [wi97Nas, wi97Mini]);

      final header = tester.getRect(find.text('SERVERS'));
      final first = _rect(tester, 'server-row-${wi97Nas.id}');
      final second = _rect(tester, 'server-row-${wi97Mini.id}');
      // The header row is 16.5 high and the eyebrow text sits at its top.
      expect(first.top, closeTo(header.top + 16.5 + 10, 0.01));
      expect(second.top, closeTo(first.bottom + 6, 0.01));
    },
  );
}
