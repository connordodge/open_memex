// WI #84 (#61 F4, ruling D7; Spec #61 Reqs 24, 25, 27, TD3, Testing
// Strategy "Spans"): the one find input of a live preview field.
//
// - `FindDecoration` {revealRange, inkRanges, current}: value equality.
// - `LivePreviewController.findDecoration`: an optional listenable, null = no
//   decoration; each fire notifies the controller once.
// - `revealedLines(revealRange:)`: the lines a find range touches reveal even
//   while `forceHidden`, by the selection's fence and table rules.
// - Ink (design pack design/55-find-in-note/packs/84.md): inside a match
//   that is not current, text that would draw in fg2, fg3 or info draws in
//   fg1; inside the current match every run draws in surface0; weight, size
//   and underline never change; outside the ranges nothing changes.
// - `buildLivePreviewSpan(inkRanges:, current:)` for card rows and table grid
//   cells, which never reveal.
//
// Styles are read the way the engine paints them: a code unit's effective
// style is its ancestors' styles merged down to its leaf. Widths come from a
// pumped field's own line boxes (theme even leading), never constants.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/markdown_lines.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/find_decoration.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart';

import '../../support/font_fetch_hold.dart';

/// The editor body style every live preview field passes as its base
/// (`_bodyStyle` in text_segment.dart: mono 13.5, fg0, height 1.7).
TextStyle _base() => OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);

TextSelection _caret(int offset) => TextSelection.collapsed(offset: offset);

/// `[start, end)` of the [nth] occurrence of [needle] in [text], built at
/// run time.
TextRange _range(String text, String needle, {int nth = 0}) {
  var at = -1;
  for (var i = 0; i <= nth; i++) {
    at = text.indexOf(needle, at + 1);
    expect(at, isNonNegative, reason: 'fixture holds "$needle" #$i');
  }
  return TextRange(start: at, end: at + needle.length);
}

/// The range from the first [from] to the end of the first [to] after it.
TextRange _span(String text, String from, String to) {
  final start = text.indexOf(from);
  final end = text.indexOf(to, start) + to.length;
  expect(start, isNonNegative, reason: 'fixture holds "$from"');
  expect(end, greaterThan(start), reason: 'fixture holds "$to" after it');
  return TextRange(start: start, end: end);
}

/// Builds through the pure builder with the body base style.
TextSpan _build(
  String text, {
  TextSelection? selection,
  bool forceHidden = false,
  bool itemText = false,
  bool taskDone = false,
  bool Function(String target)? isResolved,
  int? before,
  List<bool>? fenced,
  List<TextRange> inkRanges = const <TextRange>[],
  TextRange? current,
}) => buildLivePreviewSpan(
  text,
  style: _base(),
  selection: selection,
  forceHidden: forceHidden,
  itemText: itemText,
  taskDone: taskDone,
  isResolved: isResolved,
  before: before,
  fenced: fenced,
  inkRanges: inkRanges,
  current: current,
);

/// The effective style of the code unit at [offset]: every ancestor's style
/// merged down to the leaf holding it, as the engine inherits styles.
TextStyle _styleAt(InlineSpan root, int offset) {
  TextStyle? found;
  var pos = 0;
  bool visit(InlineSpan span, TextStyle? inherited) {
    final own = span.style;
    final style = inherited == null
        ? own
        : (own == null ? inherited : inherited.merge(own));
    final textSpan = span as TextSpan;
    final t = textSpan.text ?? '';
    if (offset >= pos && offset < pos + t.length) {
      found = style ?? const TextStyle();
      return false;
    }
    pos += t.length;
    for (final child in textSpan.children ?? const <InlineSpan>[]) {
      if (!visit(child, style)) return false;
    }
    return true;
  }

  visit(root, null);
  expect(found, isNotNull, reason: 'a style covers offset $offset');
  return found!;
}

Color? _colourAt(InlineSpan root, int offset) => _styleAt(root, offset).color;

/// Expects every code unit of [range] to draw in [colour].
void _expectColour(
  InlineSpan root,
  TextRange range,
  Color colour,
  String reason,
) {
  for (var at = range.start; at < range.end; at++) {
    expect(_colourAt(root, at), colour, reason: '$reason (offset $at)');
  }
}

/// Whether the code unit at [offset] renders as a hidden (zero-width)
/// marker.
bool _hiddenAt(InlineSpan root, int offset) =>
    _styleAt(root, offset).fontSize == 0;

bool _underlined(TextStyle s) =>
    s.decoration?.contains(TextDecoration.underline) ?? false;

FontWeight _weight(TextStyle s) => s.fontWeight ?? FontWeight.w400;

/// The controller's own span, as its field builds it.
TextSpan _controllerSpan(BuildContext context, LivePreviewController c) =>
    c.buildTextSpan(context: context, style: _base(), withComposing: false);

/// A build context for [LivePreviewController.buildTextSpan].
Future<BuildContext> _context(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  return tester.element(find.byType(SizedBox));
}

