// WI #131 (Spec #122 Requirements 24, 25, 26): the contracts the perf tests of
// outline_tracker_test.dart and spell_viewport_test.dart count around but
// do not pin by value.
//
// - `SegmentViewState.rowsWithin` answers what a linear scan of the rows'
//   global tops and bottoms answers, at every edge (a row ending exactly at
//   the band top is out, a row starting exactly at the band bottom is out).
// - `SegmentViewState.rowLineOf` answers each row, also after the rows were
//   re-derived by an edit.
// - `OutlineSectionNotifier` notifies only of a different entry.
// - `revealLineRect` anchors on the line holding its offsets and falls back
//   to the whole row for a row that is not prose or whose text slot shows
//   another text.
// - A spell evaluation asks a run only for the fields its `fieldsWithin`
//   names (every field of a run that cannot tell), in join order.
//
// Helpers carry the `_t131c` prefix. Text is invented (public repo).
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart' show RowKind;
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/outline_section.dart';
import 'package:open_memex_app/src/state/spell_check_controller.dart';
import 'package:open_memex_app/src/state/spell_session_state.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/note_reveal.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';

import '../support/editor_rows_probe.dart';
import '../support/fake_clock.dart';
import '../support/fake_spelling_service.dart';
import '../support/font_fetch_hold.dart';
import '../support/spelling_editor_pump.dart';

// ------------------------------------------------------------ rowsWithin

/// Row [i]'s global top and bottom as its `EditorRow` box lays out.
({double top, double bottom}) _t131cEdges(SegmentViewState host, int i) {
  final box = host.rowContext(i)!.findRenderObject()! as RenderBox;
  return (
    top: box.localToGlobal(Offset.zero).dy,
    bottom: box.localToGlobal(Offset(0, box.size.height)).dy,
  );
}

/// The rows meeting [top]..[bottom] by a linear scan: a row meets it when it
/// ends below [top] and starts above [bottom].
({int first, int last}) _t131cScan(
  SegmentViewState host,
  double top,
  double bottom,
) {
  var first = host.rowCount;
  var last = -1;
  for (var i = 0; i < host.rowCount; i++) {
    final e = _t131cEdges(host, i);
    if (e.bottom > top && e.top < bottom) {
      if (i < first) first = i;
      last = i;
    }
  }
  return (first: first, last: last);
}

// ------------------------------------------------------- revealLineRect

/// A box [width] wide showing a wrapped `RichText` of [text].
Future<RenderBox> _t131cPumpRich(
  WidgetTester tester,
  String text, {
  double width = 60,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          key: key,
          width: width,
          child: RichText(
            text: TextSpan(text: text, style: const TextStyle(fontSize: 10)),
          ),
        ),
      ),
    ),
  );
  return key.currentContext!.findRenderObject()! as RenderBox;
}

RenderParagraph _t131cParagraph(WidgetTester tester) =>
    tester.renderObject<RenderParagraph>(find.byType(RichText));

// --------------------------------------------------------- spell fakes

/// A field host with fixed geometry inside every window, in no run.
class _T131cLooseHost implements SpellFieldHost {
  @override
  SpellFieldLine line(TextEditingController field) =>
      (line: field.text, base: 0, atSegmentStart: true);

  @override
  ({double top, double bottom})? extent() => (top: 0.0, bottom: 20.0);

  @override
  ({double top, double bottom})? extentAt(int offset) =>
      (top: 0.0, bottom: 20.0);

  @override
  ({double top, double bottom})? viewport() => (top: 0.0, bottom: 100.0);

  @override
  bool revealed(TextEditingController field) => true;

  @override
  ValueListenable<bool>? revealGate(TextEditingController field) => null;

  @override
  bool hasFocus(TextEditingController field) => false;
}

/// A field host of the run [run]; the run answers [within].
class _T131cRunHost extends _T131cLooseHost implements SpellFieldRun {
  _T131cRunHost(this.run, this.within);

  @override
  final Object? run;

  final List<TextEditingController>? Function(double top, double bottom) within;

  @override
  List<TextEditingController>? fieldsWithin(double top, double bottom) =>
      within(top, bottom);
}

