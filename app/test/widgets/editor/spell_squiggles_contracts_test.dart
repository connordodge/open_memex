// WI #437 (Spec #392 reqs 6, 7, 9, 21), verify round: contracts the red tests
// left unpinned, each one a site the gate's mutator flips.
//
// Cheap probes, no screenshots: the squiggle layer is painted through the
// `paints` matcher (a path whose body contains a point just under a flagged
// word's baseline), and the work counter `debugSpellSquigglePaints` proves
// when the layer repaints. The hint's wording is pinned on the pure
// `spellIssuesHint`, its semantics flags on a real semantics tree.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spell_squiggles.dart';

import '../../support/font_fetch_hold.dart';

// ------------------------------------------------------------------ issues

SpellIssue _wi437Spell(int start, int length) =>
    SpellIssue(kind: SpellIssueKind.spelling, start: start, length: length);

SpellIssue _wi437Gram(int start, int length, [String? description]) =>
    SpellIssue(
      kind: SpellIssueKind.grammar,
      start: start,
      length: length,
      description: description,
    );

// ------------------------------------------------------------------ rig

const String _wi437Text = 'teh cat adn dog';

/// [child] under an optional [registry] scope, at a fixed width so a long
/// text wraps.
Widget _wi437App({SpellIssueRegistry? registry, required Widget child}) {
  final body = registry == null
      ? child
      : SpellIssueScope(registry: registry, child: child);
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 300, child: body),
      ),
    ),
  );
}

Widget _wi437Field(TextEditingController controller) => SpellSquiggles(
  controller: controller,
  child: TextField(controller: controller),
);

Finder get _wi437Layer =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SquiggleLayer');

RenderEditable _wi437Editable(WidgetTester tester) =>
    findRenderEditable(tester.renderObject(find.byType(TextField)))!;

/// A point inside the squiggle band under [range], `below` px under its
/// line's baseline, in the squiggle layer's coordinates.
Offset _wi437PointUnder(
  WidgetTester tester,
  TextRange range, {
  double below = 2.95,
}) {
  final editable = _wi437Editable(tester);
  final boxes = RenderEditableLineBoxes(editable);
  final rect = boxes.boxesFor(range).first;
  final line = boxes.lines.firstWhere(
    (l) => rect.center.dy >= l.top && rect.center.dy < l.bottom,
  );
  final layer = tester.renderObject<RenderBox>(_wi437Layer);
  return MatrixUtils.transformPoint(
    editable.getTransformTo(layer),
    Offset(rect.center.dx, line.baseline + below),
  );
}

/// Whether anything listens to [notifier] (`hasListeners` is protected; a
/// test reads it to prove a layer let go of a source).
bool _wi437Listened(Listenable notifier) =>
    // ignore: invalid_use_of_protected_member
    (notifier as ChangeNotifier).hasListeners;

PaintPattern _wi437PaintsSquiggleAt(Offset point) =>
    paints..path(color: OmColors.danger, includes: [point]);

