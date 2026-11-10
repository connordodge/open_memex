// WI #363 (lead ruling Q1, lead-approved addition to #361's vault_menu.dart):
// `VaultMenuRegion.onOpenChanged` hears `true` when the menu opens and
// `false` when it closes (Escape or a chosen item); a region with no items
// never opens, so never calls it. Seams: a bare region around a plain box,
// a hosted vault ref (no folders), no providers overridden.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/widgets/vault_menu.dart';

import '../support/font_fetch_hold.dart';

const _anchor = Key('wi363-menu-anchor');
const _hosted = HostedVaultRef('srv-363', 'team');

Future<List<bool>> _pump(
  WidgetTester tester, {
  required bool isOpen,
  VoidCallback? onManage,
}) async {
  final calls = <bool>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: VaultMenuRegion(
              vault: _hosted,
              isOpen: isOpen,
              onManage: onManage,
              onOpenChanged: calls.add,
              child: const SizedBox(
                key: _anchor,
                width: 300,
                height: 56,
                child: ColoredBox(color: Colors.black12),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return calls;
}

Future<void> _secondaryClick(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byKey(_anchor)),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  holdFontFetches();

  testWidgets('onOpenChanged hears true on open and false on Escape', (
    tester,
  ) async {
    final calls = await _pump(tester, isOpen: false, onManage: () {});

    await _secondaryClick(tester);
    expect(find.byKey(const Key('vault-menu-remove')), findsOneWidget);
    expect(calls, [true]);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('vault-menu-remove')), findsNothing);
    expect(calls, [true, false]);
  });

  testWidgets('onOpenChanged hears false when an item is chosen', (
    tester,
  ) async {
    var managed = 0;
    final calls = await _pump(tester, isOpen: false, onManage: () => managed++);

    await _secondaryClick(tester);
    await tester.tap(find.byKey(const Key('vault-menu-manage')));
    await tester.pump();

    expect(managed, 1);
    expect(calls, [true, false]);
  });

  testWidgets('a vault menu region with no items never calls onOpenChanged', (
    tester,
  ) async {
    // The open hosted vault with no manage has no items.
    final calls = await _pump(tester, isOpen: true);

    await _secondaryClick(tester);

    expect(find.byKey(const Key('vault-menu-manage')), findsNothing);
    expect(calls, isEmpty);
  });
}