/// A listenable that counts who listens to it, so a test sees the
/// controller subscribe, swap and unsubscribe.
final class _Wi84CountingListenable extends ChangeNotifier
    implements ValueListenable<FindDecoration?> {
  FindDecoration? _value;
  int listeners = 0;

  @override
  FindDecoration? get value => _value;
  set value(FindDecoration? v) {
    _value = v;
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    super.removeListener(listener);
  }
}

/// The span fixtures the null decoration must leave unchanged: one per line
/// kind the builder styles (AC1).
const List<(String, String)> _wi84Fixtures = [
  (
    'with no find decoration the link fixture spans are identical to the spans without it',
    'Read [docs](https://x.y) and [[Known]] now\nnext line',
  ),
  (
    'with no find decoration the bold fixture spans are identical to the spans without it',
    'A **bold** and *slant* word\nnext line',
  ),
  (
    'with no find decoration the heading fixture spans are identical to the spans without it',
    '## Plan [[Known]] here\n#### Small\nbody',
  ),
  (
    'with no find decoration the task fixture spans are identical to the spans without it',
    '- [ ] Item ~~old~~ #tag\nnext line',
  ),
  (
    'with no find decoration the table fixture spans are identical to the spans without it',
    '| a | `b` |\n|---|---|\n| [x](u) | ~~y~~ |\nafter',
  ),
  (
    'with no find decoration the code fence fixture spans are identical to the spans without it',
    '```\nlet a = 1;\n```\nafter',
  ),
];

/// A pumped unfocused live preview [TextField] (the theme's even leading)
/// holding [text], wide enough that no line wraps.
final class _Wi84Field {
  _Wi84Field(this.controller, this.key);

  final LivePreviewController controller;
  final GlobalKey key;

  RenderEditable get editable =>
      findRenderEditable(key.currentContext!.findRenderObject())!;

  LineBoxSource get boxes => RenderEditableLineBoxes(editable);

  InlineSpan get span => editable.text!;

  /// The laid-out width of `[start, end)` on one line.
  double width(int start, int end) =>
      boxes.caretRect(end).left - boxes.caretRect(start).left;
}

