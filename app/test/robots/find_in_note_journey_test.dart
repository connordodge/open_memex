// WI #85 (Spec #61 F6): the Find in note robot journey (Testing Strategy,
// Robot journey). A person opens a topic note with an excerpt card and a
// table, presses Cmd+F (the native menu's `find show` message, TD5), types
// `rye`, steps to the card match and the table match, types in the body
// with the bar open, then presses Esc in the field and lands in the editor
// with the current body match selected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';

import '../support/font_fetch_hold.dart';
import '../support/wi85_find_editor.dart';
import 'find_in_note_robot.dart';

void main() {
  holdFontFetches();

  testWidgets(
    'find in note journey from Cmd+F through the card and table matches to Esc',
    (tester) async {
      final r = await FindInNoteRobot.launch(tester);
      final w = r.w;

      // A topic note with a card (segment 1) and a table (in segment 2).
      expect(r.editor.card(1), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) {
          final k = widget.key;
          return k is ValueKey<String> && k.value.startsWith('editor-table-2-');
        }),
        findsWidgets,
        reason: 'the table shows as a grid',
      );

      await r.pressCmdF();
      expect(w.bar, findsOneWidget);
      expect(w.fieldFocused, isTrue);

      await r.typeQuery(wi85Query);
      r.expectBarOpen(query: wi85Query, total: 12);
      expect(w.ranges(), isNotEmpty, reason: 'matches are highlighted');

      final reveals = w.reveals();
      final card = await r.stepToCardMatch();
      expect(card.segment, 1);
      expect(reveals.last.at, isA<RevealAtCard>());

      final tableAt = wi85Seg2.indexOf('dark rye') + 'dark '.length;
      final table = await r.stepToBodyMatch(2, tableAt);
      expect(reveals.last.at, isA<RevealAtText>());
      expect((reveals.last.at as RevealAtText).start, tableAt);
      r.expectBarOpen(query: wi85Query, total: 12);
      final index = w.state.current!;

      // Typing in the body with the bar open: the count follows, the current
      // match stays.
      await r.typeInBody(0, 0, 'rye ');
      r.expectBarOpen(query: wi85Query, total: 13);
      expect(w.state.currentMatch, table);
      expect(w.state.current, index + 1);

      // Esc in the body leaves the bar open; Esc in the field closes it.
      await r.pressEsc();
      expect(w.bar, findsOneWidget);
      await r.clickField();
      expect(w.fieldFocused, isTrue);
      await r.pressEsc();

      r.expectBarClosed();
      r.expectSelected(table);
      expect(w.state.lastQuery, wi85Query);
      expect(table.kind, FindSourceKind.body);
    },
  );
}