class _T131cSink implements SpellIssueSink {
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

OutlineEntry _t131cEntry(String text) =>
    OutlineEntry(level: 2, depth: 0, text: text, segment: 0, local: 0);

void main() {
  holdFontFetches();

  // ------------------------------------------------------------ rowsWithin

  group('rowsWithin', () {
    testWidgets(
      'rowsWithin answers what a scan of the row tops and bottoms answers at every edge',
      (tester) async {
        final body = [for (var i = 0; i < 40; i++) '- Item $i is fine.'];
        await pumpSpellingEditor(tester, body: body.join('\n'));
        final host = rowsHostOf(tester);
        final count = host.rowCount;
        expect(count, greaterThan(30));

        final bands = <(String, double, double)>[];
        for (final k in [0, 1, 9, 20, count - 2]) {
          final a = _t131cEdges(host, k);
          final b = _t131cEdges(host, k + 1);
          // Row k ends exactly at the band top: it is out.
          bands.add(('top at the bottom of row $k', a.bottom, b.bottom + 1));
          // Row k starts exactly at the band bottom: it is out.
          bands.add(('bottom at the top of row $k', a.top - 40, a.top));
          // A band exactly one row's.
          bands.add(('exactly row $k', a.top, a.bottom));
          // Inside row k only.
          bands.add((
            'inside row $k',
            a.top + 1,
            a.top + (a.bottom - a.top) / 2,
          ));
        }
        final first = _t131cEdges(host, 0);
        final last = _t131cEdges(host, count - 1);
        bands
          ..add(('the whole segment', first.top - 5, last.bottom + 5))
          ..add(('above the segment', first.top - 100, first.top))
          ..add(('below the segment', last.bottom, last.bottom + 100));

        for (final (name, top, bottom) in bands) {
          final got = host.rowsWithin(top, bottom);
          final want = _t131cScan(host, top, bottom);
          expect(got, isNotNull, reason: name);
          if (want.first > want.last) {
            expect(got!.first > got.last, isTrue, reason: '$name: no row');
          } else {
            expect(got, (first: want.first, last: want.last), reason: name);
          }
        }
      },
    );

    testWidgets(
      'rowsWithin of a band over a few rows of 600 reads a bisection of row boxes not every row',
      (tester) async {
        final body = [for (var i = 0; i < 600; i++) '- Item $i is fine.'];
        await pumpSpellingEditor(tester, body: body.join('\n'));
        final host = rowsHostOf(tester);
        final count = host.rowCount;
        expect(count, greaterThan(500));
        final top = _t131cEdges(host, 300).top;
        final bottom = _t131cEdges(host, 305).bottom;
        final want = _t131cScan(host, top, bottom);
        expect(want.first, lessThan(want.last), reason: 'a band of rows');

        SegmentViewState.debugRowEdgeReads = 0;
        final got = host.rowsWithin(top, bottom);
        final reads = SegmentViewState.debugRowEdgeReads;

        expect(got, (first: want.first, last: want.last));
        expect(reads, greaterThan(0), reason: 'it reads the row boxes');
        // Two bisections over `count` rows: log2(count) + 1 reads each.
        final probes = 2 * (math.log(count) / math.ln2).ceil() + 2;
        expect(
          reads,
          lessThanOrEqualTo(probes),
          reason: 'a bisection over $count rows is at most $probes reads',
        );
      },
    );

    testWidgets(
      'rowsWithin of a band of zero height at a row top finds no row',
      (tester) async {
        await pumpSpellingEditor(
          tester,
          body: '- one\n- two\n- three\n- four\n- five\n',
        );
        final host = rowsHostOf(tester);
        final top = _t131cEdges(host, 2).top;
        final got = host.rowsWithin(top, top);
        expect(got, isNotNull);
        expect(got!.first > got.last, isTrue, reason: 'an empty band');
      },
    );
  });

  // ------------------------------------------------------------ rowLineOf

  group('rowLineOf', () {
    testWidgets(
      'rowLineOf answers each row line before and after an edit re-derives the rows',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'First line here.\n\n- item one\n- item two\n',
        );
        void check(String when) {
          final host = rowsHostOf(tester);
          expect(host.rowCount, greaterThan(2), reason: when);
          for (var i = 0; i < host.rowCount; i++) {
            final spec = host.rowSpec(i)!;
            final got = host.rowLineOf(host.rowController(i)!);
            expect(got, isNotNull, reason: '$when: row $i');
            expect(
              got!.line,
              host.text.substring(spec.start, spec.textEnd),
              reason: '$when: row $i line',
            );
            expect(
              got.textStart,
              spec.textStart - spec.start,
              reason: '$when: row $i textStart',
            );
            expect(
              got.atSegmentStart,
              spec.start == 0,
              reason: '$when: row $i',
            );
          }
          expect(
            host.rowLineOf(TextEditingController()),
            isNull,
            reason: '$when: a controller of no row',
          );
        }

        check('first look');
        final before = rowsHostOf(tester).rowCount;
        await e.typeAtEnd('- item three\n- item four\n');
        expect(
          rowsHostOf(tester).rowCount,
          greaterThan(before),
          reason: 'the edit added rows',
        );
        check('after the edit');
      },
    );
  });

  group('rowLineOf work', () {
    testWidgets(
      'rowLineOf of every row of 600 builds the row index once per re-derive not once per call',
      (tester) async {
        final body = [for (var i = 0; i < 600; i++) '- Item $i is fine.'];
        final e = await pumpSpellingEditor(tester, body: body.join('\n'));
        final count = rowsHostOf(tester).rowCount;
        expect(count, greaterThan(500));

        void lookUpEveryRow() {
          final host = rowsHostOf(tester);
          for (var i = 0; i < host.rowCount; i++) {
            expect(host.rowLineOf(host.rowController(i)!), isNotNull);
          }
        }

        // Every row looked up after the first pump, then after an edit that
        // re-derives the rows: an index is built for each list of rows,
        // never one per call.
        SegmentViewState.debugRowIndexBuilds = 0;
        lookUpEveryRow();
        lookUpEveryRow();
        expect(
          SegmentViewState.debugRowIndexBuilds,
          inInclusiveRange(0, 1),
          reason: 'a second look up of the same rows builds nothing',
        );

        SegmentViewState.debugRowIndexBuilds = 0;
        await e.typeAtEnd('\n- item added\n');
        lookUpEveryRow();
        final builds = SegmentViewState.debugRowIndexBuilds;
        expect(
          builds,
          greaterThan(0),
          reason: 'the re-derived rows need an index of their own',
        );
        expect(
          builds,
          lessThanOrEqualTo(3),
          reason: 'one index per list of rows, $count look ups',
        );
      },
    );
  });

  // ------------------------------------------------------- section notify

  group('current section notifier', () {
    test(
      'an equal but new current entry is kept and does not notify listeners',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final hub = container.read(outlineSectionHubProvider);
        var heard = 0;
        final sub = container.listen(outlineSectionProvider, (_, _) => heard++);
        final tracker = Object();

        final first = _t131cEntry('Plan');
        hub.report(tracker, first);
        expect(heard, 1, reason: 'a first entry');
        expect(identical(sub.read(), first), isTrue);

        final again = _t131cEntry('Plan');
        expect(identical(first, again), isFalse);
        hub.report(tracker, again);
        expect(heard, 1, reason: 'an equal entry is not news');
        expect(
          identical(sub.read(), again),
          isTrue,
          reason: 'the newest entry of the shared computation is held',
        );

        hub.report(tracker, _t131cEntry('Other'));
        expect(heard, 2, reason: 'a different entry');
        hub.report(tracker, null);
        expect(heard, 3, reason: 'no entry');
      },
    );
  });

  // -------------------------------------------------------- revealLineRect

  group('revealLineRect', () {
    const text = 'aaaa bbbb cccc dddd';

    testWidgets(
      'revealLineRect of a prose RichText row anchors on the line holding its offset',
      (tester) async {
        final row = await _t131cPumpRich(tester, text);
        final lines = RenderParagraphLineBoxes(_t131cParagraph(tester)).lines;
        expect(lines.length, 4);
        final rect = revealLineRect(
          row,
          kind: RowKind.prose,
          rowText: text,
          local: 6,
        );
        expect(rect.left, 0);
        expect(rect.width, row.size.width);
        expect(rect.top, lines[1].top);
        expect(rect.bottom, lines[1].bottom);
      },
    );

    testWidgets(
      'revealLineRect with an end spans from the line of its offset to the line holding the last character',
      (tester) async {
        final row = await _t131cPumpRich(tester, text);
        final lines = RenderParagraphLineBoxes(_t131cParagraph(tester)).lines;
        final rect = revealLineRect(
          row,
          kind: RowKind.prose,
          rowText: text,
          local: 6,
          end: 12,
        );
        expect(rect.top, lines[1].top);
        expect(rect.bottom, lines[2].bottom);
      },
    );

    testWidgets(
      'revealLineRect with an end at its offset or before it anchors on one line',
      (tester) async {
        final row = await _t131cPumpRich(tester, text);
        final lines = RenderParagraphLineBoxes(_t131cParagraph(tester)).lines;
        // Offset 5 starts line 1; the character before it ends line 0.
        for (final end in [5, 2]) {
          final rect = revealLineRect(
            row,
            kind: RowKind.prose,
            rowText: text,
            local: 5,
            end: end,
          );
          expect(rect.top, lines[1].top, reason: 'end $end');
          expect(rect.bottom, lines[1].bottom, reason: 'end $end');
        }
      },
    );

    testWidgets('revealLineRect of a row that is not prose is the whole row', (
      tester,
    ) async {
      final row = await _t131cPumpRich(tester, text);
      for (final kind in [RowKind.bullet, RowKind.code, null]) {
        expect(
          revealLineRect(row, kind: kind, rowText: text, local: 6),
          Offset.zero & row.size,
          reason: '$kind',
        );
      }
    });

    testWidgets(
      'revealLineRect of a RichText showing another length of text is the whole row',
      (tester) async {
        final row = await _t131cPumpRich(tester, text);
        for (final other in ['$text more', 'aaaa bbbb', '']) {
          expect(
            revealLineRect(row, kind: RowKind.prose, rowText: other, local: 6),
            Offset.zero & row.size,
            reason: 'row text "$other"',
          );
        }
      },
    );

    testWidgets(
      'revealLineRect of a field anchors on its line only while the field holds the row text',
      (tester) async {
        final controller = TextEditingController(text: text);
        addTearDown(controller.dispose);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: key,
                width: 60,
                child: EditableText(
                  controller: controller,
                  focusNode: focus,
                  style: const TextStyle(fontSize: 10),
                  cursorColor: Colors.black,
                  backgroundCursorColor: Colors.grey,
                  maxLines: null,
                ),
              ),
            ),
          ),
        );
        final row = key.currentContext!.findRenderObject()! as RenderBox;
        final field = textSlotBox(row) as RenderEditable;
        final lines = RenderEditableLineBoxes(field).lines;
        expect(lines.length, greaterThan(2));
        final line = lines.lastWhere((l) => l.range.start <= 6);
        final rect = revealLineRect(
          row,
          kind: RowKind.prose,
          rowText: text,
          local: 6,
        );
        expect(rect.top, line.top);
        expect(rect.bottom, line.bottom);
        expect(
          revealLineRect(
            row,
            kind: RowKind.prose,
            rowText: 'something else',
            local: 6,
          ),
          Offset.zero & row.size,
          reason: 'the field shows another text',
        );
      },
    );
  });

  // ------------------------------------------------------ spell near fields

  group('spell evaluation fields', () {
    testWidgets(
      'an evaluation asks a run only for the fields it names near the viewport and every field of a run that cannot tell, in join order',
      (tester) async {
        final service = FakeSpellingService();
        final clock = FakeClock();
        final container = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);
        final session = container.read(spellSessionProvider);
        final checker = SpellCheckController(
          noteId: 't131c-note',
          sink: _T131cSink(),
          session: () => session,
          service: () => service,
          flags: (spelling: true, grammar: false),
          clock: clock,
        );
        addTearDown(checker.dispose);
        final warm = session.documentTag('t131c-note');
        await tester.pump();
        await warm;

        TextEditingController field(String t) {
          final c = TextEditingController(text: t);
          addTearDown(c.dispose);
          return c;
        }

        final a0 = field('Alpha zero text.');
        final loose = field('Loose field text.');
        final a1 = field('Alpha one text.');
        final b0 = field('Beta zero text.');
        final a2 = field('Alpha two text.');
        final b1 = field('Beta one text.');
        final a3 = field('Alpha three text.');
        final bands = <(double, double)>[];
        final runA = Object();
        final runB = Object();
        final hostA = _T131cRunHost(runA, (top, bottom) {
          bands.add((top, bottom));
          return [a1, a3];
        });
        final hostB = _T131cRunHost(runB, (top, bottom) => null);
        checker
          ..addField(a0, hostA)
          ..addField(loose, _T131cLooseHost())
          ..addField(a1, hostA)
          ..addField(b0, hostB)
          ..addField(a2, hostA)
          ..addField(b1, hostB)
          ..addField(a3, hostA);

        checker.viewportChanged();
        clock.advance(spellCheckDebounce);
        await tester.pump();

        expect(
          [for (final c in service.callsFor('check')) c.args['text']],
          [
            'Loose field text.',
            'Alpha one text.',
            'Beta zero text.',
            'Beta one text.',
            'Alpha three text.',
          ],
          reason: 'loose, the named fields of run A and all of run B, joined',
        );
        // One screen above to one screen below a 0..100 viewport.
        expect(bands, [(-100.0, 200.0)]);
      },
    );
  });
}