Future<_Wi84Field> _wi84PumpField(WidgetTester tester, String text) async {
  tester.view.physicalSize = const Size(2400, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = LivePreviewController(text: text);
  addTearDown(controller.dispose);
  final key = GlobalKey(debugLabel: 'wi84-field');
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 2000,
            child: TextField(
              key: key,
              controller: controller,
              style: _base(),
              strutStyle: controller.strutStyle,
              maxLines: null,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Wi84Field(controller, key);
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // FindDecoration
  // -------------------------------------------------------------------------
  group('FindDecoration', () {
    test('FindDecoration has value equality over every field', () {
      const text = 'Further hydration and more hydration';
      final first = _range(text, 'hydration');
      final second = _range(text, 'hydration', nth: 1);
      final other = _range(text, 'more');
      FindDecoration make({
        TextRange? reveal,
        List<TextRange>? ink,
        TextRange? current,
      }) => FindDecoration(
        revealRange: reveal ?? first,
        inkRanges: ink ?? [first, second],
        current: current ?? first,
      );

      final a = make();
      final b = make(ink: List.of([first, second]));
      expect(a == b, isTrue, reason: 'equal fields, distinct lists');
      expect(a.hashCode, b.hashCode);
      expect(a == make(reveal: other), isFalse, reason: 'revealRange differs');
      expect(a == make(current: second), isFalse, reason: 'current differs');
      expect(a == make(ink: [first]), isFalse, reason: 'fewer ink ranges');
      expect(a == make(ink: [second, first]), isFalse, reason: 'ink order');
      expect(a == make(ink: [first, other]), isFalse, reason: 'ink element');
      expect(
        FindDecoration(inkRanges: [first]) ==
            FindDecoration(revealRange: first, inkRanges: [first]),
        isFalse,
        reason: 'a null revealRange differs from a set one',
      );
      expect(
        FindDecoration(inkRanges: [first]) ==
            FindDecoration(inkRanges: [first], current: first),
        isFalse,
        reason: 'a null current differs from a set one',
      );
      final empty = FindDecoration(revealRange: other);
      expect(empty.inkRanges, isEmpty, reason: 'inkRanges defaults to empty');
      expect(empty.current, isNull);
    });

    test(
      'setting an equal find decoration on a ValueNotifier does not notify the controller',
      () {
        const text = 'one hydration two';
        final c = LivePreviewController(text: text);
        addTearDown(c.dispose);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        c.findDecoration = n;
        var notified = 0;
        c.addListener(() => notified++);
        final r = _range(text, 'hydration');
        n.value = FindDecoration(revealRange: r, inkRanges: [r], current: r);
        expect(notified, 1);
        n.value = FindDecoration(
          revealRange: TextRange(start: r.start, end: r.end),
          inkRanges: [TextRange(start: r.start, end: r.end)],
          current: TextRange(start: r.start, end: r.end),
        );
        expect(notified, 1, reason: 'an equal decoration is no change');
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC1: a null decoration leaves every span unchanged
  // -------------------------------------------------------------------------
  group('null decoration', () {
    for (final (name, text) in _wi84Fixtures) {
      testWidgets(name, (tester) async {
        final context = await _context(tester);
        for (final focused in [false, true]) {
          final how = focused ? 'focused' : 'unfocused';
          final c = LivePreviewController(text: text)
            ..selection = _caret(0)
            ..revealGate = AlwaysStoppedAnimation<bool>(focused);
          addTearDown(c.dispose);
          final expected = buildLivePreviewSpan(
            text,
            style: _base(),
            selection: _caret(0),
            forceHidden: !focused,
          );

          expect(c.findDecoration, isNull, reason: '$how: null by default');
          expect(
            _controllerSpan(context, c),
            expected,
            reason: '$how: no listenable',
          );
          expect(
            buildLivePreviewSpan(
              text,
              style: _base(),
              selection: _caret(0),
              forceHidden: !focused,
              inkRanges: const <TextRange>[],
              current: null,
            ),
            expected,
            reason: '$how: no ink ranges and no current',
          );

          final n = ValueNotifier<FindDecoration?>(null);
          addTearDown(n.dispose);
          c.findDecoration = n;
          expect(
            _controllerSpan(context, c),
            expected,
            reason: '$how: a listenable holding null',
          );

          // The listenable is read live: a decoration changes the spans...
          final whole = TextRange(start: 0, end: text.length);
          n.value = FindDecoration(inkRanges: [whole], current: whole);
          expect(
            _controllerSpan(context, c),
            isNot(expected),
            reason: '$how: a decoration over the whole text',
          );

          // ...and going back to null restores them exactly.
          n.value = null;
          expect(
            _controllerSpan(context, c),
            expected,
            reason: '$how: the listenable back to null',
          );

          c.findDecoration = null;
          expect(
            _controllerSpan(context, c),
            expected,
            reason: '$how: the listenable removed',
          );
        }
      });
    }
  });

  // -------------------------------------------------------------------------
  // AC2: the listenable notifies the controller once per fire
  // -------------------------------------------------------------------------
  group('find decoration listenable', () {
    test(
      'firing the find decoration listenable notifies the controller listeners exactly once',
      () {
        const text = 'one hydration two';
        final c = LivePreviewController(text: text);
        addTearDown(c.dispose);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        c.findDecoration = n;
        var notified = 0;
        c.addListener(() => notified++);

        final r = _range(text, 'hydration');
        n.value = FindDecoration(inkRanges: [r], current: r);
        expect(notified, 1, reason: 'a decoration arrives');
        n.value = FindDecoration(revealRange: r, inkRanges: [r]);
        expect(notified, 2, reason: 'the decoration changes');
        n.value = null;
        expect(notified, 3, reason: 'the decoration clears');
        expect(c.text, text, reason: 'the text is untouched');
      },
    );

    test(
      'setting the same find decoration listenable twice still notifies exactly once per fire',
      () {
        final c = LivePreviewController(text: 'abc');
        addTearDown(c.dispose);
        final n = _Wi84CountingListenable();
        addTearDown(n.dispose);
        c.findDecoration = n;
        c.findDecoration = n;
        expect(n.listeners, 1, reason: 'one subscription');
        var notified = 0;
        c.addListener(() => notified++);
        n.value = const FindDecoration(
          inkRanges: [TextRange(start: 0, end: 1)],
        );
        expect(notified, 1);
      },
    );

    test(
      'a replaced find decoration listenable no longer notifies the controller and the new one does',
      () {
        final c = LivePreviewController(text: 'abc');
        addTearDown(c.dispose);
        final first = _Wi84CountingListenable();
        final second = _Wi84CountingListenable();
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        c.findDecoration = first;
        expect(first.listeners, 1, reason: 'subscribed to the first');
        c.findDecoration = second;
        expect(first.listeners, 0, reason: 'unsubscribed from the first');
        expect(second.listeners, 1, reason: 'subscribed to the second');
        expect(c.findDecoration, same(second));

        var notified = 0;
        c.addListener(() => notified++);
        first.value = const FindDecoration(
          inkRanges: [TextRange(start: 0, end: 1)],
        );
        expect(notified, 0, reason: 'the old listenable fired');
        second.value = const FindDecoration(
          inkRanges: [TextRange(start: 1, end: 2)],
        );
        expect(notified, 1, reason: 'the new listenable fired');

        c.findDecoration = null;
        expect(second.listeners, 0, reason: 'null unsubscribes');
        second.value = null;
        expect(notified, 1, reason: 'no listenable: nothing notifies');
      },
    );

    test(
      'a disposed controller stops listening to its find decoration listenable',
      () {
        final c = LivePreviewController(text: 'abc');
        final n = _Wi84CountingListenable();
        addTearDown(n.dispose);
        c.findDecoration = n;
        expect(n.listeners, 1);
        c.dispose();
        expect(n.listeners, 0, reason: 'dispose unsubscribes');
        expect(
          () => n.value = const FindDecoration(
            inkRanges: [TextRange(start: 0, end: 1)],
          ),
          returnsNormally,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3, AC4: revealedLines with a reveal range
  // -------------------------------------------------------------------------
  group('revealedLines with a reveal range', () {
    List<bool> revealed(
      String text, {
      TextSelection? selection,
      TextRange? range,
      bool forceHidden = false,
      bool itemText = false,
    }) => revealedLines(
      classifyLines(text, atSegmentStart: true),
      selection,
      forceHidden: forceHidden,
      itemText: itemText,
      revealRange: range,
    );

    test(
      'revealedLines with a range touching line 2 and forceHidden reveals that line only and a null range reveals nothing',
      () {
        const text = 'One **a** x\nTwo **b** y\nThree **c** z';
        final r = _range(text, 'b');
        expect(revealed(text, range: r, forceHidden: true), [
          false,
          true,
          false,
        ], reason: 'no selection');
        expect(
          revealed(text, selection: _caret(0), range: r, forceHidden: true),
          [false, true, false],
          reason: 'a selection while forceHidden still reveals nothing',
        );
        expect(revealed(text, forceHidden: true), [
          false,
          false,
          false,
        ], reason: 'null range, forceHidden');
        expect(revealed(text, selection: _caret(0), forceHidden: true), [
          false,
          false,
          false,
        ], reason: 'null range, a selection, forceHidden: as today');
        expect(revealed(text), [
          false,
          false,
          false,
        ], reason: 'null range, no selection: as today');
      },
    );

    test(
      'a reveal range touches a line from its start through its content end and no line beyond',
      () {
        const text = 'One **a** x\nTwo **b** y\nThree **c** z';
        final lines = classifyLines(text, atSegmentStart: true);
        final second = lines[1];
        expect(
          revealed(
            text,
            range: TextRange(
              start: second.contentEnd - 1,
              end: second.contentEnd,
            ),
            forceHidden: true,
          ),
          [false, true, false],
          reason: 'a range ending at the line content end',
        );
        expect(
          revealed(
            text,
            range: TextRange(start: second.start, end: second.start + 3),
            forceHidden: true,
          ),
          [false, true, false],
          reason: 'a range starting at the line start',
        );
        expect(
          revealed(
            text,
            range: const TextRange(start: 0, end: 3),
            forceHidden: true,
          ),
          [true, false, false],
          reason: 'a range on the first line',
        );
        expect(
          revealed(
            text,
            range: TextRange(
              start: lines[2].contentEnd - 1,
              end: lines[2].contentEnd,
            ),
            forceHidden: true,
          ),
          [false, false, true],
          reason: 'a range ending at the text end',
        );
      },
    );

    test('a reveal range and a focused selection reveal the lines of both', () {
      const text = 'One **a** x\nTwo **b** y\nThree **c** z';
      expect(revealed(text, selection: _caret(0), range: _range(text, 'c')), [
        true,
        false,
        true,
      ]);
      expect(revealed(text, range: _range(text, 'c')), [
        false,
        false,
        true,
      ], reason: 'no selection, not forceHidden');
      expect(
        revealed(
          text,
          selection: const TextSelection.collapsed(offset: -1),
          range: _range(text, 'a'),
        ),
        [true, false, false],
        reason: 'an invalid selection reveals nothing of its own',
      );
    });

    test(
      'a reveal range touching one line of a fenced block reveals both fence lines as a selection there does',
      () {
        const text = 'intro\n```\nlet a = 1;\nlet b = 2;\n```\nafter';
        final r = _range(text, 'b = 2');
        const expected = [false, true, false, true, true, false];
        expect(revealed(text, range: r, forceHidden: true), expected);
        expect(
          revealed(
            text,
            selection: TextSelection(baseOffset: r.start, extentOffset: r.end),
          ),
          expected,
          reason: 'the same range as a selection',
        );
        expect(
          revealed(text, range: _range(text, 'after'), forceHidden: true),
          [false, false, false, false, false, true],
          reason: 'a range after the block leaves it hidden',
        );

        // An unclosed block reveals through its last line.
        const open = 'intro\n```\ncode\nmore';
        expect(revealed(open, range: _range(open, 'more'), forceHidden: true), [
          false,
          true,
          false,
          true,
        ]);
      },
    );

    test(
      'a reveal range touching a table line reveals every table line as a selection there does',
      () {
        const text = 'intro\n| a | b |\n|---|---|\n| c | d |\n| e | f |\nafter';
        final r = _range(text, 'f');
        const expected = [false, true, true, true, true, false];
        expect(revealed(text, range: r, forceHidden: true), expected);
        expect(
          revealed(
            text,
            selection: TextSelection(baseOffset: r.start, extentOffset: r.end),
          ),
          expected,
          reason: 'the same range as a selection',
        );
        expect(
          revealed(text, range: _range(text, 'intro'), forceHidden: true),
          [true, false, false, false, false, false],
          reason: 'a range before the table leaves it hidden',
        );
      },
    );

    test(
      'with itemText a reveal range reveals only the lines it touches and no block as a unit',
      () {
        const text = '```\nlet a = 1;\n```';
        expect(
          revealed(
            text,
            range: _range(text, 'a = 1'),
            forceHidden: true,
            itemText: true,
          ),
          [false, true, false],
        );
      },
    );

    test(
      'tableRevealed stays false for a find reveal range on an unfocused table row',
      () {
        const text = '| a | b |\n|---|---|\n| c | d |';
        final c = LivePreviewController(text: text)
          ..tableRow = true
          ..selection = _caret(0);
        addTearDown(c.dispose);
        final r = _range(text, 'd');
        final n = ValueNotifier<FindDecoration?>(
          FindDecoration(revealRange: r, inkRanges: [r], current: r),
        );
        addTearDown(n.dispose);
        c.findDecoration = n;
        expect(c.tableRevealed, isFalse);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4, AC5: the controller reveals the lines its find range touches
  // -------------------------------------------------------------------------
  group('find reveal in a field', () {
    testWidgets(
      'a link line with the reveal range on its URL shows its markup while unfocused and hides it once the range moves to another line',
      (tester) async {
        const text =
            'Further reading: [label](https://example.org/hydration-tables) and more.\n'
            'Second plain line';
        final f = await _wi84PumpField(tester, text);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        f.controller.findDecoration = n;
        final open = text.indexOf('[');
        final urlStart = text.indexOf('](');
        final urlEnd = text.indexOf(')') + 1;
        final url = TextRange(start: urlStart, end: urlEnd);
        final hydration = _range(text, 'hydration');
        final label = _range(text, 'label');

        void expectHidden(String reason) {
          expect(
            f.width(urlStart, urlEnd),
            closeTo(0, 0.01),
            reason: '$reason: the markup lays out zero-width',
          );
          for (var at = urlStart; at < urlEnd; at++) {
            expect(_hiddenAt(f.span, at), isTrue, reason: '$reason: $at');
          }
          expect(_hiddenAt(f.span, open), isTrue, reason: '$reason: [');
          expect(_colourAt(f.span, label.start), OmColors.info);
        }

        expect(f.controller.revealGate.value, isFalse, reason: 'unfocused');
        expectHidden('no decoration');

        n.value = FindDecoration(
          revealRange: hydration,
          inkRanges: [hydration],
          current: hydration,
        );
        await tester.pump();
        expect(
          f.width(urlStart, urlEnd),
          greaterThan(0),
          reason: 'the revealed markup takes its width',
        );
        expect(_hiddenAt(f.span, open), isFalse, reason: '[ shows');
        _expectColour(
          f.span,
          TextRange(start: urlStart, end: hydration.start),
          OmColors.fg2,
          'markup before the match: marker fg2',
        );
        _expectColour(
          f.span,
          TextRange(start: hydration.end, end: urlEnd),
          OmColors.fg2,
          'markup after the match: marker fg2',
        );
        _expectColour(f.span, hydration, OmColors.surface0, 'current match');
        _expectColour(f.span, label, OmColors.info, 'label outside the match');
        expect(_colourAt(f.span, open), OmColors.fg2, reason: '[ is fg2');
        expect(url.isValid, isTrue);

        // The range moves to the next line: the link line hides again.
        final second = _range(text, 'Second');
        n.value = FindDecoration(
          revealRange: second,
          inkRanges: [hydration, second],
          current: second,
        );
        await tester.pump();
        expectHidden('range on the next line');

        n.value = null;
        await tester.pump();
        expectHidden('decoration cleared');
      },
    );

    testWidgets(
      'after the find reveal range moves off a line the caret is on that line keeps its markup shown',
      (tester) async {
        final context = await _context(tester);
        const text = 'One **a** x\nTwo **b** y';
        final c = LivePreviewController(text: text)
          ..revealGate = const AlwaysStoppedAnimation<bool>(true)
          ..selection = _caret(0);
        addTearDown(c.dispose);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        c.findDecoration = n;
        final firstMarker = text.indexOf('**');
        final secondMarker = text.indexOf('**', text.indexOf('Two'));

        n.value = FindDecoration(revealRange: _range(text, 'b'));
        var span = _controllerSpan(context, c);
        expect(_hiddenAt(span, firstMarker), isFalse, reason: 'caret line');
        expect(_hiddenAt(span, secondMarker), isFalse, reason: 'range line');

        n.value = FindDecoration(revealRange: _range(text, 'a'));
        span = _controllerSpan(context, c);
        expect(_hiddenAt(span, firstMarker), isFalse, reason: 'caret line');
        expect(
          _hiddenAt(span, secondMarker),
          isTrue,
          reason: 'range moved off',
        );
      },
    );

    testWidgets(
      'the controller shows both fence lines of a code row its find reveal range touches while unfocused',
      (tester) async {
        final context = await _context(tester);
        const text = '```\nlet a = 1;\nlet b = 2;\n```';
        final c = LivePreviewController(text: text)..codeRow = true;
        addTearDown(c.dispose);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        c.findDecoration = n;
        final close = text.lastIndexOf('```');

        var span = _controllerSpan(context, c);
        expect(_hiddenAt(span, 0), isTrue, reason: 'no decoration: hidden');
        expect(_hiddenAt(span, close), isTrue);

        n.value = FindDecoration(revealRange: _range(text, 'b = 2'));
        span = _controllerSpan(context, c);
        for (final at in [0, 1, 2, close, close + 1, close + 2]) {
          expect(_hiddenAt(span, at), isFalse, reason: 'fence unit $at');
          expect(_colourAt(span, at), OmColors.fg2, reason: 'fence unit $at');
        }

        n.value = const FindDecoration();
        span = _controllerSpan(context, c);
        expect(_hiddenAt(span, 0), isTrue, reason: 'no reveal range: hidden');
        expect(_hiddenAt(span, close), isTrue);
      },
    );

    testWidgets(
      'the decorations outset a fenced code box the find reveal range touches while the segment is unfocused',
      (tester) async {
        const text = 'intro\n\n```\nlet a = 1;\nlet b = 2;\n```\n\nafter';
        final controller = LivePreviewController(text: text);
        addTearDown(controller.dispose);
        final n = ValueNotifier<FindDecoration?>(null);
        addTearDown(n.dispose);
        controller.findDecoration = n;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final editable = GlobalKey(debugLabel: 'wi84-decorated');
        LineBoxSource? boxes() {
          final e = findRenderEditable(
            editable.currentContext?.findRenderObject(),
          );
          return e == null ? null : RenderEditableLineBoxes(e);
        }

        await tester.pumpWidget(
          MaterialApp(
            theme: buildOmTheme(),
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: LivePreviewDecorations(
                    controller: controller,
                    boxes: boxes,
                    textLeft: 14,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: EditableText(
                        key: editable,
                        controller: controller,
                        focusNode: focus,
                        style: _base(),
                        strutStyle: controller.strutStyle,
                        cursorColor: OmColors.accent,
                        backgroundCursorColor: OmColors.surface2,
                        maxLines: null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        double codeBoxHeight() {
          double? height;
          expect(
            tester.renderObject(find.byType(LivePreviewDecorations)),
            paints..something((method, args) {
              if (method != #drawRRect) return false;
              final paint = args[1] as Paint;
              if (paint.style != PaintingStyle.fill ||
                  paint.color.toARGB32() != OmColors.surface1.toARGB32()) {
                return false;
              }
              height = (args[0] as RRect).height;
              return true;
            }),
          );
          expect(height, isNotNull, reason: 'the code box paints');
          return height!;
        }

        final rest = codeBoxHeight();

        n.value = FindDecoration(revealRange: _range(text, 'b = 2'));
        await tester.pump();
        expect(
          codeBoxHeight(),
          closeTo(rest + 16, 0.01),
          reason: 'revealed: 8 px above and below',
        );

        n.value = FindDecoration(revealRange: _range(text, 'after'));
        await tester.pump();
        expect(
          codeBoxHeight(),
          closeTo(rest, 0.01),
          reason: 'the range left the block',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC7: other matches lift fg2, fg3 and info text to fg1
  // -------------------------------------------------------------------------
  group('other match ink', () {
    test(
      'inside a non current ink range link text and revealed marker text draw in fg1 and outside they keep their own colours',
      () {
        const text = 'A [docs](https://x.y) and [more](https://z.w) end';
        final ink = _span(text, '[docs', 'https://x');
        // A caret at 0 reveals the line and selects nothing.
        final span = _build(text, selection: _caret(0), inkRanges: [ink]);

        _expectColour(span, ink, OmColors.fg1, 'inside the other match');
        expect(
          _underlined(_styleAt(span, _range(text, 'docs').start)),
          isTrue,
          reason: 'the label keeps its underline',
        );
        expect(
          _styleAt(span, ink.start).fontSize,
          isNot(0),
          reason: 'the revealed [ keeps its width',
        );
        // The unit at the range end and the one before its start are outside.
        expect(_colourAt(span, ink.end), OmColors.fg2, reason: 'range end');
        expect(_colourAt(span, ink.start - 1), OmColors.fg0, reason: 'before');
        _expectColour(span, _range(text, '.y)'), OmColors.fg2, 'URL tail');
        _expectColour(span, _range(text, 'more'), OmColors.info, 'other link');
        final more = text.indexOf('[more');
        expect(_colourAt(span, more), OmColors.fg2, reason: 'other [');
        expect(
          _colourAt(span, text.indexOf('](', more)),
          OmColors.fg2,
          reason: 'other ](',
        );
      },
    );

    for (final (name, text, needle, taskDone, resolves) in [
      (
        'inside a non current ink range strike text draws in fg1',
        'A ~~old~~ b',
        'old',
        false,
        true,
      ),
      (
        'inside a non current ink range ghost wikilink text draws in fg1',
        'A [[Gone]] b',
        'Gone',
        false,
        false,
      ),
      (
        'inside a non current ink range resting tag text draws in fg1',
        'A #tag b',
        'tag',
        false,
        true,
      ),
      (
        'inside a non current ink range small heading text draws in fg1',
        '#### Small head',
        'Small',
        false,
        true,
      ),
      (
        'inside a non current ink range done task text draws in fg1',
        'Done item',
        'Done',
        true,
        true,
      ),
    ]) {
      test(name, () {
        final r = _range(text, needle);
        final plain = _build(
          text,
          taskDone: taskDone,
          isResolved: (_) => resolves,
        );
        _expectColour(plain, r, OmColors.fg2, 'without ink: fg2');
        final inked = _build(
          text,
          taskDone: taskDone,
          isResolved: (_) => resolves,
          inkRanges: [r],
        );
        _expectColour(inked, r, OmColors.fg1, 'inside the other match');
        final before = _styleAt(plain, r.start);
        final after = _styleAt(inked, r.start);
        expect(after.fontSize, before.fontSize, reason: 'size unchanged');
        expect(_weight(after), _weight(before), reason: 'weight unchanged');
        expect(after.decoration, before.decoration, reason: 'decoration');
        expect(after.decorationColor, before.decorationColor);
        expect(after.decorationStyle, before.decorationStyle);
        expect(after.fontStyle, before.fontStyle, reason: 'slant unchanged');
      });
    }

    test(
      'inside a non current ink range accent heading bold and fg0 text keep their colours while strike text beside them lifts',
      () {
        const text = '## Big [[Known]] and **bold** ~~past~~';
        final whole = TextRange(start: 0, end: text.length);
        final plain = _build(text, inkRanges: const <TextRange>[]);
        final inked = _build(text, inkRanges: [whole]);
        for (final needle in ['Big', 'Known', 'bold', 'and']) {
          final at = _range(text, needle).start;
          expect(
            _colourAt(inked, at),
            _colourAt(plain, at),
            reason: '"$needle" keeps its colour',
          );
          expect(_weight(_styleAt(inked, at)), _weight(_styleAt(plain, at)));
        }
        expect(_colourAt(inked, _range(text, 'Known').start), OmColors.accent);
        expect(_colourAt(inked, _range(text, 'Big').start), OmColors.fg0);
        _expectColour(
          inked,
          _range(text, 'past'),
          OmColors.fg1,
          'strike lifts',
        );

        const h1 = '# Top ~~past~~';
        final topInk = _build(
          h1,
          inkRanges: [TextRange(start: 0, end: h1.length)],
        );
        expect(_colourAt(topInk, _range(h1, 'Top').start), OmColors.heading1);
        _expectColour(topInk, _range(h1, 'past'), OmColors.fg1, 'strike lifts');

        const tag = 'A #tag ~~past~~';
        // A caret in the tag lights it accentSoft, which is not lifted.
        final lit = _build(
          tag,
          selection: _caret(4),
          inkRanges: [TextRange(start: 0, end: tag.length)],
        );
        _expectColour(lit, _range(tag, 'tag'), OmColors.accentSoft, 'lit tag');
        _expectColour(lit, _range(tag, 'past'), OmColors.fg1, 'strike lifts');
      },
    );

    testWidgets(
      'the controller inks the other and current matches its find decoration holds',
      (tester) async {
        final context = await _context(tester);
        const text = 'A [docs](https://x.y) and [more](https://z.w) end';
        final c = LivePreviewController(text: text);
        addTearDown(c.dispose);
        final docs = _range(text, 'docs');
        final more = _range(text, 'more');
        final n = ValueNotifier<FindDecoration?>(
          FindDecoration(inkRanges: [docs, more], current: more),
        );
        addTearDown(n.dispose);
        c.findDecoration = n;
        final span = _controllerSpan(context, c);
        _expectColour(span, docs, OmColors.fg1, 'other match');
        _expectColour(span, more, OmColors.surface0, 'current match');
        _expectColour(span, _range(text, 'end'), OmColors.fg0, 'outside');
        expect(_hiddenAt(span, docs.end), isTrue, reason: 'no reveal range');
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC8: the current match draws every run in surface0
  // -------------------------------------------------------------------------
  group('current match ink', () {
    test(
      'inside the current range every run including link text and markers draws in surface0',
      () {
        const text = 'A [docs](https://x.y) and **b** end';
        final current = _span(text, '[docs', 'and **b');
        final span = _build(
          text,
          selection: _caret(0),
          inkRanges: [current],
          current: current,
        );
        _expectColour(span, current, OmColors.surface0, 'current match');
        expect(
          _underlined(_styleAt(span, _range(text, 'docs').start)),
          isTrue,
          reason: 'the label keeps its underline',
        );
        expect(
          _weight(_styleAt(span, _range(text, 'b', nth: 0).start)),
          FontWeight.w700,
          reason: 'bold keeps its weight',
        );
        expect(_styleAt(span, current.start).fontSize, isNot(0));
        expect(_colourAt(span, current.end), OmColors.fg2, reason: 'range end');
        expect(_colourAt(span, current.start - 1), OmColors.fg0);
        _expectColour(span, _range(text, ' end'), OmColors.fg0, 'outside');
      },
    );

    test(
      'inside the current range selected text draws in surface0 and an other range beside it in fg1',
      () {
        const text = 'A [docs](https://x.y) [more](https://z.w) end';
        final other = _span(text, '[docs', 'x.y)');
        final current = _span(text, '[more', 'z.w)');
        final span = _build(
          text,
          selection: TextSelection(baseOffset: 0, extentOffset: text.length),
          inkRanges: [other, current],
          current: current,
        );
        _expectColour(span, current, OmColors.surface0, 'current, selected');
        _expectColour(span, other, OmColors.fg1, 'other, selected');
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC9, AC10: card rows and table grid cells ink and never reveal
  // -------------------------------------------------------------------------
  group('cards and grid cells', () {
    test(
      'a card row span with ink ranges and a current match recolours its text and reveals nothing',
      () {
        const text = 'See [docs](https://hydration.example) ~~old~~ **bold** x';
        final hydration = _range(text, 'hydration');
        final old = _range(text, 'old');
        final docs = _range(text, 'docs');
        final bold = _range(text, 'bold');
        final ranges = [docs, hydration, old, bold];
        final card = _build(
          text,
          forceHidden: true,
          inkRanges: ranges,
          current: docs,
        );

        _expectColour(card, docs, OmColors.surface0, 'current label');
        _expectColour(card, old, OmColors.fg1, 'other strike lifts');
        _expectColour(card, bold, OmColors.fg0, 'other bold keeps fg0');
        expect(_weight(_styleAt(card, bold.start)), FontWeight.w700);
        _expectColour(card, _range(text, 'See'), OmColors.fg0, 'outside');

        // Every marker stays hidden, the matched URL included.
        final strike = text.indexOf('~~');
        final star = text.indexOf('**');
        final markers = <int>[
          text.indexOf('['),
          for (var at = text.indexOf(']('); at <= text.indexOf(')'); at++) at,
          strike,
          strike + 1,
          star,
          star + 1,
        ];
        for (final at in markers) {
          expect(_hiddenAt(card, at), isTrue, reason: 'marker $at hidden');
        }

        // A selection over everything still reveals nothing in a card.
        final selected = _build(
          text,
          forceHidden: true,
          selection: TextSelection(baseOffset: 0, extentOffset: text.length),
          inkRanges: ranges,
          current: docs,
        );
        for (final at in markers) {
          expect(_hiddenAt(selected, at), isTrue, reason: 'selected $at');
        }
        _expectColour(selected, docs, OmColors.surface0, 'selected current');
      },
    );

    test(
      'a card row span with a match only in hidden markup keeps the markup hidden and the label its own colour',
      () {
        const text = 'See [docs](https://hydration.example) ~~old~~';
        final hydration = _range(text, 'hydration');
        final old = _range(text, 'old');
        final card = _build(
          text,
          forceHidden: true,
          inkRanges: [hydration, old],
          current: hydration,
        );
        for (var at = hydration.start; at < hydration.end; at++) {
          expect(_hiddenAt(card, at), isTrue, reason: 'hidden URL $at');
        }
        _expectColour(card, _range(text, 'docs'), OmColors.info, 'label');
        _expectColour(card, old, OmColors.fg1, 'the other match lifts');
      },
    );

    test(
      'a table grid cell span with ink ranges recolours the cell text inside them',
      () {
        // As table_grid.dart builds a cell: item text, hidden, one line.
        const cell = '~~y~~ and [x](u)';
        final y = _range(cell, 'y');
        final x = _range(cell, 'x');
        TextSpan build(List<TextRange> ink, TextRange? current) => _build(
          cell,
          itemText: true,
          forceHidden: true,
          fenced: const [false],
          before: 0x20,
          inkRanges: ink,
          current: current,
        );

        final other = build([y], null);
        _expectColour(other, y, OmColors.fg1, 'other match in the cell');
        _expectColour(other, x, OmColors.info, 'link outside the range');
        expect(_hiddenAt(other, cell.indexOf('~~')), isTrue);

        final current = build([y, x], x);
        _expectColour(current, x, OmColors.surface0, 'current match');
        _expectColour(current, y, OmColors.fg1, 'other match');
        _expectColour(current, _range(cell, 'and'), OmColors.fg0, 'outside');
        expect(_hiddenAt(current, cell.indexOf('](')), isTrue);
      },
    );
  });
}
