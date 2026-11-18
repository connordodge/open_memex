// WI #82 (Spec #61 F2; Reqs 30-33; design pack packs/82.md, boards B1,
// B3.2, B3.6, B3.7, B4.1-B4.5): the Find bar's geometry by body width. The
// box is `min(372, body - 24)` wide; the field flexes first and never goes
// under 96 px while the counter shows; the counter takes the short form
// below a 300 px box and hides below 240 (or when the short form would push
// the field under 96); below a 240 px box the magnifier is dropped too.
//
// "Field" is the rect of the widget keyed `find-bar-field`: the whole field
// box (its border, the magnifier inside it and the query), 198 px at a
// 372 px box. Widths are the design's, in the fonts the app ships
// (wi82LoadFonts), to half a pixel.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import 'find_bar_harness.dart';

const double _wi82Px = 0.5;

/// The box's rect relative to the body host.
Rect _wi82BoxInHost(WidgetTester tester) =>
    tester.getRect(wi82Box).shift(-wi82Host(tester).topLeft);

/// Each of the up, down and close buttons sits wholly inside the box.
void _wi82ButtonsInside(WidgetTester tester) {
  final box = tester.getRect(wi82Box);
  for (final button in [wi82Previous, wi82Next, wi82Close]) {
    expect(button, findsOneWidget);
    final r = tester.getRect(button);
    expect(r.left, greaterThanOrEqualTo(box.left - 0.01));
    expect(r.right, lessThanOrEqualTo(box.right + 0.01));
  }
}

