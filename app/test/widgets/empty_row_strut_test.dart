// Follow-up to WI #167 (D22): `TextSegmentField` lays an EMPTY prose field
// out one prose line (22.95 px) tall by forcing the controller's strut while
// the text is empty. These tests pin what the host-level height tests do not:
// the flip in both directions as the text is typed and cleared, headings
// staying taller than a line once non-empty, code rows keeping their own
// strut, and a plain controller keeping the field default.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

const double _line = 22.95;
const _fieldKey = Key('wi167-empty-field');

Future<void> _pump(
  WidgetTester tester,
  TextEditingController controller,
) async {
  final chips = KindChipHost();
  addTearDown(chips.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(44, 37, 44, 0),
            child: TextSegmentField(
              key: _fieldKey,
              controller: controller,
              kindChips: chips,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

EditableText _editable(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText));

RenderEditable _render(WidgetTester tester) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  visit(tester.renderObject(find.byKey(_fieldKey)));
  return found!;
}

void main() {
  group('empty prose field strut (D22)', () {
    testWidgets(
      'an empty live preview field is one prose line tall and its strut is forced',
      (tester) async {
        final controller = LivePreviewController();
        addTearDown(controller.dispose);
        await _pump(tester, controller);

        expect(
          _render(tester).size.height,
          moreOrLessEquals(_line, epsilon: 0.1),
        );
        expect(_editable(tester).strutStyle.forceStrutHeight, isTrue);
      },
    );

    testWidgets(
      'typing the first character keeps the row one prose line tall and lifts the forced strut',
      (tester) async {
        final controller = LivePreviewController();
        addTearDown(controller.dispose);
        await _pump(tester, controller);

        await tester.showKeyboard(find.byKey(_fieldKey));
        tester.testTextInput.enterText('x');
        await tester.pump();

        expect(controller.text, 'x');
        expect(
          _render(tester).size.height,
          moreOrLessEquals(_line, epsilon: 0.1),
        );
        expect(_editable(tester).strutStyle.forceStrutHeight, isNot(true));
      },
    );

    testWidgets(
      'a heading typed into an empty field lays out taller than a prose line',
      (tester) async {
        final controller = LivePreviewController();
        addTearDown(controller.dispose);
        await _pump(tester, controller);

        await tester.showKeyboard(find.byKey(_fieldKey));
        tester.testTextInput.enterText('# Big title');
        await tester.pump();

        expect(_render(tester).size.height, greaterThan(_line + 1));
      },
    );

    testWidgets(
      'clearing the text back to empty returns to one prose line with the forced strut',
      (tester) async {
        final controller = LivePreviewController(text: '# Big title');
        addTearDown(controller.dispose);
        await _pump(tester, controller);
        expect(_render(tester).size.height, greaterThan(_line + 1));
        expect(_editable(tester).strutStyle.forceStrutHeight, isNot(true));

        await tester.showKeyboard(find.byKey(_fieldKey));
        tester.testTextInput.enterText('');
        await tester.pump();

        expect(controller.text, isEmpty);
        expect(
          _render(tester).size.height,
          moreOrLessEquals(_line, epsilon: 0.1),
        );
        expect(_editable(tester).strutStyle.forceStrutHeight, isTrue);
      },
    );

    testWidgets('a non-empty prose field keeps the controller strut unforced', (
      tester,
    ) async {
      final controller = LivePreviewController(text: 'x');
      addTearDown(controller.dispose);
      await _pump(tester, controller);

      expect(_editable(tester).strutStyle.forceStrutHeight, isNot(true));
      expect(
        _render(tester).size.height,
        moreOrLessEquals(_line, epsilon: 0.1),
      );
    });

    testWidgets(
      'an empty code row keeps its own strut and is not forced to a prose line',
      (tester) async {
        final controller = LivePreviewController()..codeRow = true;
        addTearDown(controller.dispose);
        await _pump(tester, controller);

        final strut = _editable(tester).strutStyle;
        expect(strut.forceStrutHeight, isNot(true));
        expect(strut.fontSize, controller.strutStyle?.fontSize);
        expect(strut.height, controller.strutStyle?.height);
      },
    );

    testWidgets('a plain controller keeps one strut whether empty or not', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await _pump(tester, controller);
      final empty = _editable(tester).strutStyle;

      await tester.showKeyboard(find.byKey(_fieldKey));
      tester.testTextInput.enterText('x');
      await tester.pump();

      expect(_editable(tester).strutStyle, empty);
    });
  });
}
