// WI #85 verify: pins the FindSourceController contracts the editor tests do
// not reach (Reqs 24-25, TD3): the fg1 lift of another match, no ink while
// composing, range clamping, and the repaint notification.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/find_decoration.dart';
import 'package:open_memex_app/src/widgets/find/find_source_controller.dart';

import '../../support/font_fetch_hold.dart';

Future<TextSpan> _span(
  WidgetTester tester,
  FindSourceController c, {
  TextStyle? style,
  bool withComposing = false,
}) async {
  late TextSpan out;
  await tester.pumpWidget(
    Builder(
      builder: (context) {
        out = c.buildTextSpan(
          context: context,
          style: style,
          withComposing: withComposing,
        );
        return const SizedBox();
      },
    ),
  );
  return out;
}

Color? _colorAt(TextSpan span, int offset) {
  var i = 0;
  for (final child in span.children ?? const <InlineSpan>[]) {
    final t = child as TextSpan;
    final len = t.text!.length;
    if (offset < i + len) return t.style?.color ?? span.style?.color;
    i += len;
  }
  return null;
}

void main() {
  holdFontFetches();

  const base = TextStyle(color: OmColors.fg2);

  testWidgets('another match lifts fg2 fg3 and info text to fg1', (
    tester,
  ) async {
    for (final from in [OmColors.fg2, OmColors.fg3, OmColors.info]) {
      final c = FindSourceController(text: 'ab cd ef');
      c.find = const FindDecoration(inkRanges: [TextRange(start: 3, end: 5)]);
      final span = await _span(tester, c, style: TextStyle(color: from));
      expect(_colorAt(span, 3), OmColors.fg1);
      expect(_colorAt(span, 4), OmColors.fg1);
      expect(_colorAt(span, 2), from);
      expect(_colorAt(span, 5), from);
    }
  });

  testWidgets('another match keeps a colour outside the lifted set', (
    tester,
  ) async {
    final c = FindSourceController(text: 'ab cd ef');
    c.find = const FindDecoration(inkRanges: [TextRange(start: 3, end: 5)]);
    final span = await _span(
      tester,
      c,
      style: const TextStyle(color: OmColors.fg1),
    );
    expect(_colorAt(span, 3), OmColors.fg1);
    expect(span.children!.length, 3);
    // A colour not in the lifted set is left as the field draws it.
    final other = await _span(
      tester,
      c,
      style: const TextStyle(color: Color(0xFF123456)),
    );
    expect(_colorAt(other, 3), const Color(0xFF123456));
  });

  testWidgets('the current match draws surface0 and others stay lifted', (
    tester,
  ) async {
    final c = FindSourceController(text: 'ab cd ef');
    c.find = const FindDecoration(
      inkRanges: [TextRange(start: 0, end: 2), TextRange(start: 6, end: 8)],
      current: TextRange(start: 6, end: 8),
    );
    final span = await _span(tester, c, style: base);
    expect(_colorAt(span, 0), OmColors.fg1);
    expect(_colorAt(span, 1), OmColors.fg1);
    expect(_colorAt(span, 6), OmColors.surface0);
    expect(_colorAt(span, 7), OmColors.surface0);
    expect(_colorAt(span, 3), OmColors.fg2);
  });

  testWidgets('no ink is drawn while the field composes', (tester) async {
    final c = FindSourceController(text: 'ab cd ef');
    c.value = const TextEditingValue(
      text: 'ab cd ef',
      composing: TextRange(start: 3, end: 5),
    );
    c.find = const FindDecoration(
      inkRanges: [TextRange(start: 3, end: 5)],
      current: TextRange(start: 3, end: 5),
    );
    final composing = await _span(tester, c, style: base, withComposing: true);
    expect(_colorAt(composing, 3), isNot(OmColors.surface0));
    expect(_colorAt(composing, 3), isNot(OmColors.fg1));
    // Without the composing flag the same value draws ink.
    final plain = await _span(tester, c, style: base, withComposing: false);
    expect(_colorAt(plain, 3), OmColors.surface0);
  });

  testWidgets('no find or an empty field draws the plain span', (tester) async {
    final c = FindSourceController(text: 'ab cd');
    final none = await _span(tester, c, style: base);
    expect(none.toPlainText(), 'ab cd');
    c.find = const FindDecoration(inkRanges: [TextRange(start: 0, end: 2)]);
    c.text = '';
    final empty = await _span(tester, c, style: base);
    expect(empty.toPlainText(), '');
  });

  testWidgets('ranges past the text are clamped and never throw', (
    tester,
  ) async {
    final c = FindSourceController(text: 'ab cd');
    c.find = const FindDecoration(
      inkRanges: [TextRange(start: 3, end: 40)],
      current: TextRange(start: 3, end: 40),
    );
    final span = await _span(tester, c, style: base);
    expect(span.toPlainText(), 'ab cd');
    expect(_colorAt(span, 4), OmColors.surface0);
    expect(_colorAt(span, 2), OmColors.fg2);
  });

  test('setting find notifies once per change and never edits the text', () {
    final c = FindSourceController(text: 'ab cd');
    c.selection = const TextSelection(baseOffset: 1, extentOffset: 3);
    var calls = 0;
    c.addListener(() => calls++);
    const a = FindDecoration(inkRanges: [TextRange(start: 0, end: 2)]);
    c.find = a;
    expect(calls, 1);
    c.find = const FindDecoration(inkRanges: [TextRange(start: 0, end: 2)]);
    expect(calls, 1, reason: 'an equal decoration does not repaint');
    c.find = null;
    expect(calls, 2);
    expect(c.find, isNull);
    expect(c.text, 'ab cd');
    expect(c.selection, const TextSelection(baseOffset: 1, extentOffset: 3));
  });
}