void main() {
  holdFontFetches();
  wi82LoadFonts();

  testWidgets(
    'the box is 372 px wide at body 532, 300 at 324, 240 at 264 and 168 at 192',
    (tester) async {
      final widths = <(double, double)>[
        (532, 372),
        (324, 300),
        (264, 240),
        (192, 168),
      ];
      for (final (body, width) in widths) {
        await wi82Pump(tester, bodyWidth: body, current: 1);
        final box = _wi82BoxInHost(tester);
        expect(
          box.width,
          moreOrLessEquals(width, epsilon: 0.01),
          reason: '$body',
        );
        expect(
          box.height,
          moreOrLessEquals(38, epsilon: 0.01),
          reason: '$body',
        );
        expect(box.top, moreOrLessEquals(10, epsilon: 0.01), reason: '$body');
        expect(
          body - box.right,
          moreOrLessEquals(12, epsilon: 0.01),
          reason: '$body',
        );
      }
    },
    variant: macOnly,
  );

  testWidgets(
    'at body 532 the field, magnifier, counter and buttons sit where design B4.1 puts them',
    (tester) async {
      await wi82Pump(tester, current: 1);
      final box = tester.getRect(wi82Box);

      final field = tester.getRect(wi82Field);
      expect(field.left - box.left, moreOrLessEquals(7, epsilon: _wi82Px));
      expect(field.top - box.top, moreOrLessEquals(6, epsilon: _wi82Px));
      expect(field.width, moreOrLessEquals(198, epsilon: _wi82Px));
      expect(field.height, moreOrLessEquals(26, epsilon: _wi82Px));

      final magnifier = tester.getRect(wi82Magnifier);
      expect(magnifier.left - box.left, moreOrLessEquals(16, epsilon: _wi82Px));
      expect(magnifier.size, const Size(12, 12));
      expect(
        magnifier.center.dy,
        moreOrLessEquals(box.center.dy, epsilon: _wi82Px),
      );

      final previous = tester.getRect(wi82Previous);
      final next = tester.getRect(wi82Next);
      final close = tester.getRect(wi82Close);
      for (final b in [previous, next, close]) {
        expect(b.size, const Size(24, 24));
        expect(b.top - box.top, moreOrLessEquals(7, epsilon: _wi82Px));
      }
      expect(box.right - close.right, moreOrLessEquals(7, epsilon: _wi82Px));
      expect(close.left - next.right, moreOrLessEquals(4, epsilon: _wi82Px));
      expect(next.left - previous.right, moreOrLessEquals(4, epsilon: _wi82Px));

      // Counter text box: min 64 wide, 4 px margin plus 4 px gap before
      // the up button, centred on the box.
      expect(wi82CounterText(tester), '2 of 12');
      final counter = tester.getRect(wi82Counter);
      expect(counter.width, moreOrLessEquals(64, epsilon: _wi82Px));
      expect(
        previous.left - counter.right,
        moreOrLessEquals(8, epsilon: _wi82Px),
      );
      expect(
        counter.center.dy,
        moreOrLessEquals(box.center.dy, epsilon: _wi82Px),
      );
      expect(counter.left - field.right, moreOrLessEquals(8, epsilon: _wi82Px));
    },
    variant: macOnly,
  );

  final table = <(String, double, String, List<FindSource>?, int?, double, String?, bool)>[
    (
      'at body 532 the field is 198 px beside the full counter 2 of 12',
      532,
      wi82Word,
      null,
      1,
      198,
      '2 of 12',
      true,
    ),
    (
      'at body 324 the field is 126 px beside the full counter 2 of 12',
      324,
      wi82Word,
      null,
      1,
      126,
      '2 of 12',
      true,
    ),
    (
      'at body 264 the field is at its 96 px floor beside the short counter 2/12',
      264,
      wi82Word,
      null,
      1,
      96,
      '2/12',
      true,
    ),
    (
      'at body 192 the field is 70 px with the counter and the magnifier gone',
      192,
      wi82Word,
      null,
      1,
      70,
      null,
      false,
    ),
    (
      'at body 263 the 239 px box drops the counter and the magnifier and the field is 141 px',
      263,
      wi82Word,
      null,
      1,
      141,
      null,
      false,
    ),
    (
      'at body 532 the No matches counter is 66 px wide and the field gives up 2 px',
      532,
      'zzz',
      null,
      null,
      196,
      'No matches',
      true,
    ),
    (
      'at body 532 the large count 1 of 2,431 is 66 px wide and the field gives up 2 px',
      532,
      'x',
      wi82Many(2431),
      0,
      196,
      '1 of 2,431',
      true,
    ),
    (
      'at body 264 the short form 1/2,431 would push the field under 96 px so the counter hides and the field takes its slot',
      264,
      'x',
      wi82Many(2431),
      0,
      142,
      null,
      true,
    ),
    (
      'at body 264 a query with no matches reads None in the short slot beside a 96 px field',
      264,
      'zzz',
      null,
      null,
      96,
      'None',
      true,
    ),
  ];
  for (final (name, body, query, sources, current, field, counter, magnifier)
      in table) {
    testWidgets(name, (tester) async {
      await wi82Pump(
        tester,
        bodyWidth: body,
        query: query,
        sources: sources,
        current: current,
      );
      if (counter == null) {
        expect(wi82CounterHidden(tester), isTrue);
      } else {
        expect(wi82CounterText(tester), counter);
      }
      expect(wi82Magnifier, magnifier ? findsOneWidget : findsNothing);
      expect(
        tester.getSize(wi82Field).width,
        moreOrLessEquals(field, epsilon: _wi82Px),
      );
      _wi82ButtonsInside(tester);
    }, variant: macOnly);
  }

  testWidgets(
    'at body 264 the counter reads 2/12 and at body 192 the counter and the magnifier are gone while up, down and close remain',
    (tester) async {
      await wi82Pump(tester, bodyWidth: 264, current: 1);
      expect(wi82CounterText(tester), '2/12');
      expect(wi82Magnifier, findsOneWidget);
      _wi82ButtonsInside(tester);

      await wi82Pump(tester, bodyWidth: 192, current: 1);
      expect(wi82CounterHidden(tester), isTrue);
      expect(wi82Magnifier, findsNothing);
      _wi82ButtonsInside(tester);
    },
    variant: macOnly,
  );

  testWidgets(
    'at a 168 px box the field is at least the 70 px of design B4.4 and while the counter shows the field is never under 96 px',
    (tester) async {
      await wi82Pump(tester, bodyWidth: 192, current: 1);
      expect(
        tester.getSize(wi82Field).width,
        greaterThanOrEqualTo(70 - _wi82Px),
      );

      final bodies = <double>[
        264,
        265,
        280,
        300,
        323,
        324,
        330,
        360,
        396,
        420,
        532,
      ];
      final seeds = <(String, List<FindSource>?, int?)>[
        (wi82Word, null, 1),
        ('zzz', null, null),
        ('x', wi82Many(2431), 0),
      ];
      for (final body in bodies) {
        for (final (query, sources, current) in seeds) {
          await wi82Pump(
            tester,
            bodyWidth: body,
            query: query,
            sources: sources,
            current: current,
          );
          final why = 'body $body, query $query';
          if (!wi82CounterHidden(tester)) {
            expect(
              tester.getSize(wi82Field).width,
              greaterThanOrEqualTo(96 - _wi82Px),
              reason: why,
            );
          }
          _wi82ButtonsInside(tester);
        }
      }
    },
    variant: macOnly,
  );

  testWidgets(
    'an empty query shows no counter text and keeps the counter slot so the field is as wide as beside a counter',
    (tester) async {
      await wi82Pump(tester, query: '');
      expect(wi82CounterHidden(tester), isTrue);
      final emptyField = tester.getSize(wi82Field).width;
      final emptyPrevious = tester.getRect(wi82Previous).left;

      await wi82Pump(tester, current: 2);
      expect(wi82CounterText(tester), '3 of 12');
      expect(emptyField, moreOrLessEquals(198, epsilon: _wi82Px));
      expect(
        emptyField,
        moreOrLessEquals(tester.getSize(wi82Field).width, epsilon: 0.01),
      );
      expect(
        emptyPrevious,
        moreOrLessEquals(tester.getRect(wi82Previous).left, epsilon: 0.01),
      );
    },
    variant: macOnly,
  );

  testWidgets('a long query never grows the box or the field', (tester) async {
    final long = List.filled(8, wi82Word).join(' ');
    await wi82Pump(tester, query: long);
    expect(tester.getSize(wi82Box).width, moreOrLessEquals(372, epsilon: 0.01));
    expect(wi82CounterText(tester), 'No matches');
    expect(
      tester.getSize(wi82Field).width,
      moreOrLessEquals(196, epsilon: _wi82Px),
    );
    expect(tester.takeException(), isNull);
  }, variant: macOnly);
}
