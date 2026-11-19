// WI #125 (Spec #122 Requirements 1, 2, 36; Technical Decision 8; rulings D8,
// D9): the long-note fixtures and the perf work counters.
//
// Fixtures: sizes, structure, determinism, the flagged-word variants, the
// decorated variant and the public-text rule (no home-shaped path, only the
// invented vocabulary).
//
// Counters: each counter is one increment in the function it counts, so each
// test drives that function through its public surface (or the widget that
// runs it) and reads the counter by its [PerfCounters] name. A counter that
// never moved, or moved twice per call, fails its test. The helper itself
// (reset, snapshot by name, delta) has its own tests.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart' as rows;
import 'package:open_memex_app/src/editor/markdown_inline.dart' as inline;
import 'package:open_memex_app/src/editor/markdown_lines.dart' as mdlines;
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/spell_check_controller.dart';
import 'package:open_memex_app/src/state/spell_session_state.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart' as row;
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart'
    as decorations;
import 'package:open_memex_app/src/widgets/editor/marker_column.dart' as marker;
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_check_host.dart'
    as host;
import 'package:open_memex_app/src/widgets/editor/spell_squiggles.dart'
    as squiggles;
import 'package:open_memex_app/src/widgets/find/find_highlights.dart' as findhl;
import 'package:open_memex_app/src/widgets/outline/section_tracker.dart';

import '../support/app_harness.dart';
import '../support/fake_spelling_service.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/long_note_fixtures.dart';
import '../support/perf_counters.dart';
import '../support/spelling_editor_pump.dart';

/// One counter's current value, by its [PerfCounters] name.
int _n(String name) => PerfCounters.snapshot()[name]!;

/// FNV-1a over UTF-16 code units: a digest that is the same in every run.
int _wi125Digest(String text) {
  var h = 0x811c9dc5;
  for (final u in text.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// A [LineBoxSource] over [text]: one fixed-height line box per source line,
/// no geometry beyond that. For calling `layoutDecorations` directly.
class _Wi125Boxes implements LineBoxSource {
  _Wi125Boxes(this.text);

  final String text;
  final RenderBox _box = RenderConstrainedBox(
    additionalConstraints: const BoxConstraints.tightFor(
      width: 400,
      height: 400,
    ),
  );

  @override
  RenderBox get box => _box;

  @override
  List<LineBox> get lines {
    var start = 0;
    var top = 0.0;
    final out = <LineBox>[];
    for (final line in text.split('\n')) {
      out.add(
        LineBox(
          range: TextRange(start: start, end: start + line.length),
          top: top,
          bottom: top + 20,
        ),
      );
      start += line.length + 1;
      top += 20;
    }
    return out;
  }

  @override
  List<Rect> boxesFor(TextRange range) => [
    for (final line in lines)
      if (range.start < line.range.end && range.end > line.range.start)
        Rect.fromLTRB(0, line.top, 40, line.bottom),
  ];

  @override
  Rect caretRect(int offset) => Rect.fromLTWH(0, 0, 0, 20);

  @override
  int offsetAt(Offset point) => 0;
}

/// An `EditorRow` pumped alone (no segment around it) on [controller].
Widget _wi125Row(LivePreviewController controller, FocusNode focus) =>
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: row.EditorRow(
            segment: 0,
            index: 0,
            kind: rows.RowKind.prose,
            geometry: null,
            marker: '',
            controller: controller,
            focusNode: focus,
            boxes: () => null,
            field: const SizedBox(width: 200, height: 24),
          ),
        ),
      ),
    );

/// A [SpellingService] with a known document tag, so a check never waits on
/// one.
Future<void> _wi125WarmTag(
  WidgetTester tester,
  SpellSession session,
  String noteId,
) async {
  final warm = session.documentTag(noteId);
  await tester.pump();
  await warm;
}

