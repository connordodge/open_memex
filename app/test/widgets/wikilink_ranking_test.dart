// WI #244 (A0, Spec #234 R23, R24): the `[[` popover ranks note titles by
// match kind for one query: a prefix first, then a substring, then letters
// found in order. Moving the scorer out must not change this order, so the
// test passes on main as a regression guard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/widgets/wikilink_autocomplete.dart';

import '../support/editor_scope.dart';

NoteTitle _note(String id, String title) =>
    NoteTitle(id: id, title: title, updatedAt: 0);

Finder _item(String title) => find.byKey(Key('wikilink-popover-item-$title'));

Future<TextEditingController> _pumpPopover(
  WidgetTester tester,
  List<NoteTitle> titles,
) async {
  final controller = TextEditingController();
  addTearDown(controller.dispose);
  await pumpEditorScoped(
    tester,
    MaterialApp(
      home: Scaffold(
        body: WikilinkAutocomplete(
          controller: controller,
          caretLocator: () => const Offset(20, 20),
          onNoteCreatedSelect: (_) {},
        ),
      ),
    ),
    titles: titles,
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('wikilink popover ranks prefix then substring then in-order', (
    tester,
  ) async {
    // Stored in an order that differs from the expected ranking.
    final controller = await _pumpPopover(tester, [
      _note('a', 'Pa Radio Inc'),
      _note('b', 'Zebra'),
      _note('c', 'The Pricing'),
      _note('d', 'Pricing'),
    ]);

    controller.value = const TextEditingValue(
      text: '[[Pri',
      selection: TextSelection.collapsed(offset: 5),
    );
    await tester.pumpAndSettle();

    expect(_item('Zebra'), findsNothing);
    expect(_item('Pricing'), findsOneWidget);
    expect(_item('The Pricing'), findsOneWidget);
    expect(_item('Pa Radio Inc'), findsOneWidget);
    final prefixY = tester.getTopLeft(_item('Pricing')).dy;
    final substringY = tester.getTopLeft(_item('The Pricing')).dy;
    final inOrderY = tester.getTopLeft(_item('Pa Radio Inc')).dy;
    expect(prefixY, lessThan(substringY));
    expect(substringY, lessThan(inOrderY));
  });

  testWidgets('wikilink popover matches the query case-insensitively', (
    tester,
  ) async {
    final controller = await _pumpPopover(tester, [
      _note('a', 'Roadmap Notes'),
      _note('b', 'Zebra'),
    ]);

    controller.value = const TextEditingValue(
      text: '[[ROAD',
      selection: TextSelection.collapsed(offset: 6),
    );
    await tester.pumpAndSettle();

    expect(_item('Roadmap Notes'), findsOneWidget);
    expect(_item('Zebra'), findsNothing);
  });
}