void main() {
  holdFontFetches();

  // ------------------------------------------------------- selection
  group('selection boundaries (AC5)', () {
    // The flagged word is 'cat' (4..7) of 'teh cat adn dog'.
    const cat = TextRange(start: 4, end: 7);
    for (final (name, base, extent, hidden) in <(String, int, int, bool)>[
      ('a selection strictly around the flagged range hides it', 0, 15, true),
      (
        'a selection that starts at the flagged range and runs past its end hides it',
        4,
        10,
        true,
      ),
      (
        'a selection that starts before the flagged range and ends at its end hides it',
        1,
        7,
        true,
      ),
      ('a backwards selection around the flagged range hides it', 10, 0, true),
      (
        'a selection that starts before the flagged range and ends inside it keeps it',
        0,
        6,
        false,
      ),
      (
        'a selection that starts inside the flagged range and ends past it keeps it',
        5,
        12,
        false,
      ),
      ('a selection inside the flagged range keeps it', 5, 6, false),
      (
        'a selection that starts at the flagged range and ends inside it keeps it',
        4,
        6,
        false,
      ),
      (
        'a selection that starts inside the flagged range and ends at its end keeps it',
        5,
        7,
        false,
      ),
      ('a selection beside the flagged range keeps it', 8, 11, false),
      // Outside a segment (no host) the field's own selection is the truth.
      (
        'a selection equal to the flagged range keeps it in a field of its own',
        4,
        7,
        false,
      ),
      (
        'a backwards selection equal to the flagged range keeps it in a field of its own',
        7,
        4,
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final registry = SpellIssueRegistry();
        final controller = TextEditingController(text: _wi437Text);
        addTearDown(controller.dispose);
        registry.setIssues(controller, [_wi437Spell(cat.start, 3)]);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        controller.selection = TextSelection(
          baseOffset: base,
          extentOffset: extent,
        );
        await tester.pump();

        final layer = tester.renderObject(_wi437Layer);
        if (hidden) {
          expect(layer, isNot(paints..path()));
        } else {
          expect(layer, _wi437PaintsSquiggleAt(_wi437PointUnder(tester, cat)));
        }
      });
    }

    testWidgets('a hidden squiggle returns once the selection collapses', (
      tester,
    ) async {
      final registry = SpellIssueRegistry();
      final controller = TextEditingController(text: _wi437Text);
      addTearDown(controller.dispose);
      registry.setIssues(controller, [_wi437Spell(4, 3)]);
      await tester.pumpWidget(
        _wi437App(registry: registry, child: _wi437Field(controller)),
      );
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 15,
      );
      await tester.pump();
      expect(tester.renderObject(_wi437Layer), isNot(paints..path()));

      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pump();
      expect(
        tester.renderObject(_wi437Layer),
        _wi437PaintsSquiggleAt(
          _wi437PointUnder(tester, const TextRange(start: 4, end: 7)),
        ),
      );
    });
  });

  // ------------------------------------------------------- clamped ranges
  group('ranges past the text (AC2)', () {
    testWidgets(
      'an issue that starts past the end of the text paints nothing and does not throw',
      (tester) async {
        final registry = SpellIssueRegistry();
        final controller = TextEditingController(text: _wi437Text);
        addTearDown(controller.dispose);
        registry.setIssues(controller, [_wi437Spell(100, 5)]);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        expect(tester.takeException(), isNull);
        expect(tester.renderObject(_wi437Layer), isNot(paints..path()));
      },
    );

    testWidgets(
      'an issue that runs past the end of the text paints up to the last character',
      (tester) async {
        final registry = SpellIssueRegistry();
        final controller = TextEditingController(text: _wi437Text);
        addTearDown(controller.dispose);
        // 'adn dog' is 8..15; the issue claims 40 characters from 8.
        registry.setIssues(controller, [_wi437Spell(8, 40)]);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        expect(tester.takeException(), isNull);
        final layer = tester.renderObject(_wi437Layer);
        final dog = _wi437PointUnder(
          tester,
          const TextRange(start: 12, end: 15),
        );
        expect(layer, _wi437PaintsSquiggleAt(dog));
        final before = _wi437PointUnder(
          tester,
          const TextRange(start: 0, end: 3),
        );
        expect(
          layer,
          isNot(_wi437PaintsSquiggleAt(before)),
          reason: 'nothing paints before the issue start',
        );
      },
    );

    testWidgets('an issue with a negative start is clamped to the text start', (
      tester,
    ) async {
      final registry = SpellIssueRegistry();
      final controller = TextEditingController(text: _wi437Text);
      addTearDown(controller.dispose);
      // -2 .. 3: the characters 0..3, 'teh'.
      registry.setIssues(controller, [_wi437Spell(-2, 5)]);
      await tester.pumpWidget(
        _wi437App(registry: registry, child: _wi437Field(controller)),
      );
      expect(tester.takeException(), isNull);
      final layer = tester.renderObject(_wi437Layer);
      expect(
        layer,
        _wi437PaintsSquiggleAt(
          _wi437PointUnder(tester, const TextRange(start: 0, end: 3)),
        ),
      );
      expect(
        layer,
        isNot(
          _wi437PaintsSquiggleAt(
            _wi437PointUnder(tester, const TextRange(start: 4, end: 7)),
          ),
        ),
        reason: 'the cat after it is not flagged',
      );
    });
  });

  // ------------------------------------------------------- wave shape
  group('wave shape (AC2)', () {
    // 'cat' is the flagged word. Its squiggle starts at the word's left edge
    // with its top at baseline + 2, climbs to baseline + 2.9 over two
    // pixels, and falls back to baseline + 2 over the next two; its body is
    // 1 px thick. A straight line, a sawtooth, a shifted phase, a different
    // amplitude or another wavelength each leave one of these points on the
    // wrong side of the body.
    const cat = TextRange(start: 4, end: 7);

    /// The point `dx` px right of the word's left edge and `below` px under
    /// its baseline, in the squiggle layer's coordinates.
    Offset pointAt(WidgetTester tester, double dx, double below) {
      final editable = _wi437Editable(tester);
      final boxes = RenderEditableLineBoxes(editable);
      final rect = boxes.boxesFor(cat).first;
      final line = boxes.lines.firstWhere(
        (l) => rect.center.dy >= l.top && rect.center.dy < l.bottom,
      );
      final layer = tester.renderObject<RenderBox>(_wi437Layer);
      return MatrixUtils.transformPoint(
        editable.getTransformTo(layer),
        Offset(rect.left + dx, line.baseline + below),
      );
    }

    // (name, dx, below, inside)
    for (final (name, dx, below, inside) in <(String, double, double, bool)>[
      (
        'the wave at the left edge the squiggle is low and 1 px thick',
        0.2,
        2.1,
        true,
      ),
      (
        'the wave at the left edge the squiggle is not yet high',
        0.2,
        3.5,
        false,
      ),
      ('the wave two pixels in the squiggle has climbed', 2.0, 3.8, true),
      (
        'the wave two pixels in the squiggle has left its low band',
        2.0,
        2.3,
        false,
      ),
      (
        'the wave just past the first crest the squiggle falls again',
        2.2,
        2.3,
        false,
      ),
      ('the wave four pixels in the squiggle is back low', 4.0, 2.15, true),
      (
        'the wave four pixels in the squiggle has left its high band',
        4.0,
        3.5,
        false,
      ),
      ('the wave the squiggle is never over its band', 3.0, 1.9, false),
      ('the wave the squiggle is never under its band', 3.0, 4.2, false),
    ]) {
      testWidgets(name, (tester) async {
        final registry = SpellIssueRegistry();
        final controller = TextEditingController(text: _wi437Text);
        addTearDown(controller.dispose);
        registry.setIssues(controller, [_wi437Spell(cat.start, 3)]);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        final point = pointAt(tester, dx, below);
        final layer = tester.renderObject(_wi437Layer);
        final pattern = paints..path(color: OmColors.danger, includes: [point]);
        if (inside) {
          expect(layer, pattern);
        } else {
          expect(layer, isNot(pattern));
        }
      });
    }
  });

  // ------------------------------------------------------- repaint sources
  group('repaint sources (AC7)', () {
    testWidgets(
      'a squiggle follows the field when the field scrolls its own text',
      (tester) async {
        final registry = SpellIssueRegistry();
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        // Eight lines of one word each, two of which fit.
        final text = [for (var i = 0; i < 8; i++) 'w$i'].join('\n');
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        final last = TextRange(start: text.length - 2, end: text.length);
        registry.setIssues(controller, [_wi437Spell(last.start, 2)]);
        await tester.pumpWidget(
          _wi437App(
            registry: registry,
            child: SpellSquiggles(
              controller: controller,
              child: SizedBox(
                height: 60,
                child: TextField(
                  controller: controller,
                  scrollController: scroll,
                  maxLines: 2,
                ),
              ),
            ),
          ),
        );
        expect(
          scroll.position.maxScrollExtent,
          greaterThan(20),
          reason: 'fixture: the field scrolls',
        );
        final first = _wi437PointUnder(tester, last);
        expect(tester.renderObject(_wi437Layer), _wi437PaintsSquiggleAt(first));

        final paintsBefore = debugSpellSquigglePaints;
        scroll.jumpTo(20);
        await tester.pump();
        expect(
          debugSpellSquigglePaints,
          greaterThan(paintsBefore),
          reason: 'the layer repaints when the field scrolls',
        );
        final moved = _wi437PointUnder(tester, last);
        expect(moved.dy, closeTo(first.dy - 20, 0.001));
        expect(tester.renderObject(_wi437Layer), _wi437PaintsSquiggleAt(moved));
        expect(
          tester.renderObject(_wi437Layer),
          isNot(_wi437PaintsSquiggleAt(first)),
          reason: 'the squiggle left its old place',
        );
      },
    );

    testWidgets(
      'swapping the controller moves the layer to the new controller and drops the old one',
      (tester) async {
        final registry = SpellIssueRegistry();
        final one = TextEditingController(text: _wi437Text);
        final two = TextEditingController(text: _wi437Text);
        addTearDown(one.dispose);
        addTearDown(two.dispose);
        registry.setIssues(one, [_wi437Spell(0, 3)]);
        registry.setIssues(two, [_wi437Spell(4, 3)]);
        final holder = ValueNotifier<TextEditingController>(one);
        addTearDown(holder.dispose);
        await tester.pumpWidget(
          _wi437App(
            registry: registry,
            child: ValueListenableBuilder(
              valueListenable: holder,
              builder: (_, c, _) => _wi437Field(c),
            ),
          ),
        );
        expect(
          tester.renderObject(_wi437Layer),
          _wi437PaintsSquiggleAt(
            _wi437PointUnder(tester, const TextRange(start: 0, end: 3)),
          ),
        );

        holder.value = two;
        await tester.pump();
        expect(
          tester.renderObject(_wi437Layer),
          _wi437PaintsSquiggleAt(
            _wi437PointUnder(tester, const TextRange(start: 4, end: 7)),
          ),
          reason: 'the second controller issue paints',
        );
        expect(
          _wi437Listened(registry.issuesFor(one)),
          isFalse,
          reason: 'the old issues are no longer listened to',
        );
        expect(
          _wi437Listened(one),
          isFalse,
          reason: 'the old controller is no longer listened to',
        );

        // The new controller's issues and value drive repaints.
        final paintsBefore = debugSpellSquigglePaints;
        registry.setIssues(two, [_wi437Spell(8, 3)]);
        await tester.pump();
        expect(debugSpellSquigglePaints, greaterThan(paintsBefore));
        final afterIssues = debugSpellSquigglePaints;
        two.selection = const TextSelection.collapsed(offset: 2);
        await tester.pump();
        expect(
          debugSpellSquigglePaints,
          greaterThan(afterIssues),
          reason: 'the new controller repaints the layer too',
        );
      },
    );

    testWidgets(
      'a removed field stops listening to its controller and its issues',
      (tester) async {
        final registry = SpellIssueRegistry();
        final controller = TextEditingController(text: _wi437Text);
        addTearDown(controller.dispose);
        registry.setIssues(controller, [_wi437Spell(0, 3)]);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        final issues = registry.issuesFor(controller);
        expect(_wi437Listened(issues), isTrue, reason: 'fixture: listened to');

        await tester.pumpWidget(
          _wi437App(registry: registry, child: const SizedBox()),
        );
        expect(_wi437Listened(issues), isFalse);
        expect(_wi437Listened(controller), isFalse);
      },
    );

    testWidgets(
      'the layer repaints when the reveal gate of a table row field flips',
      (tester) async {
        final registry = SpellIssueRegistry();
        final gate = ValueNotifier<bool>(false);
        addTearDown(gate.dispose);
        final controller = LivePreviewController(text: _wi437Text)
          ..tableRow = true
          ..revealGate = gate;
        addTearDown(controller.dispose);
        registry.setIssues(controller, [_wi437Spell(4, 3)]);
        controller.selection = const TextSelection.collapsed(offset: 0);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        expect(
          tester.renderObject(_wi437Layer),
          isNot(paints..path()),
          reason: 'an unrevealed table row paints no squiggle',
        );

        final paintsBefore = debugSpellSquigglePaints;
        gate.value = true;
        await tester.pump();
        expect(
          debugSpellSquigglePaints,
          greaterThan(paintsBefore),
          reason: 'revealing repaints the layer',
        );
        expect(
          tester.renderObject(_wi437Layer),
          _wi437PaintsSquiggleAt(
            _wi437PointUnder(tester, const TextRange(start: 4, end: 7)),
          ),
        );
      },
    );

    testWidgets('a squiggle layer never takes a tap from the field', (
      tester,
    ) async {
      final registry = SpellIssueRegistry();
      final controller = TextEditingController(text: _wi437Text);
      addTearDown(controller.dispose);
      registry.setIssues(controller, [_wi437Spell(4, 3)]);
      await tester.pumpWidget(
        _wi437App(registry: registry, child: _wi437Field(controller)),
      );
      await tester.tapAt(
        tester.getTopLeft(find.byType(TextField)) + const Offset(40, 20),
      );
      await tester.pump();
      expect(
        tester
            .state<EditableTextState>(find.byType(EditableText))
            .widget
            .focusNode
            .hasFocus,
        isTrue,
        reason: 'the field got the tap through the squiggle layer',
      );
    });

    testWidgets('without a scope the field is returned unchanged', (
      tester,
    ) async {
      final controller = TextEditingController(text: _wi437Text);
      addTearDown(controller.dispose);
      await tester.pumpWidget(_wi437App(child: _wi437Field(controller)));
      expect(_wi437Layer, findsNothing);
    });
  });

  // ------------------------------------------------------- hint wording
  group('semantics hint wording (AC8)', () {
    test('a hint lists its issues in list order joined with a semicolon', () {
      final c = TextEditingController(text: _wi437Text);
      addTearDown(c.dispose);
      expect(
        spellIssuesHint(c, [_wi437Spell(0, 3), _wi437Spell(8, 3)]),
        'misspelled: teh; misspelled: adn',
      );
      expect(
        spellIssuesHint(c, [_wi437Spell(8, 3), _wi437Spell(0, 3)]),
        'misspelled: adn; misspelled: teh',
      );
      expect(
        spellIssuesHint(c, [_wi437Spell(0, 3), _wi437Gram(4, 3, 'Why')]),
        'misspelled: teh; grammar: Why',
      );
    });

    test('a hint is null without issues', () {
      final c = TextEditingController(text: _wi437Text);
      addTearDown(c.dispose);
      expect(spellIssuesHint(c, const []), isNull);
    });

    test(
      'a grammar issue without a description is named by its flagged text',
      () {
        final c = TextEditingController(text: _wi437Text);
        addTearDown(c.dispose);
        expect(spellIssuesHint(c, [_wi437Gram(4, 3)]), 'grammar: cat');
        expect(
          spellIssuesHint(c, [_wi437Gram(4, 3, 'Use a noun')]),
          'grammar: Use a noun',
        );
      },
    );

    test('empty and out of range issues are left out of the hint', () {
      final c = TextEditingController(text: _wi437Text);
      addTearDown(c.dispose);
      expect(spellIssuesHint(c, [_wi437Spell(2, 0)]), isNull);
      expect(spellIssuesHint(c, [_wi437Spell(15, 3)]), isNull);
      expect(spellIssuesHint(c, [_wi437Spell(40, 3)]), isNull);
      expect(
        spellIssuesHint(c, [_wi437Spell(40, 3), _wi437Spell(0, 3)]),
        'misspelled: teh',
      );
    });

    test(
      'an issue running past the end is named by the characters that exist',
      () {
        final c = TextEditingController(text: _wi437Text);
        addTearDown(c.dispose);
        expect(spellIssuesHint(c, [_wi437Spell(12, 40)]), 'misspelled: dog');
        expect(spellIssuesHint(c, [_wi437Spell(-2, 5)]), 'misspelled: teh');
      },
    );

    test(
      'an unrevealed table row field has no hint and a revealed one has',
      () {
        final gate = ValueNotifier<bool>(false);
        addTearDown(gate.dispose);
        final row = LivePreviewController(text: _wi437Text)
          ..tableRow = true
          ..revealGate = gate
          ..selection = const TextSelection.collapsed(offset: 0);
        addTearDown(row.dispose);
        final issues = [_wi437Spell(0, 3)];
        expect(spellIssuesHint(row, issues), isNull, reason: 'gate closed');

        gate.value = true;
        expect(spellIssuesHint(row, issues), 'misspelled: teh');

        row.selection = const TextSelection.collapsed(offset: -1);
        expect(
          spellIssuesHint(row, issues),
          isNull,
          reason: 'no valid selection: not revealed',
        );

        final plain = LivePreviewController(text: _wi437Text)
          ..selection = const TextSelection.collapsed(offset: 0);
        addTearDown(plain.dispose);
        expect(
          spellIssuesHint(plain, issues),
          'misspelled: teh',
          reason: 'a row that is not a table row is never hidden',
        );
      },
    );
  });

  // ------------------------------------------------------- semantics flags
  group('semantics flags (AC8)', () {
    testWidgets(
      'a field with issues keeps its own node and the hint sits on a container above it',
      (tester) async {
        final handle = tester.ensureSemantics();
        final registry = SpellIssueRegistry();
        final controller = TextEditingController(text: _wi437Text);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _wi437App(registry: registry, child: _wi437Field(controller)),
        );
        final field = tester.getSemantics(find.byType(EditableText));
        expect(field.getSemanticsData().hint, isNot(contains('misspelled')));

        registry.setIssues(controller, [_wi437Spell(0, 3)]);
        await tester.pump();
        final fieldAfter = tester.getSemantics(find.byType(EditableText));
        expect(
          fieldAfter.getSemanticsData().flagsCollection.isTextField,
          isTrue,
          reason: 'the field keeps its own text field node',
        );
        expect(
          fieldAfter.getSemanticsData().hint,
          isNot(contains('misspelled')),
          reason: 'the hint is not merged into the field node',
        );
        final parent = fieldAfter.parent!.getSemanticsData();
        expect(parent.hint, 'misspelled: teh');
        expect(
          parent.flagsCollection.isTextField,
          isFalse,
          reason: 'the hint node is a separate container',
        );
        handle.dispose();
      },
    );

    testWidgets('a field without issues adds no semantics node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      int nodes() {
        var n = 0;
        void down(SemanticsNode node) {
          n++;
          node.visitChildren((c) {
            down(c);
            return true;
          });
        }

        down(tester.getSemantics(find.byType(Scaffold)));
        return n;
      }

      final controller = TextEditingController(text: _wi437Text);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _wi437App(child: TextField(controller: controller)),
      );
      await tester.pump();
      final plain = nodes();

      await tester.pumpWidget(
        _wi437App(
          registry: SpellIssueRegistry(),
          child: _wi437Field(controller),
        ),
      );
      await tester.pump();
      expect(nodes(), plain, reason: 'no hint, no extra node');
      handle.dispose();
    });

    testWidgets('the hint of a table row field follows its reveal gate', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final registry = SpellIssueRegistry();
      final gate = ValueNotifier<bool>(false);
      addTearDown(gate.dispose);
      final controller = LivePreviewController(text: _wi437Text)
        ..tableRow = true
        ..revealGate = gate
        ..selection = const TextSelection.collapsed(offset: 0);
      addTearDown(controller.dispose);
      registry.setIssues(controller, [_wi437Spell(0, 3)]);
      await tester.pumpWidget(
        _wi437App(registry: registry, child: _wi437Field(controller)),
      );
      bool hinted() {
        for (
          var n = tester.getSemantics(find.byType(EditableText)).parent;
          n != null;
          n = n.parent
        ) {
          if (n.getSemanticsData().hint.contains('misspelled')) return true;
        }
        return false;
      }

      expect(hinted(), isFalse, reason: 'unrevealed: no hint');
      gate.value = true;
      await tester.pump();
      expect(hinted(), isTrue, reason: 'revealed: the hint appears');
      handle.dispose();
    });
  });

  // ------------------------------------------------------- baselines
  group('line box baseline contracts (AC1)', () {
    ui.LineMetrics metric(double baseline, int n) => ui.LineMetrics(
      hardBreak: true,
      ascent: 10,
      descent: 4,
      unscaledAscent: 10,
      height: 14,
      width: 30,
      left: 0,
      baseline: baseline,
      lineNumber: n,
    );

    TextPainter painterOfX() {
      final painter = TextPainter(
        text: const TextSpan(text: 'x', style: TextStyle(fontSize: 20)),
        textDirection: TextDirection.ltr,
      )..layout();
      addTearDown(painter.dispose);
      return painter;
    }

    test('a LineBox built without a baseline sits it on its bottom', () {
      const line = LineBox(
        range: TextRange(start: 0, end: 3),
        top: 4,
        bottom: 22,
      );
      expect(line.baseline, 22);
      const own = LineBox(
        range: TextRange(start: 0, end: 3),
        top: 4,
        bottom: 22,
        baseline: 17.5,
      );
      expect(own.baseline, 17.5);
    });

    test('measuredBaseline reads the baseline of a line that has metrics', () {
      final painter = painterOfX();
      final metrics = [metric(11, 0), metric(33, 1)];
      const previous = LineBox(
        range: TextRange(start: 0, end: 1),
        top: 0,
        bottom: 20,
        baseline: 15,
      );
      expect(measuredBaseline(painter, metrics, 0, 0, null), 11);
      expect(measuredBaseline(painter, metrics, 1, 500, previous), 33);
    });

    test(
      'measuredBaseline puts a line without metrics as far under its top as the line above',
      () {
        final painter = painterOfX();
        const previous = LineBox(
          range: TextRange(start: 0, end: 1),
          top: 10,
          bottom: 34,
          baseline: 27,
        );
        expect(measuredBaseline(painter, [metric(27, 0)], 1, 40, previous), 57);
      },
    );

    test(
      'measuredBaseline puts the first line of an empty painter at its first baseline',
      () {
        final painter = painterOfX();
        final first = painter.computeLineMetrics().first.baseline;
        expect(
          measuredBaseline(painter, const [], 0, 7, null),
          closeTo(7 + first, 0.001),
        );
      },
    );

    testWidgets(
      'an empty field and an empty last line take the baseline offset of the first line',
      (tester) async {
        final controller = TextEditingController(text: 'x');
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _wi437App(child: TextField(controller: controller, maxLines: null)),
        );
        final one = RenderEditableLineBoxes(
          _wi437Editable(tester),
        ).lines.single;
        final offset = one.baseline - one.top;
        expect(offset, greaterThan(0));
        expect(one.baseline, lessThan(one.bottom));

        controller.text = '';
        await tester.pump();
        final empty = RenderEditableLineBoxes(
          _wi437Editable(tester),
        ).lines.single;
        expect(empty.baseline - empty.top, closeTo(offset, 0.001));

        controller.text = 'x\n';
        await tester.pump();
        final two = RenderEditableLineBoxes(_wi437Editable(tester)).lines;
        expect(two, hasLength(2));
        expect(two[0].baseline - two[0].top, closeTo(offset, 0.001));
        expect(
          two[1].baseline - two[1].top,
          closeTo(offset, 0.001),
          reason: 'the empty last line sits like the line above',
        );
      },
    );
  });
}