void main() {
  holdFontFetches();

  setUp(PerfCounters.reset);

  // ----------------------------------------------------------- fixtures

  group('long note fixtures', () {
    test(
      'N1 has 3000 lines 110k to 130k chars and a heading every 50 lines',
      () {
        final n = longNote(LongNoteKind.n1Plain120k);
        expect(n.text.split('\n'), hasLength(3000));
        expect(n.lines, hasLength(3000));
        expect(n.text.length, inInclusiveRange(110000, 130000));
        expect(n.headingCount, 60);
        for (var i = 0; i < 3000; i++) {
          if (i % 50 == 0) {
            expect(n.lines[i], '## Section ${i ~/ 50 + 1}', reason: 'line $i');
          } else {
            expect(n.lines[i], startsWith('Speaker $i: '), reason: 'line $i');
          }
        }
      },
    );

    test(
      'N2 has the line count of N1 with every non heading line a bullet item',
      () {
        final n1 = longNote(LongNoteKind.n1Plain120k);
        final n = longNote(LongNoteKind.n2Bullets120k);
        expect(n.lines, hasLength(3000));
        expect(n.text.length, inInclusiveRange(110000, 130000));
        expect(n.headingCount, 60);
        for (var i = 0; i < 3000; i++) {
          if (i % 50 == 0) {
            expect(n.lines[i], n1.lines[i], reason: 'heading line $i');
          } else {
            expect(n.lines[i], '- ${n1.lines[i]}', reason: 'line $i');
          }
        }
      },
    );

    test('N3 and N4 have 12000 lines and 440k to 520k chars', () {
      final n3 = longNote(LongNoteKind.n3Plain500k);
      final n4 = longNote(LongNoteKind.n4Bullets500k);
      for (final n in [n3, n4]) {
        expect(n.lines, hasLength(12000), reason: n.kind.name);
        expect(n.text.split('\n'), hasLength(12000), reason: n.kind.name);
        expect(
          n.text.length,
          inInclusiveRange(440000, 520000),
          reason: n.kind.name,
        );
        expect(n.headingCount, 240, reason: n.kind.name);
      }
      expect(n3.lines.where((l) => l.startsWith('- ')), isEmpty);
      expect(
        n4.lines.where((l) => !l.startsWith('## ') && !l.startsWith('- ')),
        isEmpty,
      );
    });

    test(
      'N5 has about 550 lines averaging 200 to 240 chars with a heading every 10 lines',
      () {
        final n = longNote(LongNoteKind.n5PlainLongLines120k);
        expect(n.lines.length, inInclusiveRange(540, 560));
        final body = [
          for (final l in n.lines)
            if (!l.startsWith('## ')) l,
        ];
        expect(n.headingCount, n.lines.length ~/ 10);
        for (var i = 0; i < n.lines.length; i += 10) {
          expect(n.lines[i], startsWith('## Section '), reason: 'line $i');
        }
        final average = n.text.length / n.lines.length;
        expect(average, inInclusiveRange(200, 240));
        expect(n.text.length, inInclusiveRange(110000, 130000));
        expect(body, isNotEmpty);
      },
    );

    test('every plain fixture is identical across runs', () {
      // Digests pinned from a first run: any clock, hash-order or Random
      // dependence moves one.
      const digests = {
        LongNoteKind.n1Plain120k: 2671144222,
        LongNoteKind.n2Bullets120k: 1764064728,
        LongNoteKind.n3Plain500k: 929457574,
        LongNoteKind.n4Bullets500k: 3550151302,
        LongNoteKind.n5PlainLongLines120k: 2731159626,
      };
      for (final kind in LongNoteKind.values) {
        final first = longNote(kind);
        final second = longNote(kind);
        expect(second.text, first.text, reason: kind.name);
        expect(_wi125Digest(first.text), digests[kind], reason: kind.name);
      }
    });

    test('the misspelled variant flags one word in every 10th line', () {
      final n = longNote(
        LongNoteKind.n1Plain120k,
        variant: LongNoteVariant.misspelled,
      );
      expect(n.flaggedLines, [for (var i = 9; i < 3000; i += 10) i]);
      expect(n.flaggedWords, hasLength(300));
      for (var i = 0; i < 3000; i++) {
        final hits = [
          for (final w in longNoteFlaggedPool)
            if (RegExp('\\b$w\\b').hasMatch(n.lines[i])) w,
        ];
        if (i % 10 == 9) {
          expect(hits, [n.flaggedWords[n.flaggedLines.indexOf(i)]]);
        } else {
          expect(hits, isEmpty, reason: 'line $i');
        }
      }
      // The plain note never holds a flagged word.
      final plain = longNote(LongNoteKind.n1Plain120k);
      for (final w in longNoteFlaggedPool) {
        expect(plain.text, isNot(contains(w)));
      }
    });

    test('the misspelled heavy variant flags one word in every line', () {
      final n = longNote(
        LongNoteKind.n1Plain120k,
        variant: LongNoteVariant.misspelledHeavy,
      );
      expect(n.flaggedLines, [for (var i = 0; i < 3000; i++) i]);
      for (var i = 0; i < 3000; i++) {
        final hits = [
          for (final w in longNoteFlaggedPool)
            for (final _ in RegExp('\\b$w\\b').allMatches(n.lines[i])) w,
        ];
        expect(hits, [n.flaggedWords[i]], reason: 'line $i');
      }
    });

    test(
      'seeding a variant makes FakeSpellingService report exactly its flagged words',
      () {
        final n = longNote(
          LongNoteKind.n1Plain120k,
          variant: LongNoteVariant.misspelled,
        );
        final spelling = FakeSpellingService();
        expect(
          spelling.issuesFor(n.text, documentTag: 1),
          isEmpty,
          reason: 'nothing is flagged before seeding',
        );
        seedMisspellings(spelling, n);
        final issues = spelling.issuesFor(n.text, documentTag: 1);
        expect(issues, hasLength(300));
        final starts = <int>[];
        var at = 0;
        for (final line in n.lines) {
          starts.add(at);
          at += line.length + 1;
        }
        for (final (k, issue) in issues.indexed) {
          final line = n.flaggedLines[k];
          final word = n.flaggedWords[k];
          expect(issue.start, starts[line] + n.lines[line].indexOf(word));
          expect(
            n.text.substring(issue.start, issue.start + issue.length),
            word,
          );
        }
        // The heavy variant: one issue per line.
        final heavy = longNote(
          LongNoteKind.n5PlainLongLines120k,
          variant: LongNoteVariant.misspelledHeavy,
        );
        final other = FakeSpellingService();
        seedMisspellings(other, heavy);
        expect(
          other.issuesFor(heavy.text, documentTag: 1),
          hasLength(heavy.lines.length),
        );
        // A plain note seeds nothing.
        final none = FakeSpellingService();
        seedMisspellings(none, longNote(LongNoteKind.n1Plain120k));
        expect(none.issuesFor(n.text, documentTag: 1), isEmpty);
      },
    );

    test(
      'the decorated variant has a code span and a wikilink every 10 lines and a quote and a rule every 100',
      () {
        final n = longNote(
          LongNoteKind.n1Plain120k,
          variant: LongNoteVariant.decorated,
        );
        final md = mdlines.classifyLines(n.text, atSegmentStart: true);
        expect(md, hasLength(3000));
        expect([
          for (final l in md)
            if (l.kind == mdlines.MdLineKind.quote) l,
        ], hasLength(30));
        expect([
          for (final l in md)
            if (l.kind == mdlines.MdLineKind.rule) l,
        ], hasLength(30));
        for (var i = 0; i < 3000; i++) {
          final tokens = inline.tokenizeInline(n.lines[i]);
          final code = tokens
              .where((t) => t.kind == inline.InlineTokenKind.codeSpan)
              .length;
          final links = tokens
              .where((t) => t.kind == inline.InlineTokenKind.wikilink)
              .length;
          expect(code, i % 10 == 5 ? 1 : 0, reason: 'code spans on line $i');
          expect(links, i % 10 == 5 ? 1 : 0, reason: 'wikilinks on line $i');
          expect(
            md[i].kind == mdlines.MdLineKind.quote,
            i % 100 == 22,
            reason: 'quote at line $i',
          );
          expect(
            md[i].kind == mdlines.MdLineKind.rule,
            i % 100 == 77,
            reason: 'rule at line $i',
          );
        }
      },
    );

    test(
      'no fixture holds a home shaped path or text outside the invented vocabulary',
      () {
        final home = RegExp(r'/(Users|home)/[A-Za-z]');
        final prose = RegExp(
          r'^(- )?Speaker \d+: [a-z]+( [a-z]+)*( [a-z.]+)*\.$',
        );
        for (final kind in LongNoteKind.values) {
          for (final variant in LongNoteVariant.values) {
            final n = longNote(kind, variant: variant);
            expect(
              n.text,
              isNot(matches(home)),
              reason: '${kind.name} $variant',
            );
            expect(
              n.text,
              isNot(contains('~/')),
              reason: '${kind.name} $variant',
            );
          }
          final plain = longNote(kind);
          for (final (i, line) in plain.lines.indexed) {
            if (line.startsWith('## Section ')) {
              expect(
                line,
                matches(RegExp(r'^## Section \d+$')),
                reason: 'line $i',
              );
            } else {
              expect(line, matches(prose), reason: '${kind.name} line $i');
            }
          }
        }
      },
    );
  });

  // ------------------------------------------------------ helper itself

  group('perf counters helper', () {
    // Every counter set to its own value 1..N, in [PerfCounters.names] order.
    void setAll() {
      inline.debugTokenizeInlineCalls = 1;
      mdlines.debugClassifyLinesCalls = 2;
      rows.debugSplitRowsCalls = 3;
      RenderEditableLineBoxes.debugMeasures = 4;
      RenderEditableLineBoxes.debugLineWalks = 5;
      RenderParagraphLineBoxes.debugMeasures = 6;
      RenderParagraphLineBoxes.debugLineWalks = 7;
      decorations.debugLayoutDecorationsCalls = 8;
      LivePreviewController.debugBuildTextSpans = 9;
      row.EditorRow.debugBuilds = 10;
      row.debugEditorRowSelectionPaints = 11;
      SegmentViewState.debugBuilds = 12;
      SegmentViewState.debugSetStates = 13;
      marker.debugMarkerColumnBuilds = 14;
      marker.debugMarkerColumnSetStates = 15;
      marker.debugMarkerColumnPaints = 16;
      SectionTracker.debugPasses = 17;
      SpellCheckController.debugEvaluations = 18;
      host.debugSpellHostLineCalls = 19;
      host.debugSpellHostRectCalls = 20;
      squiggles.debugSpellSquigglePaints = 21;
      findhl.debugFindHighlightUpdates = 22;
      findhl.debugFindHighlightPaints = 23;
    }

    test('snapshot returns every counter by name', () {
      expect(PerfCounters.names, hasLength(23));
      expect(PerfCounters.names.toSet(), hasLength(23));
      setAll();
      expect(PerfCounters.snapshot(), {
        for (final (i, name) in PerfCounters.names.indexed) name: i + 1,
      });
    });

    test(
      'reset zeroes every counter including the tracker and squiggle paints',
      () {
        setAll();
        PerfCounters.reset();
        expect(PerfCounters.snapshot().values.every((v) => v == 0), isTrue);
        expect(SectionTracker.debugPasses, 0);
        expect(squiggles.debugSpellSquigglePaints, 0);
        expect(findhl.debugFindHighlightPaints, 0);
        expect(PerfCounters.snapshot().keys, PerfCounters.names);
      },
    );

    test('delta is the work done since a snapshot', () {
      setAll();
      final before = PerfCounters.snapshot();
      mdlines.debugClassifyLinesCalls += 4;
      SectionTracker.debugPasses += 1;
      final delta = PerfCounters.delta(before);
      expect(delta['classifyLines'], 4);
      expect(delta['sectionTrackerPasses'], 1);
      expect(
        delta.entries.where((e) => e.value != 0).map((e) => e.key).toSet(),
        {'classifyLines', 'sectionTrackerPasses'},
      );
    });
  });

  // ------------------------------------------------------ pure counters

  group('pure parsing counters', () {
    test('classifyLines adds one per call', () {
      expect(_n('classifyLines'), 0);
      mdlines.classifyLines('one\ntwo', atSegmentStart: true);
      expect(_n('classifyLines'), 1);
      mdlines.classifyLines('', atSegmentStart: false);
      expect(_n('classifyLines'), 2);
    });

    test('tokenizeInline adds one per call', () {
      expect(_n('tokenizeInline'), 0);
      inline.tokenizeInline('a `code` and [[Note]]');
      expect(_n('tokenizeInline'), 1);
      inline.tokenizeInline('b', before: 0x20);
      expect(_n('tokenizeInline'), 2);
    });

    test('splitRows adds one per call', () {
      expect(_n('splitRows'), 0);
      rows.splitRows('- a\n- b', atSegmentStart: true);
      expect(_n('splitRows'), 1);
      rows.splitRows('plain', atSegmentStart: false);
      expect(_n('splitRows'), 2);
    });
  });

  // ------------------------------------------------- decorations and spans

  group('decoration and span counters', () {
    test('layoutDecorations adds one per call', () {
      const text = 'a `code` b\n> quote\n***';
      expect(_n('layoutDecorations'), 0);
      decorations.layoutDecorations(
        text: text,
        boxes: _Wi125Boxes(text),
        columnLeft: 0,
        columnRight: 400,
      );
      expect(_n('layoutDecorations'), 1);
      decorations.layoutDecorations(
        text: '',
        boxes: _Wi125Boxes(''),
        columnLeft: 0,
        columnRight: 400,
      );
      expect(_n('layoutDecorations'), 2);
    });

    testWidgets('buildTextSpan adds one per call', (tester) async {
      await tester.pumpWidget(const SizedBox(key: Key('wi125-context')));
      final context = tester.element(find.byKey(const Key('wi125-context')));
      final c = LivePreviewController(text: 'a **bold** word');
      addTearDown(c.dispose);
      PerfCounters.reset();
      c.buildTextSpan(context: context, withComposing: false);
      expect(_n('buildTextSpan'), 1);
      c.buildTextSpan(context: context, withComposing: true);
      expect(_n('buildTextSpan'), 2);
    });
  });

  // ------------------------------------------------------- line boxes

  group('line box counters', () {
    Future<RenderEditableLineBoxes> pumpEditable(WidgetTester tester) async {
      final c = TextEditingController(text: 'first line\nsecond line\nthird');
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: TextField(controller: c, maxLines: null),
            ),
          ),
        ),
      );
      final editable = findRenderEditable(
        tester.renderObject(find.byType(TextField)),
      )!;
      PerfCounters.reset();
      return RenderEditableLineBoxes(editable);
    }

    Future<RenderParagraphLineBoxes> pumpParagraph(WidgetTester tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 300,
            child: Text.rich(
              TextSpan(text: 'first line\nsecond line\nthird'),
              key: Key('wi125-paragraph'),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byKey(const Key('wi125-paragraph')),
          matching: find.byType(RichText),
        ),
      );
      PerfCounters.reset();
      return RenderParagraphLineBoxes(paragraph);
    }

    testWidgets(
      'an editable counts one measure and one line walk per lines read',
      (tester) async {
        final boxes = await pumpEditable(tester);
        expect(boxes.lines, hasLength(3));
        expect(_n('editableLineMeasures'), 1);
        expect(_n('editableLineWalks'), 1);
        expect(boxes.lines, hasLength(3));
        expect(_n('editableLineMeasures'), 2);
        expect(_n('editableLineWalks'), 2);
        expect(_n('paragraphLineMeasures'), 0);
        expect(_n('paragraphLineWalks'), 0);
      },
    );

    testWidgets(
      'an editable counts one measure and one line walk per range read',
      (tester) async {
        final boxes = await pumpEditable(tester);
        expect(
          boxes.boxesFor(const TextRange(start: 2, end: 15)),
          hasLength(2),
        );
        expect(_n('editableLineMeasures'), 1);
        expect(_n('editableLineWalks'), 1);
        expect(boxes.boxesFor(const TextRange(start: 0, end: 4)), hasLength(1));
        expect(_n('editableLineMeasures'), 2);
        expect(_n('editableLineWalks'), 2);
      },
    );

    testWidgets(
      'an editable caret rect measures once while an offset query and a collapsed range measure nothing',
      (tester) async {
        final boxes = await pumpEditable(tester);
        boxes.caretRect(14);
        expect(_n('editableLineMeasures'), 1);
        expect(_n('editableLineWalks'), 1);
        final before = PerfCounters.snapshot();
        boxes.offsetAt(const Offset(10, 5));
        expect(boxes.boxesFor(const TextRange.collapsed(3)), isEmpty);
        expect(PerfCounters.delta(before)['editableLineMeasures'], 0);
        expect(PerfCounters.delta(before)['editableLineWalks'], 0);
      },
    );

    testWidgets(
      'a paragraph counts one measure and one line walk per lines read',
      (tester) async {
        final boxes = await pumpParagraph(tester);
        expect(boxes.lines, hasLength(3));
        expect(_n('paragraphLineMeasures'), 1);
        expect(_n('paragraphLineWalks'), 1);
        expect(boxes.lines, hasLength(3));
        expect(_n('paragraphLineMeasures'), 2);
        expect(_n('paragraphLineWalks'), 2);
        expect(_n('editableLineMeasures'), 0);
        expect(_n('editableLineWalks'), 0);
      },
    );

    testWidgets(
      'a paragraph counts one measure and one line walk per range read',
      (tester) async {
        final boxes = await pumpParagraph(tester);
        expect(
          boxes.boxesFor(const TextRange(start: 2, end: 15)),
          hasLength(2),
        );
        expect(_n('paragraphLineMeasures'), 1);
        expect(_n('paragraphLineWalks'), 1);
        expect(boxes.boxesFor(const TextRange(start: 0, end: 4)), hasLength(1));
        expect(_n('paragraphLineMeasures'), 2);
        expect(_n('paragraphLineWalks'), 2);
      },
    );

    testWidgets(
      'a paragraph caret rect measures once while an offset query and a collapsed range measure nothing',
      (tester) async {
        final boxes = await pumpParagraph(tester);
        boxes.caretRect(14);
        expect(_n('paragraphLineMeasures'), 1);
        expect(_n('paragraphLineWalks'), 1);
        final before = PerfCounters.snapshot();
        boxes.offsetAt(const Offset(10, 5));
        expect(boxes.boxesFor(const TextRange.collapsed(3)), isEmpty);
        expect(PerfCounters.delta(before)['paragraphLineMeasures'], 0);
        expect(PerfCounters.delta(before)['paragraphLineWalks'], 0);
      },
    );
  });

  // --------------------------------------------- rows and marker columns

  group('row and marker column counters', () {
    testWidgets('an editor row counts one build per build', (tester) async {
      final c = LivePreviewController(text: 'hello');
      final focus = FocusNode();
      addTearDown(c.dispose);
      addTearDown(focus.dispose);
      PerfCounters.reset();
      await tester.pumpWidget(_wi125Row(c, focus));
      expect(_n('rowBuilds'), 1);
      await tester.pumpWidget(_wi125Row(c, focus));
      expect(_n('rowBuilds'), 2);
    });

    testWidgets('an editor row counts one selection paint per paint', (
      tester,
    ) async {
      final c = LivePreviewController(text: 'hello');
      final focus = FocusNode();
      addTearDown(c.dispose);
      addTearDown(focus.dispose);
      PerfCounters.reset();
      await tester.pumpWidget(_wi125Row(c, focus));
      expect(_n('rowSelectionPaints'), 1);
      // A frame with nothing dirty paints nothing.
      await tester.pump();
      expect(_n('rowSelectionPaints'), 1);
      c.value = const TextEditingValue(
        text: 'hello',
        selection: TextSelection(baseOffset: 0, extentOffset: 3),
      );
      await tester.pump();
      expect(_n('rowSelectionPaints'), 2);
    });

    testWidgets(
      'a marker column counts one build and one paint per build and paint',
      (tester) async {
        Widget column() => const MaterialApp(
          home: Scaffold(
            body: marker.MarkerColumn(marker: '- ', width: 24, readOnly: true),
          ),
        );
        PerfCounters.reset();
        await tester.pumpWidget(column());
        expect(_n('markerColumnBuilds'), 1);
        expect(_n('markerColumnPaints'), 1);
        await tester.pump();
        expect(_n('markerColumnBuilds'), 1);
        expect(_n('markerColumnPaints'), 1);
      },
    );

    testWidgets('a marker column counts a setState when its row changes', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(tester, body: '- one\n- two\n');
      PerfCounters.reset();
      await e.typeAtEnd(' more');
      await pumpFrames(tester);
      expect(_n('markerColumnSetStates'), greaterThan(0));
      expect(_n('markerColumnBuilds'), greaterThan(0));
    });

    testWidgets(
      'a segment counts a setState and a build when an edit re-derives its rows',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'First line\n\n- item\n',
        );
        PerfCounters.reset();
        await e.typeAtEnd(' more');
        await pumpFrames(tester);
        expect(_n('segmentSetStates'), greaterThan(0));
        expect(_n('segmentBuilds'), greaterThan(0));
        expect(_n('rowBuilds'), greaterThan(0));
      },
    );
  });

  // ---------------------------------------------------------- spelling

  group('spelling counters', () {
    testWidgets(
      'an evaluation pass adds one per viewport check and one per check all',
      (tester) async {
        final service = FakeSpellingService()..misspell('teh');
        final container = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final session = container.read(spellSessionProvider);
        final checker = SpellCheckController(
          noteId: 'wi125-note',
          sink: _Wi125Sink(),
          session: () => session,
          service: () => service,
          flags: (spelling: true, grammar: true),
        );
        addTearDown(checker.dispose);
        await _wi125WarmTag(tester, session, 'wi125-note');
        PerfCounters.reset();
        checker.viewportChanged();
        await tester.pump();
        expect(_n('spellEvaluations'), 1);
        final done = checker.checkAll();
        await tester.pump();
        await done;
        expect(_n('spellEvaluations'), 2);
      },
    );

    testWidgets(
      'a live preview field host counts one line lookup per line call',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Some words here.\n\n- an item\n',
        );
        final fieldFinder = find.byType(host.SpellCheckField).first;
        final field = tester.widget<host.SpellCheckField>(fieldFinder);
        final spellHost = tester.state(fieldFinder) as SpellFieldHost;
        expect(e.rowFields(0), findsWidgets);
        PerfCounters.reset();
        spellHost.line(field.controller);
        expect(_n('spellHostLineCalls'), 1);
        spellHost.line(field.controller);
        expect(_n('spellHostLineCalls'), 2);
      },
    );

    testWidgets(
      'a source mode field host counts one line lookup per line call',
      (tester) async {
        await pumpSpellingEditor(
          tester,
          body: 'Some words here.\n',
          source: true,
        );
        final fieldFinder = find.byType(host.SpellCheckField).first;
        final field = tester.widget<host.SpellCheckField>(fieldFinder);
        final spellHost = tester.state(fieldFinder) as SpellFieldHost;
        PerfCounters.reset();
        spellHost.line(field.controller);
        expect(_n('spellHostLineCalls'), 1);
      },
    );

    testWidgets(
      'check document now measures an issue rect before and after the frame',
      (tester) async {
        final spelling = FakeSpellingService()
          ..misspell('wrld', corrections: const ['world']);
        final e = await pumpSpellingEditor(
          tester,
          body: 'Start here.\n\nA wrld word.\n',
          spelling: spelling,
        );
        await e.advance(const Duration(seconds: 1));
        await e.advance(const Duration(seconds: 1));
        await e.robot.focusSegment(0, offset: 0);
        await pumpFrames(tester);
        PerfCounters.reset();
        spelling.emitCheckDocumentNow();
        await pumpFrames(tester);
        await pumpFrames(tester);
        // `_goTo` reads the rect once to scroll it into view and once after
        // the frame to anchor the menu.
        expect(_n('spellHostRectCalls'), 2);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------- find

  group('find counters', () {
    testWidgets(
      'a find highlight layer counts one update per update and a paint only when it changed',
      (tester) async {
        Widget layer(List<findhl.FindPaintRange> ranges) => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 100,
            height: 40,
            child: findhl.FindHighlights(ranges: ranges, boxes: () => null),
          ),
        );
        PerfCounters.reset();
        await tester.pumpWidget(layer(const []));
        expect(
          _n('findHighlightUpdates'),
          0,
          reason: 'creating is not updating',
        );
        expect(_n('findHighlightPaints'), 1);
        await tester.pumpWidget(layer(const []));
        expect(_n('findHighlightUpdates'), 1);
        expect(
          _n('findHighlightPaints'),
          1,
          reason: 'equal ranges repaint nothing',
        );
        await tester.pumpWidget(
          layer(const [
            findhl.FindPaintRange(0, 3, findhl.FindPaintStyle.other),
          ]),
        );
        expect(_n('findHighlightUpdates'), 2);
        expect(_n('findHighlightPaints'), 2);
      },
    );
  });
}

/// A [SpellIssueSink] over a map.
class _Wi125Sink implements SpellIssueSink {
  final issues = <TextEditingController, List<SpellIssue>>{};

  @override
  List<SpellIssue> issuesOf(TextEditingController field) =>
      issues[field] ?? const [];

  @override
  void setIssues(TextEditingController field, List<SpellIssue> value) =>
      issues[field] = value;

  @override
  void forget(TextEditingController field) => issues.remove(field);
}
