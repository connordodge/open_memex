// WI #80 (Spec #61 F1): the Find bar width and counter rules (Reqs 10, 29,
// 30, 32-34) as pure functions. Box widths are design B4 (packs/82.md).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';

String? _text(
  int? current,
  int total,
  FindCounterForm form, {
  String q = 'x',
}) => findCounterText(current: current, total: total, query: q, form: form);

void main() {
  group('findBoxWidth (Req 30)', () {
    test(
      'findBoxWidth gives 372 at 532, 300 at 324, 240 at 264 and 168 at 192',
      () {
        expect(findBoxWidth(532), 372);
        expect(findBoxWidth(324), 300);
        expect(findBoxWidth(264), 240);
        expect(findBoxWidth(192), 168);
      },
    );

    test('findBoxWidth caps at 372 from a 396 px body', () {
      expect(findBoxWidth(395), 371);
      expect(findBoxWidth(396), 372);
      expect(findBoxWidth(397), 372);
      expect(findBoxWidth(1120), 372);
    });
  });

  group('findCounterText (Reqs 10, 29, 32)', () {
    test('findCounterText gives the full short and empty query forms', () {
      expect(_text(2, 12, FindCounterForm.full), '3 of 12');
      expect(_text(0, 2431, FindCounterForm.full), '1 of 2,431');
      expect(_text(null, 0, FindCounterForm.full), 'No matches');
      expect(_text(2, 12, FindCounterForm.short), '3/12');
      expect(_text(null, 0, FindCounterForm.short), 'None');
      expect(_text(null, 0, FindCounterForm.full, q: ''), isNull);
      expect(_text(null, 0, FindCounterForm.short, q: ''), isNull);
    });

    test('findCounterText puts thousands separators on both numbers', () {
      expect(_text(1233, 2431, FindCounterForm.full), '1,234 of 2,431');
      expect(_text(998, 1000, FindCounterForm.full), '999 of 1,000');
      expect(_text(999, 1234567, FindCounterForm.short), '1,000/1,234,567');
      expect(_text(0, 1, FindCounterForm.full), '1 of 1');
    });

    test('findCounterText gives null for the hidden form', () {
      expect(_text(2, 12, FindCounterForm.hidden), isNull);
      expect(_text(null, 0, FindCounterForm.hidden), isNull);
      // A spaces only query is not empty.
      expect(_text(0, 3, FindCounterForm.full, q: ' '), '1 of 3');
    });
  });

  group('findCounterForm (Req 32)', () {
    FindCounterForm form(double box, double shortText) =>
        findCounterForm(boxWidth: box, shortTextWidth: shortText);

    test(
      'findCounterForm gives full at 300 short at 299 and 240 and hidden at 239',
      () {
        expect(form(300, 24), FindCounterForm.full);
        expect(form(299, 24), FindCounterForm.short);
        expect(form(240, 24), FindCounterForm.short);
        expect(form(239, 24), FindCounterForm.hidden);
      },
    );

    test(
      'findCounterForm hides a short text wider than 34 px at a 260 px box',
      () {
        expect(form(260, 60), FindCounterForm.hidden);
      },
    );

    test('findCounterForm keeps the short form for a 34 px short text', () {
      expect(form(260, 34), FindCounterForm.short);
      expect(form(240, 34), FindCounterForm.short);
      // At the 240 floor box any short text past 34 px pushes the field under
      // 96 px.
      expect(form(240, 34.5), FindCounterForm.hidden);
    });

    test(
      'findCounterForm keeps the full form whatever the short text width',
      () {
        expect(form(300, 60), FindCounterForm.full);
        expect(form(372, 66), FindCounterForm.full);
        expect(form(239, 0), FindCounterForm.hidden);
      },
    );
  });

  group('findSemanticsValue (Req 34)', () {
    test('findSemanticsValue is always the full form', () {
      expect(findSemanticsValue(current: 2, total: 12, query: 'x'), '3 of 12');
      expect(
        findSemanticsValue(current: 0, total: 2431, query: 'x'),
        '1 of 2,431',
      );
      expect(
        findSemanticsValue(current: null, total: 0, query: 'x'),
        'No matches',
      );
      // The same text as the full counter, at any counter form.
      for (final box in [372.0, 260.0, 168.0]) {
        final shown = findCounterForm(boxWidth: box, shortTextWidth: 40);
        expect(
          findSemanticsValue(current: 2, total: 12, query: 'x'),
          findCounterText(
            current: 2,
            total: 12,
            query: 'x',
            form: FindCounterForm.full,
          ),
          reason: 'box $box shows $shown',
        );
      }
      expect(findSemanticsValue(current: null, total: 0, query: ''), '');
    });
  });
}
