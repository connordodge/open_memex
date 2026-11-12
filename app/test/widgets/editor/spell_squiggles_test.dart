// WI #437 (Spec #392 reqs 6, 7, 9, 21): painted spelling and grammar
// squiggles, and the row semantics hint.
//
// Issues are seeded straight into the note editor's SpellIssueRegistry
// (`setIssues` on a row field's controller); the E3 scheduler is not part
// of this WI.
//
// Pixel probes (architect's probe rule): a squiggle lives in the band from
// its line's baseline + 2 to baseline + 4 px. Each probe compares a capture
// WITH the issue against one WITHOUT it in the same state, so only what the
// squiggle paints differs; a changed pixel's coverage is how far it moved
// from the pixel underneath toward the squiggle colour. Expected baselines
// and character rects come from oracles independent of the WI: the field's
// own span laid out again (computeLineMetrics) and the existing line box
// seam's boxesFor, both on the real editor field with its strut.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';
import 'package:open_memex_app/src/widgets/editor/spell_squiggles.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/spelling_editor_pump.dart';

// ------------------------------------------------------------------ issues

SpellIssue _wi437Spelling(TextRange r) => SpellIssue(
  kind: SpellIssueKind.spelling,
  start: r.start,
  length: r.end - r.start,
  corrections: const ['the'],
);

SpellIssue _wi437Grammar(TextRange r, String description) => SpellIssue(
  kind: SpellIssueKind.grammar,
  start: r.start,
  length: r.end - r.start,
  description: description,
);

/// The [n]th (0-based) occurrence of [word] in [text].
TextRange _wi437Find(String text, String word, [int n = 0]) {
  var at = -1;
  for (var i = 0; i <= n; i++) {
    at = text.indexOf(word, at + 1);
    if (at < 0) throw TestFailure('fixture: no "$word" #$n in "$text"');
  }
  return TextRange(start: at, end: at + word.length);
}

// ------------------------------------------------------------------ fields

TextEditingController _wi437Ctrl(WidgetTester tester, Finder field) =>
    tester.widget<EditableText>(field).controller;

String _wi437Text(WidgetTester tester, Finder field) =>
    _wi437Ctrl(tester, field).text;

RenderEditable _wi437Editable(WidgetTester tester, Finder field) =>
    findRenderEditable(tester.renderObject(field))!;

/// Seeds [field]'s issues in the registry its note editor hands down, then
/// pumps one frame.
Future<void> _wi437Flag(
  WidgetTester tester,
  Finder field,
  List<SpellIssue> issues,
) async {
  final registry = SpellIssueScope.maybeOf(tester.element(field));
  expect(registry, isNotNull, reason: 'fixture: the field has a registry');
  registry!.setIssues(_wi437Ctrl(tester, field), issues);
  await tester.pump();
}

/// Takes focus away from the editor (no caret blinks between captures).
Future<void> _wi437Unfocus(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

/// The row field of live preview text segment 0 whose text contains [text].
Finder _wi437RowWith(SpellingEditorHarness e, String text) {
  final rows = e.rowFields(0);
  for (var i = 0; i < rows.evaluate().length; i++) {
    final row = rows.at(i);
    if (_wi437Text(e.tester, row).contains(text)) return row;
  }
  throw TestFailure('fixture: no row holding "$text"');
}

/// Oracle: every line's baseline of [editable]'s laid-out text, in its local
/// coordinates (vertical scroll applied), from its own span laid out again
/// with its strut and scaler (`computeLineMetrics`).
List<double> _wi437Baselines(RenderEditable editable) {
  final multiline = editable.maxLines != 1;
  final painter = TextPainter(
    text: editable.text,
    textAlign: editable.textAlign,
    textDirection: editable.textDirection,
    textScaler: editable.textScaler,
    locale: editable.locale,
    maxLines: multiline ? null : 1,
    strutStyle: editable.strutStyle,
    textHeightBehavior: editable.textHeightBehavior,
    textWidthBasis: editable.textWidthBasis,
  );
  try {
    final available = editable.constraints.maxWidth - 1 - editable.cursorWidth;
    painter.layout(
      minWidth: editable.forceLine ? available : 0,
      maxWidth: multiline ? available : double.infinity,
    );
    final scroll = multiline ? editable.offset.pixels : 0.0;
    return [for (final m in painter.computeLineMetrics()) m.baseline - scroll];
  } finally {
    painter.dispose();
  }
}

/// One line's part of a flagged range: its characters' rect (the line box's
/// full height) and the line's baseline, both global.
typedef _Wi437Part = ({Rect chars, double baseline});

/// Where [range] of [field] lies, one part per line it covers.
List<_Wi437Part> _wi437Parts(
  WidgetTester tester,
  Finder field,
  TextRange range,
) {
  final editable = _wi437Editable(tester, field);
  final origin = editable.localToGlobal(Offset.zero);
  final baselines = _wi437Baselines(editable);
  return [
    for (final rect in RenderEditableLineBoxes(editable).boxesFor(range))
      (
        chars: rect.shift(origin),
        baseline:
            baselines.firstWhere(
              (b) => b > rect.top && b < rect.bottom,
              orElse: () => throw TestFailure('fixture: no baseline in $rect'),
            ) +
            origin.dy,
      ),
  ];
}

/// The single line part of [range].
_Wi437Part _wi437Part1(WidgetTester tester, Finder field, TextRange range) {
  final parts = _wi437Parts(tester, field, range);
  expect(parts, hasLength(1), reason: 'fixture: $range lies on one line');
  return parts.single;
}

// ------------------------------------------------------------------ pixels

/// The RGBA pixels of the whole screen (the root repaint boundary).
final class _Wi437Shot {
  _Wi437Shot(this._bytes, this.width, this.height, this._origin);

  final ByteData _bytes;
  final int width;
  final int height;
  final Offset _origin;

  /// The pixel at global column [x], row [y] (whole pixels), as 0..255
  /// channels r, g, b.
  List<int> rgb(int x, int y) {
    final px = x - _origin.dx.round();
    final py = y - _origin.dy.round();
    if (px < 0 || py < 0 || px >= width || py >= height) {
      throw TestFailure('pixel ($x, $y) is off screen');
    }
    final i = (py * width + px) * 4;
    return [_bytes.getUint8(i), _bytes.getUint8(i + 1), _bytes.getUint8(i + 2)];
  }
}

Future<_Wi437Shot> _wi437Capture(WidgetTester tester) async {
  final render = tester.renderObject<RenderRepaintBoundary>(
    find
        .ancestor(
          of: find.byType(NoteEditor),
          matching: find.byType(RepaintBoundary),
        )
        .last,
  );
  final image = (await tester.runAsync(() => render.toImage()))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final shot = _Wi437Shot(
    bytes,
    image.width,
    image.height,
    render.localToGlobal(Offset.zero),
  );
  image.dispose();
  return shot;
}

List<int> _wi437Channels(Color c) => [
  (c.r * 255).round(),
  (c.g * 255).round(),
  (c.b * 255).round(),
];

String _wi437Hex(List<int> c) =>
    '#${c.map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

/// How far pixel [after] moved from [before] toward [target], 0..1, read on
/// the channel where [target] differs most from [before]; null when [before]
/// is too close to [target] to tell.
double? _wi437Coverage(List<int> before, List<int> after, List<int> target) {
  var k = 0;
  for (var j = 1; j < 3; j++) {
    if ((target[j] - before[j]).abs() > (target[k] - before[k]).abs()) k = j;
  }
  final span = target[k] - before[k];
  if (span.abs() < 40) return null;
  return ((after[k] - before[k]) / span).clamp(0.0, 1.0);
}

bool _wi437Changed(List<int> before, List<int> after) {
  for (var j = 0; j < 3; j++) {
    if ((after[j] - before[j]).abs() > 6) return true;
  }
  return false;
}

/// Expects a squiggle in [color] under [part]: in the band from its
/// baseline + 2 to + 4 px, under every character column of [part], 1 px
/// thick, and nothing else changed between [before] and [after] around it.
void _wi437ExpectSquiggle(
  _Wi437Shot before,
  _Wi437Shot after,
  _Wi437Part part, {
  required Color color,
  required String what,
}) {
  final target = _wi437Channels(color);
  final chars = part.chars;
  final bandTop = part.baseline + 2;
  final bandBottom = part.baseline + 4;
  final rowFirst = bandTop.floor();
  final rowLast = bandBottom.ceil() - 1;
  final colFirst = chars.left.floor() - 1;
  final colLast = chars.right.ceil();

  // Nothing outside the band and the flagged characters changed.
  final window = Rect.fromLTRB(
    chars.left - 24,
    chars.top - 2,
    chars.right + 24,
    chars.bottom + 2,
  );
  for (var y = window.top.floor(); y <= window.bottom.ceil(); y++) {
    for (var x = window.left.floor(); x <= window.right.ceil(); x++) {
      final inside =
          y >= rowFirst && y <= rowLast && x >= colFirst && x <= colLast;
      if (inside) continue;
      final b = before.rgb(x, y);
      final a = after.rgb(x, y);
      if (_wi437Changed(b, a)) {
        fail(
          '$what: pixel ($x, $y) changed ${_wi437Hex(b)} -> ${_wi437Hex(a)} '
          'outside the band rows $rowFirst..$rowLast (baseline '
          '${part.baseline.toStringAsFixed(2)} + 2..4) and columns '
          '$colFirst..$colLast of the flagged characters',
        );
      }
    }
  }

  // Every character column carries the squiggle, in its colour.
  final missing = <int>[];
  final sums = <double>[];
  for (var x = chars.left.ceil() + 1; x <= chars.right.floor() - 2; x++) {
    var sum = 0.0;
    for (var y = rowFirst; y <= rowLast; y++) {
      final b = before.rgb(x, y);
      final a = after.rgb(x, y);
      final c = _wi437Coverage(b, a, target);
      if (c == null) continue;
      if (c >= 0.3) {
        for (var j = 0; j < 3; j++) {
          final want = b[j] + c * (target[j] - b[j]);
          if ((a[j] - want).abs() > 24) {
            fail(
              '$what: pixel ($x, $y) ${_wi437Hex(a)} over ${_wi437Hex(b)} is not '
              '${_wi437Hex(target)} at coverage ${c.toStringAsFixed(2)}',
            );
          }
        }
      }
      sum += c;
    }
    sums.add(sum);
    if (sum < 0.35) missing.add(x);
  }
  expect(sums, isNotEmpty, reason: '$what: fixture: the range has columns');
  expect(
    missing,
    isEmpty,
    reason:
        '$what: every column of the flagged characters '
        '(${chars.left.toStringAsFixed(1)}..${chars.right.toStringAsFixed(1)}) '
        'shows the squiggle in rows $rowFirst..$rowLast',
  );
  final mean = sums.reduce((a, b) => a + b) / sums.length;
  expect(
    mean,
    inInclusiveRange(0.6, 1.7),
    reason: '$what: the squiggle is 1 px thick (mean column coverage)',
  );
}

/// Expects nothing changed between [before] and [after] inside [window]
/// (global).
void _wi437ExpectNoChange(
  _Wi437Shot before,
  _Wi437Shot after,
  Rect window, {
  required String what,
}) {
  for (var y = window.top.floor(); y <= window.bottom.ceil(); y++) {
    for (var x = window.left.floor(); x <= window.right.ceil(); x++) {
      final b = before.rgb(x, y);
      final a = after.rgb(x, y);
      if (_wi437Changed(b, a)) {
        fail(
          '$what: pixel ($x, $y) changed ${_wi437Hex(b)} -> ${_wi437Hex(a)}',
        );
      }
    }
  }
}

/// The window around [part] that a squiggle would change.
Rect _wi437Around(_Wi437Part part) => Rect.fromLTRB(
  part.chars.left - 8,
  part.chars.top,
  part.chars.right + 8,
  part.chars.bottom + 2,
);

// ------------------------------------------------------------------ geometry

/// Everything about [field]'s layout an issue must not change.
String _wi437Geometry(WidgetTester tester, Finder field) {
  final editable = _wi437Editable(tester, field);
  final boxes = RenderEditableLineBoxes(editable);
  final text = _wi437Text(tester, field);
  final out = StringBuffer()
    ..writeln('text: $text')
    ..writeln('span: ${editable.text!.toStringDeep()}')
    ..writeln('size: ${editable.size}')
    ..writeln('at: ${editable.localToGlobal(Offset.zero)}');
  for (final line in boxes.lines) {
    out.writeln('line ${line.range} ${line.top} ${line.bottom}');
  }
  for (var i = 0; i <= text.length; i++) {
    out.writeln('caret $i ${boxes.caretRect(i)}');
  }
  return out.toString();
}

// ------------------------------------------------------------------ semantics

/// Every non-empty semantics hint on [field]'s semantics node, its
/// descendants and its ancestors: the hints that belong to its row.
List<String> _wi437HintsOf(WidgetTester tester, Finder field) {
  final node = tester.getSemantics(field);
  final hints = <String>[];
  void down(SemanticsNode n) {
    hints.add(n.getSemanticsData().hint);
    n.visitChildren((c) {
      down(c);
      return true;
    });
  }

  down(node);
  for (var p = node.parent; p != null; p = p.parent) {
    hints.add(p.getSemanticsData().hint);
  }
  return hints.where((h) => h.isNotEmpty).toList();
}

bool _wi437SpellHint(String hint) =>
    hint.contains('misspelled') || hint.contains('grammar:');

void main() {
  holdFontFetches();

  // ------------------------------------------------------------------- AC2
  group('look (AC2)', () {
    testWidgets(
      'a spelling issue paints a 1 px wavy underline in OmColors.danger from baseline plus 2 exactly under the flagged characters',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'teh cat adn dog\n');
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);

        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh',
        );
        // The unflagged words stay unmarked.
        final rest = _wi437Part1(
          tester,
          row,
          TextRange(
            start: teh.end + 1,
            end: _wi437Text(tester, row).indexOf('\n'),
          ),
        );
        _wi437ExpectNoChange(
          before,
          after,
          Rect.fromLTRB(
            rest.chars.left + 1,
            rest.chars.top,
            rest.chars.right,
            rest.chars.bottom,
          ),
          what: 'cat adn dog',
        );
      },
    );

    testWidgets(
      'a grammar issue paints a 1 px wavy underline in OmColors.info from baseline plus 2 exactly under the flagged characters',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'they was here today\n',
        );
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final range = _wi437Find(_wi437Text(tester, row), 'they was');
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [
          _wi437Grammar(range, 'Possible agreement error'),
        ]);
        final after = await _wi437Capture(tester);

        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, range),
          color: OmColors.info,
          what: 'they was',
        );
      },
    );

    testWidgets(
      'a spelling and a grammar issue in one row each paint in their own colour',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat they was here\n',
        );
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final text = _wi437Text(tester, row);
        final teh = _wi437Find(text, 'teh');
        final grammar = _wi437Find(text, 'they was');
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [
          _wi437Spelling(teh),
          _wi437Grammar(grammar, 'Possible agreement error'),
        ]);
        final after = await _wi437Capture(tester);

        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'spelling teh',
        );
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, grammar),
          color: OmColors.info,
          what: 'grammar they was',
        );
      },
    );
  });

  // ------------------------------------------------------------------- AC3
  group('placement (AC3)', () {
    testWidgets('a squiggle sits at baseline plus 2 on a plain row', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'first line here\n\nteh cat\n',
      );
      await _wi437Unfocus(tester);
      final row = _wi437RowWith(e, 'teh cat');
      final teh = _wi437Find(_wi437Text(tester, row), 'teh');
      final before = await _wi437Capture(tester);
      await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
      final after = await _wi437Capture(tester);
      _wi437ExpectSquiggle(
        before,
        after,
        _wi437Part1(tester, row, teh),
        color: OmColors.danger,
        what: 'plain row, third line',
      );
    });

    testWidgets(
      'a flagged range that wraps paints on both of its lines at each line baseline plus 2',
      (tester) async {
        final words = [
          for (var i = 0; i < 60; i++) 'w${i.toString().padLeft(2, '0')}',
        ];
        final e = await pumpSpellingEditor(
          tester,
          body: '${words.join(' ')}\n',
        );
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final editable = _wi437Editable(tester, row);
        final lines = RenderEditableLineBoxes(editable).lines;
        expect(
          lines.length,
          greaterThanOrEqualTo(2),
          reason: 'fixture: the paragraph wraps',
        );
        // The last word of the first visual line through the first word of
        // the second.
        final wrapAt = lines[1].range.start;
        final range = TextRange(start: wrapAt - 4, end: wrapAt + 3);
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(range)]);
        final after = await _wi437Capture(tester);

        final parts = _wi437Parts(tester, row, range);
        expect(parts, hasLength(2), reason: 'fixture: the range wraps');
        expect(
          parts[1].baseline - parts[0].baseline,
          greaterThan(5),
          reason: 'fixture: two visual lines',
        );
        _wi437ExpectSquiggle(
          before,
          after,
          parts[0],
          color: OmColors.danger,
          what: 'first line of the wrapped range',
        );
        _wi437ExpectSquiggle(
          before,
          after,
          parts[1],
          color: OmColors.danger,
          what: 'second line of the wrapped range',
        );
      },
    );

    for (final (name, level) in [
      ('a squiggle sits at baseline plus 2 on an H1 heading', 1),
      ('a squiggle sits at baseline plus 2 on an H2 heading', 2),
      ('a squiggle sits at baseline plus 2 on an H3 heading', 3),
    ]) {
      testWidgets(name, (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'body line\n\n${'#' * level} Heading teh\n\nafter\n',
        );
        await _wi437Unfocus(tester);
        final row = _wi437RowWith(e, 'Heading teh');
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final before = await _wi437Capture(tester);
        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);

        final part = _wi437Part1(tester, row, teh);
        final body = _wi437Part1(
          tester,
          row,
          _wi437Find(_wi437Text(tester, row), 'body'),
        );
        expect(
          part.chars.height,
          greaterThan(body.chars.height + 1),
          reason: 'fixture: the H$level line lays out taller than a body line',
        );
        _wi437ExpectSquiggle(
          before,
          after,
          part,
          color: OmColors.danger,
          what: 'H$level',
        );
      });
    }

    testWidgets('a squiggle sits at baseline plus 2 on a list item row', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'intro\n\n- item teh\n- next one\n',
      );
      await _wi437Unfocus(tester);
      final row = _wi437RowWith(e, 'item teh');
      final view = tester.widget<EditorRow>(
        find.ancestor(of: row, matching: find.byType(EditorRow)),
      );
      expect(view.kind, RowKind.bullet, reason: 'fixture: a list item row');
      final teh = _wi437Find(_wi437Text(tester, row), 'teh');
      final before = await _wi437Capture(tester);
      await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
      final after = await _wi437Capture(tester);
      _wi437ExpectSquiggle(
        before,
        after,
        _wi437Part1(tester, row, teh),
        color: OmColors.danger,
        what: 'list item',
      );
    });

    testWidgets('a squiggle sits at baseline plus 2 in Source mode', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: '# Title\n\nsome text\n\nteh cat\n',
        source: true,
      );
      await _wi437Unfocus(tester);
      final field = e.sourceField;
      final teh = _wi437Find(_wi437Text(tester, field), 'teh');
      final before = await _wi437Capture(tester);
      await _wi437Flag(tester, field, [_wi437Spelling(teh)]);
      final after = await _wi437Capture(tester);
      _wi437ExpectSquiggle(
        before,
        after,
        _wi437Part1(tester, field, teh),
        color: OmColors.danger,
        what: 'Source mode',
      );
    });

    testWidgets(
      'a grammar issue in Source mode paints in OmColors.info at baseline plus 2',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'they was here\n',
          source: true,
        );
        await _wi437Unfocus(tester);
        final field = e.sourceField;
        final range = _wi437Find(_wi437Text(tester, field), 'they was');
        final before = await _wi437Capture(tester);
        await _wi437Flag(tester, field, [
          _wi437Grammar(range, 'Possible agreement error'),
        ]);
        final after = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, field, range),
          color: OmColors.info,
          what: 'Source mode grammar',
        );
      },
    );

    testWidgets(
      'after the editor scrolls the squiggle stays under its flagged word',
      (tester) async {
        final filler = [for (var i = 0; i < 70; i++) 'line $i'].join('\n\n');
        final e = await pumpSpellingEditor(
          tester,
          body: '$filler\n\nteh cat\n\n$filler\n',
        );
        await _wi437Unfocus(tester);
        final row = _wi437RowWith(e, 'teh cat');
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        // Scroll the word to y 500 (the editor page scrolls; the whole body
        // is one prose row), flag it, then scroll 60 px further.
        final scrollable = find
            .ancestor(of: row, matching: find.byType(Scrollable))
            .last;
        final position = tester.state<ScrollableState>(scrollable).position;
        final y = _wi437Part1(tester, row, teh).chars.top;
        position.jumpTo(position.pixels + y - 500);
        await tester.pump();
        expect(
          _wi437Part1(tester, row, teh).chars.top,
          moreOrLessEquals(500, epsilon: 1),
          reason: 'fixture: the page scrolled the word to y 500',
        );
        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);

        position.jumpTo(position.pixels + 60);
        await tester.pump();
        expect(
          _wi437Part1(tester, row, teh).chars.top,
          moreOrLessEquals(440, epsilon: 1),
          reason: 'fixture: the word moved up with the scroll',
        );
        final with_ = await _wi437Capture(tester);
        await _wi437Flag(tester, row, const []);
        final without = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          without,
          with_,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'after a scroll',
        );
      },
    );

    testWidgets(
      'after the editor narrows the squiggle follows its rewrapped word',
      (tester) async {
        final words = [
          for (var i = 0; i < 60; i++) 'w${i.toString().padLeft(2, '0')}',
        ];
        final e = await pumpSpellingEditor(
          tester,
          body: '${words.join(' ')} teh end\n',
        );
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final wide = _wi437Part1(tester, row, teh);

        tester.view.physicalSize = const Size(1100, 1000);
        await tester.pump();
        await tester.pump();
        final narrow = _wi437Part1(tester, row, teh);
        expect(
          (narrow.chars.topLeft - wide.chars.topLeft).distance,
          greaterThan(20),
          reason: 'fixture: the word moved when the text rewrapped',
        );
        final with_ = await _wi437Capture(tester);
        await _wi437Flag(tester, row, const []);
        final without = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          without,
          with_,
          narrow,
          color: OmColors.danger,
          what: 'after a rewrap',
        );
      },
    );
  });

  // ------------------------------------------------------------------- AC4
  group('tables (AC4)', () {
    testWidgets(
      'an unrevealed table row paints no squiggle and its issues paint once the table is revealed',
      (tester) async {
        final previous = EditableText.debugDeterministicCursor;
        EditableText.debugDeterministicCursor = true;
        addTearDown(() => EditableText.debugDeterministicCursor = previous);

        await pumpSpellingEditor(
          tester,
          body: 'intro\n\n| a | b |\n| - | - |\n| teh | x |\n\nafter\n',
        );
        await _wi437Unfocus(tester);
        final tableRow = find.byWidgetPredicate(
          (w) => w is EditorRow && w.kind == RowKind.table,
          skipOffstage: false,
        );
        expect(tableRow, findsOneWidget, reason: 'fixture: one table row');
        final field = find.descendant(
          of: tableRow,
          matching: find.byType(EditableText, skipOffstage: false),
          skipOffstage: false,
        );
        expect(
          find.descendant(of: tableRow, matching: find.byType(EditableText)),
          findsNothing,
          reason: 'fixture: the table renders as a grid, its field offstage',
        );
        final text = _wi437Text(tester, field);
        final teh = _wi437Find(text, 'teh');

        // Unrevealed: nothing anywhere in the table row changes.
        final before = await _wi437Capture(tester);
        await _wi437Flag(tester, field, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);
        final rowRect = tester.getRect(tableRow);
        _wi437ExpectNoChange(
          before,
          after,
          Rect.fromLTRB(
            rowRect.left,
            rowRect.top,
            rowRect.right - 1,
            rowRect.bottom + 4,
          ),
          what: 'unrevealed table',
        );

        // Revealed (the caret in the table): the issue paints.
        final segment = segmentEditingAt(tester, 0);
        final caret = segment.text.indexOf('| x |') + 2;
        await tester.showKeyboard(field);
        await tester.pump();
        segment.select(TextSelection.collapsed(offset: caret));
        await tester.pump();
        await tester.pump();
        expect(
          find.descendant(of: tableRow, matching: find.byType(EditableText)),
          findsOneWidget,
          reason: 'fixture: the table is revealed',
        );
        // The reveal made E3's controller republish the field (its own empty
        // list, no checker ran), so seed the issue again, after the reveal.
        await _wi437Flag(tester, field, [_wi437Spelling(teh)]);
        final with_ = await _wi437Capture(tester);
        await _wi437Flag(tester, field, const []);
        final without = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          without,
          with_,
          _wi437Part1(tester, field, teh),
          color: OmColors.danger,
          what: 'revealed table',
        );
      },
    );
  });

  // ------------------------------------------------------------------- AC5
  group('selection (AC5)', () {
    const body = 'teh cat adn dog\n';

    testWidgets(
      'a non-collapsed selection covering a flagged range hides that squiggle and a squiggle outside the selection still paints',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: body);
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final text = _wi437Text(tester, row);
        final teh = _wi437Find(text, 'teh');
        final adn = _wi437Find(text, 'adn');
        final segment = segmentEditingAt(tester, 0);
        final covering = TextSelection(
          baseOffset: teh.start,
          extentOffset: teh.end + 4,
        );

        segment.select(covering);
        await tester.pump();
        final selected = await _wi437Capture(tester);
        segment.select(const TextSelection.collapsed(offset: 0));
        await tester.pump();
        final plain = await _wi437Capture(tester);

        // Flagged with a collapsed selection: both paint.
        await _wi437Flag(tester, row, [
          _wi437Spelling(teh),
          _wi437Spelling(adn),
        ]);
        final flagged = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          plain,
          flagged,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh before the selection',
        );

        // The selection covers teh (and cat): teh hides, adn stays.
        segment.select(covering);
        await tester.pump();
        // The selection change made E3's controller republish the field (its
        // own empty list, no checker ran): seed the same issues again, after
        // the last selection change.
        await _wi437Flag(tester, row, [
          _wi437Spelling(teh),
          _wi437Spelling(adn),
        ]);
        final after = await _wi437Capture(tester);
        _wi437ExpectNoChange(
          selected,
          after,
          _wi437Around(_wi437Part1(tester, row, teh)),
          what: 'teh under a covering selection',
        );
        _wi437ExpectSquiggle(
          selected,
          after,
          _wi437Part1(tester, row, adn),
          color: OmColors.danger,
          what: 'adn outside the selection',
        );
      },
    );

    testWidgets('a selection equal to the flagged range keeps its squiggle', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(tester, body: body);
      await _wi437Unfocus(tester);
      final row = e.rowFields(0).first;
      final teh = _wi437Find(_wi437Text(tester, row), 'teh');
      final segment = segmentEditingAt(tester, 0);
      final equal = TextSelection(baseOffset: teh.start, extentOffset: teh.end);
      segment.select(equal);
      await tester.pump();
      final before = await _wi437Capture(tester);

      await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
      final after = await _wi437Capture(tester);
      _wi437ExpectSquiggle(
        before,
        after,
        _wi437Part1(tester, row, teh),
        color: OmColors.danger,
        what: 'teh selected exactly',
      );
    });

    testWidgets(
      'a backwards selection equal to the flagged range keeps its squiggle',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: body);
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final segment = segmentEditingAt(tester, 0);
        segment.select(
          TextSelection(baseOffset: teh.end, extentOffset: teh.start),
        );
        await tester.pump();
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh selected exactly, backwards',
        );
      },
    );

    testWidgets(
      'a collapsed selection inside a flagged range keeps its squiggle',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: body);
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final segment = segmentEditingAt(tester, 0);
        segment.select(TextSelection.collapsed(offset: teh.start + 1));
        await tester.pump();
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'caret inside teh',
        );
      },
    );

    // Cross-row selections (review r1, findings 2 and 3): a row's field only
    // holds its clamped slice of the segment selection, so a selection that
    // runs on into a neighbouring row can look equal to the flagged range
    // there. The squiggle must still hide: only a selection that equals the
    // flagged range in segment offsets keeps it.
    for (final (name, source, from, to) in <(String, String, String, String)>[
      (
        'a selection from a flagged last word of a list item into the next row hides its squiggle',
        'intro\n\n- item teh\n- next one\n',
        'teh',
        'next',
      ),
      (
        'a selection from the row above that ends at a flagged first word hides its squiggle',
        'intro\n\n- one\n- teh more\n',
        'one',
        'teh',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final e = await pumpSpellingEditor(tester, body: source);
        await _wi437Unfocus(tester);
        final row = _wi437RowWith(e, 'teh');
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final segment = segmentEditingAt(tester, 0);
        final text = segment.text;
        final start = text.indexOf(from);
        // The first selection ends at the flagged word's end when it
        // starts before it, else it starts at the flagged word.
        final end = from == 'teh'
            ? text.indexOf(to) + 2
            : text.indexOf('teh') + 'teh'.length;
        segment.select(TextSelection(baseOffset: start, extentOffset: end));
        await tester.pump();
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);

        _wi437ExpectNoChange(
          before,
          after,
          _wi437Around(_wi437Part1(tester, row, teh)),
          what: 'teh under a selection that runs into the next row',
        );
      });
    }

    testWidgets(
      'selecting all of two one word list items hides both their squiggles',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: '- teh\n- adn\n');
        await _wi437Unfocus(tester);
        final first = _wi437RowWith(e, 'teh');
        final second = _wi437RowWith(e, 'adn');
        final segment = segmentEditingAt(tester, 0);
        segment.select(
          TextSelection(baseOffset: 0, extentOffset: segment.text.length),
        );
        await tester.pump();
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, first, [
          _wi437Spelling(_wi437Find(_wi437Text(tester, first), 'teh')),
        ]);
        await _wi437Flag(tester, second, [
          _wi437Spelling(_wi437Find(_wi437Text(tester, second), 'adn')),
        ]);
        final after = await _wi437Capture(tester);

        for (final (field, word) in [(first, 'teh'), (second, 'adn')]) {
          _wi437ExpectNoChange(
            before,
            after,
            _wi437Around(
              _wi437Part1(
                tester,
                field,
                _wi437Find(_wi437Text(tester, field), word),
              ),
            ),
            what: '$word under a select all',
          );
        }
      },
    );

    testWidgets(
      'a list item squiggle hides when the segment selection grows from its word into the next row and returns when it shrinks back',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'intro\n\n- item teh\n- next one\n',
        );
        await _wi437Unfocus(tester);
        final row = _wi437RowWith(e, 'teh');
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final segment = segmentEditingAt(tester, 0);
        final text = segment.text;
        final word = TextSelection(
          baseOffset: text.indexOf('teh'),
          extentOffset: text.indexOf('teh') + 3,
        );
        final grown = TextSelection(
          baseOffset: word.start,
          extentOffset: text.indexOf('next') + 2,
        );

        segment.select(grown);
        await tester.pump();
        final plainGrown = await _wi437Capture(tester);
        segment.select(word);
        await tester.pump();
        final plainWord = await _wi437Capture(tester);

        // The word is selected exactly: the squiggle stays.
        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final kept = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          plainWord,
          kept,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh selected exactly in a list item',
        );

        // The selection grows into the next row; the row's own slice stays
        // (5, 8), so only the segment selection says it changed.
        segment.select(grown);
        await tester.pump();
        final hidden = await _wi437Capture(tester);
        _wi437ExpectNoChange(
          plainGrown,
          hidden,
          _wi437Around(_wi437Part1(tester, row, teh)),
          what: 'teh once the selection runs into the next row',
        );

        // And back: the squiggle returns.
        segment.select(word);
        await tester.pump();
        final back = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          plainWord,
          back,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh once the selection shrinks back to the word',
        );
      },
    );

    testWidgets(
      'a selection equal to a flagged word in a list item keeps its squiggle',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: '- one\n- teh\n');
        await _wi437Unfocus(tester);
        final row = _wi437RowWith(e, 'teh');
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final segment = segmentEditingAt(tester, 0);
        final at = segment.text.indexOf('teh');
        segment.select(TextSelection(baseOffset: at, extentOffset: at + 3));
        await tester.pump();
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh selected exactly in segment offsets',
        );
      },
    );

    testWidgets(
      'a selection that covers a flagged range in Source mode hides its squiggle',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: body, source: true);
        await _wi437Unfocus(tester);
        final field = e.sourceField;
        final ctrl = _wi437Ctrl(tester, field);
        final text = ctrl.text;
        final teh = _wi437Find(text, 'teh');
        final adn = _wi437Find(text, 'adn');
        final covering = TextSelection(
          baseOffset: 0,
          extentOffset: teh.end + 4,
        );
        ctrl.selection = covering;
        await tester.pump();
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, field, [
          _wi437Spelling(teh),
          _wi437Spelling(adn),
        ]);
        final after = await _wi437Capture(tester);
        _wi437ExpectNoChange(
          before,
          after,
          _wi437Around(_wi437Part1(tester, field, teh)),
          what: 'teh under a covering selection',
        );
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, field, adn),
          color: OmColors.danger,
          what: 'adn outside the selection',
        );
      },
    );
  });

  // ------------------------------------------------------------------- AC6
  group('layout is untouched (AC6)', () {
    testWidgets(
      'row heights line boxes caret rects and the text are identical with and without issues in live preview',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat\n\n# Heading teh\n\n- item teh\n',
        );
        await _wi437Unfocus(tester);
        final rows = e.rowFields(0);
        final count = rows.evaluate().length;
        final segment = find.descendant(
          of: e.textSegment(0),
          matching: find.byType(SegmentView),
        );
        final before = [
          for (var i = 0; i < count; i++) _wi437Geometry(tester, rows.at(i)),
        ];
        final rowSizes = [
          for (var i = 0; i < count; i++)
            tester.getRect(find.byKey(ValueKey('editor-row-0-$i'))),
        ];
        final segmentRect = tester.getRect(segment);
        final shotBefore = await _wi437Capture(tester);

        final first = _wi437RowWith(e, 'teh cat');
        final item = _wi437RowWith(e, 'item teh');
        final tehFirst = _wi437Find(_wi437Text(tester, first), 'teh');
        final tehHead = _wi437Find(_wi437Text(tester, first), 'teh', 1);
        final tehItem = _wi437Find(_wi437Text(tester, item), 'teh');
        final registry = SpellIssueScope.maybeOf(tester.element(first))!;
        registry.setIssues(_wi437Ctrl(tester, first), [
          _wi437Spelling(tehFirst),
          _wi437Grammar(tehHead, 'Possible agreement error'),
        ]);
        registry.setIssues(_wi437Ctrl(tester, item), [_wi437Spelling(tehItem)]);
        await tester.pump();
        final shotAfter = await _wi437Capture(tester);

        // The issues paint (so the comparison below is with squiggles on).
        _wi437ExpectSquiggle(
          shotBefore,
          shotAfter,
          _wi437Part1(tester, first, tehFirst),
          color: OmColors.danger,
          what: 'teh',
        );
        _wi437ExpectSquiggle(
          shotBefore,
          shotAfter,
          _wi437Part1(tester, item, tehItem),
          color: OmColors.danger,
          what: 'item teh',
        );

        for (var i = 0; i < count; i++) {
          expect(
            _wi437Geometry(tester, rows.at(i)),
            before[i],
            reason: 'row $i text, span, size, line boxes and caret rects',
          );
          expect(
            tester.getRect(find.byKey(ValueKey('editor-row-0-$i'))),
            rowSizes[i],
            reason: 'row $i rect',
          );
        }
        expect(tester.getRect(segment), segmentRect, reason: 'segment rect');
      },
    );

    testWidgets(
      'the field height line boxes caret rects and the text are identical with and without issues in Source mode',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: '# Title teh\n\nteh cat\n',
          source: true,
        );
        await _wi437Unfocus(tester);
        final field = e.sourceField;
        final before = _wi437Geometry(tester, field);
        final shotBefore = await _wi437Capture(tester);
        final teh = _wi437Find(_wi437Text(tester, field), 'teh', 1);
        await _wi437Flag(tester, field, [_wi437Spelling(teh)]);
        final shotAfter = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          shotBefore,
          shotAfter,
          _wi437Part1(tester, field, teh),
          color: OmColors.danger,
          what: 'Source teh',
        );
        expect(_wi437Geometry(tester, field), before);
      },
    );
  });

  // ------------------------------------------------------------------- AC7
  group('repaint (AC7)', () {
    testWidgets(
      'removing an issue from the registry removes its squiggle on the next frame',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'teh cat adn dog\n');
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final text = _wi437Text(tester, row);
        final teh = _wi437Find(text, 'teh');
        final adn = _wi437Find(text, 'adn');
        final clean = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [
          _wi437Spelling(teh),
          _wi437Spelling(adn),
        ]);
        final both = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          clean,
          both,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh flagged',
        );

        // Drop teh only: one frame later it is gone and adn stays.
        await _wi437Flag(tester, row, [_wi437Spelling(adn)]);
        final one = await _wi437Capture(tester);
        _wi437ExpectNoChange(
          clean,
          one,
          _wi437Around(_wi437Part1(tester, row, teh)),
          what: 'teh after its issue was removed',
        );
        _wi437ExpectSquiggle(
          clean,
          one,
          _wi437Part1(tester, row, adn),
          color: OmColors.danger,
          what: 'adn still flagged',
        );

        // Drop the rest.
        await _wi437Flag(tester, row, const []);
        final none = await _wi437Capture(tester);
        _wi437ExpectNoChange(
          clean,
          none,
          _wi437Around(_wi437Part1(tester, row, adn)),
          what: 'adn after the list was emptied',
        );
      },
    );

    testWidgets(
      'a rebuild with an unchanged issue list does not repaint the squiggle layer',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'teh cat\n\nmore\n');
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');

        final start = debugSpellSquigglePaints;
        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        await tester.pump();
        final painted = debugSpellSquigglePaints;
        expect(
          painted,
          greaterThan(start),
          reason: 'a changed issue list repaints the layer',
        );

        // Rebuild the rows (same text, same issues) a few times.
        final view = find.descendant(
          of: e.textSegment(0),
          matching: find.byType(SegmentView),
        );
        for (var i = 0; i < 3; i++) {
          tester.element(view).markNeedsBuild();
          await tester.pump();
        }
        tester.element(find.byType(NoteEditor)).markNeedsBuild();
        await tester.pump();
        expect(
          debugSpellSquigglePaints,
          painted,
          reason: 'rebuilds with the same issues paint no squiggle layer',
        );

        // And a real change still repaints.
        await _wi437Flag(tester, row, const []);
        expect(debugSpellSquigglePaints, greaterThan(painted));
      },
    );
  });

  group('segment selection (AC5, AC7)', () {
    testWidgets(
      'a selection move inside one row repaints no layer of the other rows while no row has issues',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: '- one\n- two\n- three\n- four\n',
        );
        await _wi437Unfocus(tester);
        final segment = segmentEditingAt(tester, 0);
        expect(e.rowFields(0).evaluate().length, greaterThanOrEqualTo(4));
        final at = segment.text.indexOf('two');
        segment.select(TextSelection.collapsed(offset: at));
        await tester.pump();

        final before = debugSpellSquigglePaints;
        segment.select(TextSelection.collapsed(offset: at + 1));
        await tester.pump();
        // Only the row holding the caret sees its own selection change; the
        // other rows' layers have nothing to paint and stay put.
        expect(debugSpellSquigglePaints - before, lessThanOrEqualTo(1));
      },
    );

    testWidgets(
      'a caret move or a keystroke in one row repaints no flagged row whose selection does not equal its issue range',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: '- teh one\n- two\n- teh three\n- teh four\n',
        );
        await _wi437Unfocus(tester);
        final segment = segmentEditingAt(tester, 0);
        expect(e.rowFields(0).evaluate().length, greaterThanOrEqualTo(4));
        for (final word in ['one', 'three', 'four']) {
          final row = _wi437RowWith(e, word);
          await _wi437Flag(tester, row, [
            _wi437Spelling(_wi437Find(_wi437Text(tester, row), 'teh')),
          ]);
        }
        final at = segment.text.indexOf('two');
        segment.select(TextSelection.collapsed(offset: at));
        await tester.pump();

        // The caret moves inside the unflagged row: the three flagged rows
        // keep their selection, none equals its issue range, and the segment
        // selection was never consulted, so none of them repaints.
        var before = debugSpellSquigglePaints;
        segment.select(TextSelection.collapsed(offset: at + 1));
        await tester.pump();
        expect(
          debugSpellSquigglePaints - before,
          lessThanOrEqualTo(1),
          reason: 'only the row holding the caret repaints on a caret move',
        );

        // A keystroke in the same row changes the segment text and, as
        // replaceText puts the caret at the segment end, the last row's
        // selection: those two rows repaint, the other flagged rows stay.
        before = debugSpellSquigglePaints;
        final text = segment.text;
        segment.replaceText(text.replaceFirst('two', 'twox'));
        await tester.pump();
        expect(
          debugSpellSquigglePaints - before,
          lessThanOrEqualTo(2),
          reason:
              'only the edited row and the row of the new caret repaint on a keystroke',
        );
      },
    );

    testWidgets(
      'a row selection equal to the flagged range keeps its squiggle while the segment selection is invalid',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'teh cat\n');
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        final teh = _wi437Find(_wi437Text(tester, row), 'teh');
        final segment = segmentEditingAt(tester, 0);
        segment.select(const TextSelection.collapsed(offset: -1));
        await tester.pump();
        _wi437Ctrl(tester, row).selection = TextSelection(
          baseOffset: teh.start,
          extentOffset: teh.end,
        );
        await tester.pump();
        expect(
          segment.selection.isValid,
          isFalse,
          reason: 'fixture: the segment has no selection of its own',
        );
        final before = await _wi437Capture(tester);

        await _wi437Flag(tester, row, [_wi437Spelling(teh)]);
        final after = await _wi437Capture(tester);
        _wi437ExpectSquiggle(
          before,
          after,
          _wi437Part1(tester, row, teh),
          color: OmColors.danger,
          what: 'teh selected in its row only',
        );
      },
    );
  });

  // ------------------------------------------------------------------- AC8
  group('semantics hint (AC8)', () {
    testWidgets(
      'a row with a spelling issue on teh exposes the hint misspelled teh and a row without issues has none',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat\n\n- plain item\n',
        );
        await _wi437Unfocus(tester);
        final row = _wi437RowWith(e, 'teh cat');
        final other = _wi437RowWith(e, 'plain item');
        expect(
          _wi437HintsOf(tester, row).where(_wi437SpellHint),
          isEmpty,
          reason: 'no hint before any issue',
        );

        await _wi437Flag(tester, row, [
          _wi437Spelling(_wi437Find(_wi437Text(tester, row), 'teh')),
        ]);
        expect(
          _wi437HintsOf(tester, row).join('\n'),
          contains('misspelled: teh'),
        );
        expect(
          _wi437HintsOf(tester, other).where(_wi437SpellHint),
          isEmpty,
          reason: 'the row without issues has no spelling hint',
        );
      },
    );

    testWidgets(
      'a row with a grammar issue exposes the hint grammar with its description',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'they was here\n');
        await _wi437Unfocus(tester);
        final row = e.rowFields(0).first;
        await _wi437Flag(tester, row, [
          _wi437Grammar(
            _wi437Find(_wi437Text(tester, row), 'they was'),
            'Possible agreement error',
          ),
        ]);
        final hints = _wi437HintsOf(tester, row).join('\n');
        expect(hints, contains('grammar: Possible agreement error'));
        expect(hints, isNot(contains('misspelled')));
      },
    );

    testWidgets('a row hint names every issue of the row', (tester) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'teh cat adn they was\n',
      );
      await _wi437Unfocus(tester);
      final row = e.rowFields(0).first;
      final text = _wi437Text(tester, row);
      await _wi437Flag(tester, row, [
        _wi437Spelling(_wi437Find(text, 'teh')),
        _wi437Spelling(_wi437Find(text, 'adn')),
        _wi437Grammar(_wi437Find(text, 'they was'), 'Possible agreement error'),
      ]);
      final hints = _wi437HintsOf(tester, row).join('\n');
      expect(hints, contains('misspelled: teh'));
      expect(hints, contains('misspelled: adn'));
      expect(hints, contains('grammar: Possible agreement error'));
    });

    testWidgets('a row hint goes away once its issues are cleared', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(tester, body: 'teh cat\n');
      await _wi437Unfocus(tester);
      final row = e.rowFields(0).first;
      await _wi437Flag(tester, row, [
        _wi437Spelling(_wi437Find(_wi437Text(tester, row), 'teh')),
      ]);
      expect(
        _wi437HintsOf(tester, row).join('\n'),
        contains('misspelled: teh'),
      );

      await _wi437Flag(tester, row, const []);
      expect(_wi437HintsOf(tester, row).where(_wi437SpellHint), isEmpty);
    });

    testWidgets(
      'the Source mode field with a spelling issue exposes the hint misspelled teh',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat\n',
          source: true,
        );
        await _wi437Unfocus(tester);
        final field = e.sourceField;
        await _wi437Flag(tester, field, [
          _wi437Spelling(_wi437Find(_wi437Text(tester, field), 'teh')),
        ]);
        expect(
          _wi437HintsOf(tester, field).join('\n'),
          contains('misspelled: teh'),
        );
      },
    );
  });
}
