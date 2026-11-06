// WI #172 (B4, Spec #157 R7; D4, D6, D7, D12, D17; L14; TS2, TS6, TS9):
// read-only excerpt cards render their text with live preview's styling.
// - CardRows on its own (pixels and geometry at text scale 1): prose and
//   item rows, painted markers from C1b's read-only MarkerColumn, hanging
//   indent at A2's item text x, a surface4 quote band over the card's inner
//   width, B1 spans with every marker forced hidden, B2 pills.
// - The RenderParagraph line-box adapter (D6) against a real RichText.
// - D17: the card rows joined back give the excerpt text, every fixture.
// - Through the workspace: the fixture card, display-only clicks, Cmd+click,
//   hover, caption, remove and the removed stub.
// Design pack design/156-live-preview/packs/172.md wins over WI numbers:
// item text x = inner left + marker column (bullet 2 cols, task 4, numbered
// digits + 2, quote 2 with 1 col right padding); prose rows at the inner
// left; rows 22.95 per body line with no gap; base text fg1; quote band
// surface4 across the inner width.
//
// Keys (documented on CardRows): `card-row-<r>` (the whole row),
// `card-row-text-<r>` (the row text, one RichText), `card-row-marker-<r>`
// (an item row's MarkerColumn).
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_styles.dart';
import 'package:open_memex_app/src/widgets/editor/marker_column.dart';
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/markdown_fixtures.dart';

// ------------------------------------------------------------------ harness

/// One mono column (A2).
const double _wi172Col = 8.1;

/// A body, item or quote line (R13).
const double _wi172Line = 22.95;

/// Vertical tolerance: the engine rounds laid-out line metrics (a 22.95 px
/// line measures 23.0).
const double _wi172Y = 0.2;

const _wi172BoundaryKey = Key('wi172-boundary');
const _wi172RowsKey = Key('wi172-rows');

/// Pumps [CardRows] of [text], [width] wide, on the card's `surface3` fill
/// inside a repaint boundary (for pixel probes), at text scale 1.
Future<void> _wi172PumpRows(
  WidgetTester tester,
  String text, {
  double width = 736,
  TextScaler? textScaler,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Widget rows = CardRows(key: _wi172RowsKey, text: text);
  if (textScaler != null) {
    rows = Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: CardRows(key: _wi172RowsKey, text: text),
      ),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: _wi172BoundaryKey,
            child: Container(
              color: OmColors.surface3,
              padding: const EdgeInsets.all(20),
              child: SizedBox(width: width, child: rows),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder get _wi172Rows => find.byKey(_wi172RowsKey);

/// Row [r] (Key `card-row-<r>`) under [scope].
Finder _wi172Row(Finder scope, int r) =>
    find.descendant(of: scope, matching: find.byKey(Key('card-row-$r')));

/// Row [r]'s marker column (Key `card-row-marker-<r>`) under [scope].
Finder _wi172Marker(Finder scope, int r) =>
    find.descendant(of: scope, matching: find.byKey(Key('card-row-marker-$r')));

/// Row [r]'s text: the one RichText under Key `card-row-text-<r>`.
Finder _wi172RowText(Finder scope, int r) => find.descendant(
  of: find.descendant(of: scope, matching: find.byKey(Key('card-row-text-$r'))),
  matching: find.byType(RichText),
);

/// The rows A1 splits [text] into (as the editor does).
List<RowSpec> _wi172Specs(String text) => splitRows(text, atSegmentStart: true);

/// One leaf of a span tree: its text, its own style and its effective
/// (inherited and merged) style.
typedef _Wi172Leaf = ({String text, TextStyle? own, TextStyle style});

/// Every non-empty text leaf of [root], in order. A non-TextSpan child
/// (a WidgetSpan) shows as U+FFFC.
List<_Wi172Leaf> _wi172Leaves(InlineSpan root) {
  final out = <_Wi172Leaf>[];
  void visit(InlineSpan span, TextStyle inherited) {
    final style = span.style == null ? inherited : inherited.merge(span.style);
    if (span is TextSpan) {
      final text = span.text;
      if (text != null && text.isNotEmpty) {
        out.add((text: text, own: span.style, style: style));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    } else {
      out.add((text: '￼', own: span.style, style: style));
    }
  }

  visit(root, const TextStyle());
  return out;
}

/// Whether [leaf] shows: not a zero-size hidden marker, not transparent.
bool _wi172Shows(_Wi172Leaf leaf) =>
    leaf.style.fontSize != 0 &&
    (leaf.style.color == null || leaf.style.color!.a > 0);

/// The visible leaves of every RichText [finder] matches.
List<_Wi172Leaf> _wi172VisibleLeaves(WidgetTester tester, Finder finder) => [
  for (final w in tester.widgetList<RichText>(finder))
    ..._wi172Leaves(w.text).where(_wi172Shows),
];

/// The visible text of every RichText [finder] matches, joined.
String _wi172Visible(WidgetTester tester, Finder finder) =>
    [for (final leaf in _wi172VisibleLeaves(tester, finder)) leaf.text].join();

/// The single visible leaf of [finder]'s RichText whose text is [text].
_Wi172Leaf _wi172Leaf(WidgetTester tester, Finder finder, String text) {
  final found = _wi172VisibleLeaves(
    tester,
    finder,
  ).where((l) => l.text == text).toList();
  expect(found, hasLength(1), reason: 'one visible run "$text"');
  return found.single;
}

/// The global rect of [token]'s characters in row text [rich] (first visual
/// line it touches), at full line height.
Rect _wi172TokenRect(WidgetTester tester, Finder rich, String token) {
  final paragraph = tester.renderObject<RenderParagraph>(rich);
  final plain = paragraph.text.toPlainText();
  final at = plain.indexOf(token);
  expect(at, isNonNegative, reason: '"$token" in "$plain"');
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: at, extentOffset: at + token.length),
        boxHeightStyle: ui.BoxHeightStyle.max,
      )
      .first
      .toRect();
  return box.shift(paragraph.localToGlobal(Offset.zero));
}

/// Expects row text [rich] to start at [textX] right of [scope]'s left edge
/// and every visual line of it (at least two) to start at that x.
void _wi172ExpectHangs(
  WidgetTester tester,
  Finder scope,
  Finder rich,
  double textX, {
  required String why,
}) {
  final paragraph = tester.renderObject<RenderParagraph>(rich);
  final left = tester.getTopLeft(scope).dx;
  final origin = paragraph.localToGlobal(Offset.zero);
  expect(origin.dx - left, closeTo(textX, 0.01), reason: '$why: text x');
  final plain = paragraph.text.toPlainText();
  final starts = <double, double>{};
  for (final box in paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: plain.length),
  )) {
    starts[box.top] = math.min(starts[box.top] ?? double.infinity, box.left);
  }
  expect(starts.length, greaterThanOrEqualTo(2), reason: '$why: wraps');
  for (final MapEntry(key: top, value: x) in starts.entries) {
    expect(
      origin.dx + x - left,
      closeTo(textX, 0.01),
      reason: '$why: visual line at $top starts at the item text x',
    );
  }
}

// ------------------------------------------------------------------- pixels

/// Pixels of a region of the repaint boundary, captured at [ratio] image
/// pixels per logical pixel.
class _Wi172Pixels {
  _Wi172Pixels(this._bytes, this.width, this.height, this.rect, this.ratio);

  final ByteData _bytes;
  final int width;
  final int height;

  /// The captured region in global coordinates.
  final Rect rect;
  final double ratio;

  /// The pixel at global [point].
  Color at(Offset point) {
    final x = ((point.dx - rect.left) * ratio).floor();
    final y = ((point.dy - rect.top) * ratio).floor();
    expect(x, inInclusiveRange(0, width - 1), reason: 'x of $point');
    expect(y, inInclusiveRange(0, height - 1), reason: 'y of $point');
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      _bytes.getUint8(i + 3),
      _bytes.getUint8(i),
      _bytes.getUint8(i + 1),
      _bytes.getUint8(i + 2),
    );
  }
}

/// Captures the boundary's pixels inside global [region].
Future<_Wi172Pixels> _wi172Capture(
  WidgetTester tester,
  Rect region, {
  double ratio = 8,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_wi172BoundaryKey),
  );
  final origin = boundary.localToGlobal(Offset.zero);
  final local = region.shift(-origin).intersect(Offset.zero & boundary.size);
  final layer = boundary.debugLayer! as OffsetLayer;
  final image = (await tester.runAsync(
    () => layer.toImage(local, pixelRatio: ratio),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final pixels = _Wi172Pixels(
    bytes,
    image.width,
    image.height,
    local.shift(origin),
    ratio,
  );
  image.dispose();
  return pixels;
}

/// Matches a [Color] whose RGBA channels are each within 4 of [expected]
/// (surface3 and surface4 differ by 8 to 11 per channel).
class _Wi172Near extends Matcher {
  const _Wi172Near(this.expected);

  final Color expected;

  static List<int> _channels(Color c) => [
    for (final v in [c.r, c.g, c.b, c.a]) (v * 255).round(),
  ];

  static String _hex(Color c) =>
      '0x${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  @override
  bool matches(Object? item, Map<dynamic, dynamic> matchState) {
    if (item is! Color) return false;
    final a = _channels(item);
    final b = _channels(expected);
    for (var i = 0; i < 4; i++) {
      if ((a[i] - b[i]).abs() > 4) return false;
    }
    return true;
  }

  @override
  Description describe(Description description) =>
      description.add('a colour near ${_hex(expected)} (+-4)');

  @override
  Description describeMismatch(
    Object? item,
    Description mismatchDescription,
    Map<dynamic, dynamic> matchState,
    bool verbose,
  ) => item is Color
      ? mismatchDescription.add('was ${_hex(item)}')
      : mismatchDescription.add('was not a Color');
}

Matcher _wi172IsColor(Color c) => _Wi172Near(c);

// --------------------------------------------------------------- workspace

/// The A3 board card, one daily block per line (ords 3 to 7 of the fixture
/// daily note).
const _wi172Blocks = [
  '## Evidence',
  '- [x] Prototype buildTextSpan on one segment',
  '- [ ] Measure caret mapping with `TextPainter`',
  'Offsets stayed **byte-exact**; see [[Conflict merge]].',
  '> Caret mapping is the risky part.',
];

/// What each row of the A3 card shows, every marker hidden.
const _wi172Shown = [
  'Evidence',
  'Prototype buildTextSpan on one segment',
  'Measure caret mapping with TextPainter',
  'Offsets stayed byte-exact; see Conflict merge.',
  'Caret mapping is the risky part.',
];

const _wi172Token = '![[2026-09-05#^wi172a..^wi172e]]';

/// The topic note title the card wikilink names (a real note, so a link
/// that opened would open a tab).
const _wi172LinkedId = 'topic-wi172-conflict';

/// [seedSegmentedVault] plus the A3 card's blocks and the linked topic
/// note; the topic body is `Intro line`, the A3 card (card 1), `Outro line`.
({FakeVaultDb db, FakeMemexCli cli}) _wi172Vault() {
  final vault = seedSegmentedVault(
    topicBody: 'Intro line\n$_wi172Token\nOutro line\n',
  );
  for (final (i, text) in _wi172Blocks.indexed) {
    vault.db.seedBlock(
      fixtureDailyId,
      'wi172${'abcde'[i]}',
      ord: 3 + i,
      text: text,
    );
  }
  vault.db.seedTopicNote(_wi172LinkedId, 'Conflict merge');
  return vault;
}

/// The CLI calls that write (everything but `settings get`).
List<FakeCliCall> _wi172Writes(SegmentedEditorRobot r) => [
  for (final c in r.h.cli.calls)
    if (c.subcommand != 'settings get') c,
];

/// Whether the primary focus sits inside [scope].
bool _wi172FocusInside(Finder scope) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return find
      .descendant(
        of: scope,
        matching: find.byElementPredicate((e) => identical(e, context)),
      )
      .evaluate()
      .isNotEmpty;
}

/// Expects card [card] of the A3 vault to show [_wi172Shown], every marker
/// hidden: no marker column shows text, no field, nothing focused in it.
void _wi172ExpectAllHidden(WidgetTester tester, Finder card, String why) {
  for (final (r, shown) in _wi172Shown.indexed) {
    expect(
      _wi172Visible(tester, _wi172RowText(card, r)),
      shown,
      reason: '$why: row $r',
    );
  }
  for (final r in [1, 2, 4]) {
    expect(
      _wi172Visible(
        tester,
        find.descendant(
          of: _wi172Marker(card, r),
          matching: find.byType(RichText),
        ),
      ),
      '',
      reason: '$why: marker column $r shows no marker text',
    );
  }
  expect(
    find.descendant(of: card, matching: find.byType(EditableText)),
    findsNothing,
    reason: '$why: no field (no caret) in the card',
  );
  expect(_wi172FocusInside(card), isFalse, reason: '$why: no focus in card');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: prose and bullet item rows, painted bullet, no marker text
  // -------------------------------------------------------------------------
  group('prose and item rows (AC1)', () {
    testWidgets(
      'a card shows its prose line and its bullet item text with a painted bullet and no bullet marker text',
      (tester) async {
        await _wi172PumpRows(
          tester,
          'Fixed the jump arc.\n- tried coyote time',
        );
        final left = tester.getTopLeft(_wi172Rows).dx;

        final prose = _wi172RowText(_wi172Rows, 0);
        expect(
          tester.widget<RichText>(prose).text.toPlainText(),
          'Fixed the jump arc.',
        );
        expect(_wi172Visible(tester, prose), 'Fixed the jump arc.');
        expect(
          tester.getTopLeft(prose).dx - left,
          closeTo(0, 0.01),
          reason: 'a prose row starts at the inner left edge',
        );
        expect(_wi172Marker(_wi172Rows, 0), findsNothing);

        final item = _wi172RowText(_wi172Rows, 1);
        expect(
          tester.widget<RichText>(item).text.toPlainText(),
          'tried coyote time',
        );
        expect(_wi172Visible(tester, item), 'tried coyote time');
        expect(
          tester.getTopLeft(item).dx - left,
          closeTo(2 * _wi172Col, 0.01),
          reason: 'bullet text x = inner left + 2 columns',
        );

        // C1b's marker column, read-only, 2 columns wide at the inner left.
        final marker = _wi172Marker(_wi172Rows, 1);
        expect(marker, findsOneWidget);
        final column = tester.widget<MarkerColumn>(
          find.descendant(of: marker, matching: find.byType(MarkerColumn)),
        );
        expect(column.readOnly, isTrue);
        expect(column.marker, '- ');
        final rect = tester.getRect(
          find.descendant(of: marker, matching: find.byType(MarkerColumn)),
        );
        expect(rect.left - left, closeTo(0, 0.01));
        expect(rect.width, closeTo(2 * _wi172Col, 0.01));
        expect(rect.height, closeTo(_wi172Line, _wi172Y));

        // The painted level-1 bullet: a filled fg2 dot (pack #168).
        final px = await _wi172Capture(tester, rect.inflate(2));
        final dot = rect.topLeft + const Offset(4.05, 11.475);
        expect(px.at(dot), _wi172IsColor(OmColors.fg2), reason: 'dot centre');
        expect(
          px.at(Offset(rect.right - 1.5, rect.top + 1.5)),
          _wi172IsColor(OmColors.surface3),
          reason: 'the column is unfilled around the dot',
        );

        // No `- ` anywhere: not in a row, not in the marker column.
        final all = find.descendant(
          of: _wi172Rows,
          matching: find.byType(RichText),
        );
        for (final leaf in _wi172VisibleLeaves(tester, all)) {
          expect(leaf.text, isNot(contains('-')), reason: 'run "$leaf"');
        }
      },
    );

    testWidgets(
      'the fixture excerpt card shows Fixed the jump arc and tried coyote time as card rows',
      (tester) async {
        final r = await launchSegmented(tester, vault: seedSegmentedVault());
        await r.open(fixtureTopicId);

        final rows = find.descendant(
          of: r.card(1),
          matching: find.byType(CardRows),
        );
        expect(rows, findsOneWidget);
        expect(
          tester.widget<CardRows>(rows).text,
          'Fixed the jump arc.\n- tried coyote time',
          reason: 'the card renders the text excerpt_render returns (D4)',
        );
        expect(r.textIn(r.card(1), 'Fixed the jump arc.'), findsWidgets);
        expect(r.textIn(r.card(1), 'tried coyote time'), findsWidgets);
        expect(_wi172Marker(r.card(1), 1), findsOneWidget);
        for (final w in tester.widgetList<RichText>(
          find.descendant(of: r.card(1), matching: find.byType(RichText)),
        )) {
          expect(
            w.text.toPlainText(),
            isNot(contains('- ')),
            reason: 'no rendered text holds the bullet marker',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC2: quote line, italic fg1 over a surface4 band, marker hidden
  // -------------------------------------------------------------------------
  group('quote rows (AC2)', () {
    testWidgets(
      'a card quote line renders italic fg1 text over a surface4 band across the inner width with its marker hidden',
      (tester) async {
        await _wi172PumpRows(
          tester,
          'Offsets stayed put.\n> Caret mapping is the risky part.',
        );
        final rows = tester.getRect(_wi172Rows);
        final quote = _wi172RowText(_wi172Rows, 1);

        expect(
          _wi172Visible(tester, quote),
          'Caret mapping is the risky part.',
        );
        for (final leaf in _wi172VisibleLeaves(tester, quote)) {
          expect(leaf.style.fontStyle, FontStyle.italic, reason: leaf.text);
          expect(leaf.style.color, OmColors.fg1, reason: leaf.text);
        }
        final all = find.descendant(
          of: _wi172Rows,
          matching: find.byType(RichText),
        );
        expect(
          _wi172Visible(tester, all),
          isNot(contains('>')),
          reason: 'the quote marker is hidden, also in the marker column',
        );
        final column = tester.widget<MarkerColumn>(
          find.descendant(
            of: _wi172Marker(_wi172Rows, 1),
            matching: find.byType(MarkerColumn),
          ),
        );
        expect(column.readOnly, isTrue);

        // Quote text x = inner left + 2 columns, 1 column right padding.
        final text = tester.getRect(quote);
        expect(text.left - rows.left, closeTo(2 * _wi172Col, 0.01));
        expect(rows.right - text.right, closeTo(_wi172Col, 0.01));

        // The band: surface4 across the whole inner width, one line tall.
        final row = tester.getRect(_wi172Row(_wi172Rows, 1));
        expect(row.height, closeTo(_wi172Line, _wi172Y));
        final px = await _wi172Capture(tester, rows.inflate(4));
        for (final p in [
          Offset(rows.left + 1, row.center.dy),
          Offset(rows.left + 1, row.top + 1),
          Offset(rows.right - 1, row.center.dy),
          Offset(rows.right - 1, row.bottom - 1),
        ]) {
          expect(px.at(p), _wi172IsColor(OmColors.surface4), reason: 'band $p');
        }
        for (final p in [
          Offset(rows.right - 1, row.top - 2),
          Offset(rows.right - 1, row.bottom + 2),
        ]) {
          expect(
            px.at(p),
            _wi172IsColor(OmColors.surface3),
            reason: 'card fill outside the band at $p',
          );
        }
      },
    );

    testWidgets(
      'a wrapped card quote line keeps its band over every wrapped line and hangs at the quote text x',
      (tester) async {
        await _wi172PumpRows(
          tester,
          '> Caret mapping is the risky part of every card we render here',
          width: 300,
        );
        final rows = tester.getRect(_wi172Rows);
        final quote = _wi172RowText(_wi172Rows, 0);
        _wi172ExpectHangs(
          tester,
          _wi172Rows,
          quote,
          2 * _wi172Col,
          why: 'wrapped quote',
        );
        final row = tester.getRect(_wi172Row(_wi172Rows, 0));
        expect(row.height, greaterThan(2 * _wi172Line - 0.01));
        final px = await _wi172Capture(tester, rows.inflate(4));
        for (final y in [row.top + 1, row.center.dy, row.bottom - 1]) {
          for (final x in [rows.left + 1, rows.right - 1]) {
            expect(
              px.at(Offset(x, y)),
              _wi172IsColor(OmColors.surface4),
              reason: 'band at ($x, $y)',
            );
          }
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3: heading, bold, inline code, wikilink: live preview styles, markers
  // hidden
  // -------------------------------------------------------------------------
  group('live preview styles (AC3)', () {
    testWidgets(
      'a card heading bold inline code and wikilink render with live preview styles and every marker hidden',
      (tester) async {
        await _wi172PumpRows(
          tester,
          '# Title\n'
          'Offsets stayed **byte-exact**; see [[Conflict merge]].\n'
          '- [ ] Measure caret mapping with `TextPainter`',
        );
        final prose = _wi172RowText(_wi172Rows, 0);
        expect(
          _wi172Visible(tester, prose),
          'Title\nOffsets stayed byte-exact; see Conflict merge.',
          reason: 'heading, bold and wikilink markers render hidden',
        );
        expect(
          tester.widget<RichText>(prose).text.toPlainText(),
          '# Title\nOffsets stayed **byte-exact**; see [[Conflict merge]].',
          reason: 'hidden markers keep their characters (D17)',
        );

        final title = _wi172Leaf(tester, prose, 'Title');
        // WI #223 (design A + D): H1 is 26 px w700 heading1.
        expect(title.style.fontSize, 26, reason: 'H1 size');
        expect(title.style.fontWeight, FontWeight.w700, reason: 'H1 bold');
        expect(title.style.color, OmColors.heading1, reason: 'H1 colour');
        final plain = _wi172Leaf(tester, prose, 'Offsets stayed ');
        expect(plain.style.color, OmColors.fg1, reason: 'card base text fg1');
        expect(plain.style.fontSize, 13.5);
        final bold = _wi172Leaf(tester, prose, 'byte-exact');
        expect(bold.style.fontWeight, FontWeight.w700);
        expect(bold.style.color, OmColors.fg1);
        final link = _wi172Leaf(tester, prose, 'Conflict merge');
        expect(link.style.color, OmColors.accent, reason: 'wikilink accent');
        expect(
          link.style.decoration ?? TextDecoration.none,
          TextDecoration.none,
          reason: 'a resolved wikilink has no underline',
        );

        final task = _wi172RowText(_wi172Rows, 1);
        expect(
          _wi172Visible(tester, task),
          'Measure caret mapping with TextPainter',
        );
        final code = _wi172Leaf(tester, task, 'TextPainter');
        expect(code.style.color, OmColors.fg1, reason: 'inline code fg1');

        // B2's pill behind the code span, surface4, from the line top + 2 to
        // + 19 (pack #165); probed above the glyphs.
        final content = _wi172TokenRect(tester, task, 'TextPainter');
        final px = await _wi172Capture(tester, content.inflate(6));
        expect(
          px.at(Offset(content.center.dx, content.top + 3)),
          _wi172IsColor(OmColors.surface4),
          reason: 'pill above the code glyphs',
        );
        expect(
          px.at(Offset(content.center.dx, content.top + 1)),
          _wi172IsColor(OmColors.surface3),
          reason: 'the pill starts 2 px below the line top',
        );
      },
    );

    testWidgets(
      'every card row renders the B1 span of its row text with markers forced hidden',
      (tester) async {
        final text = [
          ..._wi172Blocks,
          '1. numbered with *italic* and ~~strike~~',
          '  - nested [link](https://example.com)',
          'tail line',
        ].join('\n');
        await _wi172PumpRows(tester, text);
        final specs = _wi172Specs(text);
        expect(specs.where((s) => s.kind == RowKind.code), isEmpty);
        for (final (r, spec) in specs.indexed) {
          final rowText = text.substring(spec.textStart, spec.textEnd);
          final expected = buildLivePreviewSpan(
            rowText,
            forceHidden: true,
            itemText: spec.isItem,
            taskDone: spec.done,
            quote: spec.kind == RowKind.quote,
            atSegmentStart: spec.textStart == 0,
          );
          final rendered = tester.widget<RichText>(
            _wi172RowText(_wi172Rows, r),
          );
          expect(
            [for (final l in _wi172Leaves(rendered.text)) (l.text, l.own)],
            [for (final l in _wi172Leaves(expected)) (l.text, l.own)],
            reason: 'row $r ($rowText) renders B1 spans, markers hidden',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // WI #223 (Spec #222 R10, R5a): a card heading row renders design A + D's
  // heading styles over the card's fg1 base and lays out at the heading line
  // height under the card's even leading, as the editor body row does.
  // -------------------------------------------------------------------------
  group('heading rows design A and D (WI 223)', () {
    testWidgets(
      'a card heading row renders the editor heading size weight and colour and lays out at its heading line height',
      (tester) async {
        for (final (level, size, weight, colour) in [
          (1, 26.0, FontWeight.w700, OmColors.heading1),
          (2, 19.0, FontWeight.w700, OmColors.fg0),
          (3, 15.0, FontWeight.w700, OmColors.fg0),
          (4, 11.0, FontWeight.w500, OmColors.fg2),
          (5, 11.0, FontWeight.w500, OmColors.fg2),
          (6, 11.0, FontWeight.w500, OmColors.fg2),
        ]) {
          final why = 'H$level';
          final text = '${'#' * level} Card title';
          await _wi172PumpRows(tester, text);
          final row = _wi172RowText(_wi172Rows, 0);
          expect(_wi172Visible(tester, row), 'Card title', reason: why);
          expect(
            tester.widget<RichText>(row).text.toPlainText(),
            text,
            reason: '$why: byte-exact, no text transform',
          );
          final title = _wi172Leaf(tester, row, 'Card title').style;
          expect(title.fontSize, size, reason: '$why size');
          expect(title.fontWeight, weight, reason: '$why weight');
          expect(
            title.fontFamily,
            OmType.mono(weight: weight).fontFamily,
            reason: '$why mono face',
          );
          expect(title.color, colour, reason: '$why colour over the fg1 base');
          expect(
            title.fontStyle ?? FontStyle.normal,
            FontStyle.normal,
            reason: '$why upright',
          );
          expect(title.letterSpacing ?? 0, 0, reason: '$why letter spacing');

          // The editor builds the same style for the same run.
          final editor = buildLivePreviewSpan(text, forceHidden: true);
          final editorTitle = _wi172Leaves(
            editor,
          ).where((l) => l.text == 'Card title').single.own;
          expect(title.fontSize, editorTitle?.fontSize, reason: why);
          expect(title.fontWeight, editorTitle?.fontWeight, reason: why);
          expect(title.color, editorTitle?.color, reason: why);

          // Laid out under the card's even leading and the body strut.
          final paragraph = tester.renderObject<RenderParagraph>(row);
          final lines = RenderParagraphLineBoxes(paragraph).lines;
          expect(lines, hasLength(1), reason: '$why: one line');
          expect(
            lines.single.bottom - lines.single.top,
            closeTo(headingLineHeight(level), 0.05),
            reason: '$why: card line height',
          );
          // (The line box, not the paragraph size: a laid-out text height
          // rounds up to a whole pixel.)

          // The editor body row for the same text is as tall.
          await _wi172PumpBody(tester, text);
          final body = RenderEditableLineBoxes(
            _wi172BodyEditable(tester, 0),
          ).lines;
          expect(body, hasLength(1), reason: '$why: one body line');
          expect(
            body.single.bottom - body.single.top,
            closeTo(headingLineHeight(level), 0.05),
            reason: '$why: editor body row line height',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4: hanging indent and row geometry
  // -------------------------------------------------------------------------
  group('hanging indent (AC4)', () {
    testWidgets(
      'a long card item wraps with every line starting at the item text x',
      (tester) async {
        const text =
            '- tried coyote time while the jump arc stayed floaty\n'
            '- [ ] measure caret mapping with a task long enough to wrap\n'
            '- parent\n'
            '  - child item that is long enough to wrap onto a new line\n'
            '1. numbered item long enough to wrap onto the next line';
        await _wi172PumpRows(tester, text, width: 300);
        final left = tester.getTopLeft(_wi172Rows).dx;

        // (row, marker x, marker width, text x, wraps)
        const cases = [
          (0, 0.0, 2 * _wi172Col, 2 * _wi172Col, true),
          (1, 0.0, 4 * _wi172Col, 4 * _wi172Col, true),
          (2, 0.0, 2 * _wi172Col, 2 * _wi172Col, false),
          (3, 2 * _wi172Col, 2 * _wi172Col, 4 * _wi172Col, true),
          (4, 0.0, 3 * _wi172Col, 3 * _wi172Col, true),
        ];
        for (final (r, markerX, markerW, textX, wraps) in cases) {
          final column = tester.getRect(
            find.descendant(
              of: _wi172Marker(_wi172Rows, r),
              matching: find.byType(MarkerColumn),
            ),
          );
          expect(column.left - left, closeTo(markerX, 0.01), reason: 'row $r');
          expect(column.width, closeTo(markerW, 0.01), reason: 'row $r');
          final rich = _wi172RowText(_wi172Rows, r);
          if (wraps) {
            _wi172ExpectHangs(tester, _wi172Rows, rich, textX, why: 'row $r');
          } else {
            expect(
              tester.getTopLeft(rich).dx - left,
              closeTo(textX, 0.01),
              reason: 'row $r text x',
            );
          }
          expect(
            tester.getTopRight(rich).dx,
            closeTo(tester.getTopRight(_wi172Rows).dx, 0.01),
            reason: 'row $r text runs to the inner right edge',
          );
        }
      },
    );

    testWidgets('card rows stack with no gap at the body line height', (
      tester,
    ) async {
      await _wi172PumpRows(
        tester,
        'Fixed the jump arc.\n- tried coyote time\n- [ ] open task',
      );
      final rows = tester.getRect(_wi172Rows);
      var top = rows.top;
      for (var r = 0; r < 3; r++) {
        final row = tester.getRect(_wi172Row(_wi172Rows, r));
        expect(
          row.top,
          closeTo(top, 0.01),
          reason: 'row $r follows with no gap',
        );
        expect(
          row.height,
          closeTo(_wi172Line, _wi172Y),
          reason: 'row $r height',
        );
        expect(row.left, closeTo(rows.left, 0.01));
        top = row.bottom;
      }
      expect(rows.height, closeTo(3 * _wi172Line, _wi172Y));
    });
  });

  // -------------------------------------------------------------------------
  // AC5: D17, the rows joined back give the excerpt text
  // -------------------------------------------------------------------------
  group('byte exact rows (AC5, D17)', () {
    testWidgets(
      'the plain text of the card rows joined back equals the excerpt text for every markdown fixture',
      (tester) async {
        final texts = {
          ...markdownFixtures,
          'a3 card': _wi172Blocks.join('\n'),
          'fixture card': 'Fixed the jump arc.\n- tried coyote time',
        };
        expect(texts.length, greaterThan(20), reason: 'sweep is real');
        for (final MapEntry(key: name, value: text) in texts.entries) {
          await _wi172PumpRows(tester, text);
          final specs = _wi172Specs(text);
          final joined = StringBuffer();
          for (final (r, spec) in specs.indexed) {
            final slice = text.substring(spec.textStart, spec.textEnd);
            final rich = _wi172RowText(_wi172Rows, r);
            final String plain;
            if (rich.evaluate().isEmpty) {
              expect(slice, isEmpty, reason: '$name: row $r is not rendered');
              plain = '';
            } else {
              final span = tester.widget<RichText>(rich).text;
              plain = span.toPlainText();
              for (final leaf in _wi172Leaves(span)) {
                expect(
                  leaf.text,
                  isNot('￼'),
                  reason: '$name: row $r holds only TextSpans (TD4)',
                );
              }
            }
            expect(plain, slice, reason: '$name: row $r plain text');
            joined
              ..write(text.substring(spec.start, spec.textStart))
              ..write(plain)
              ..write(text.substring(spec.textEnd, spec.end));
          }
          expect(joined.toString(), text, reason: '$name joined back');
          expect(
            _wi172RowText(_wi172Rows, specs.length),
            findsNothing,
            reason: '$name: one card row per A1 row',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC6: display only, no toggle, no link open
  // -------------------------------------------------------------------------
  group('display only (AC6)', () {
    testWidgets(
      'clicking a task checkbox in a card changes nothing and sends no update',
      (tester) async {
        final r = await launchSegmented(tester, vault: _wi172Vault());
        await r.open(fixtureTopicId);
        final card = r.card(1);
        _wi172ExpectAllHidden(tester, card, 'before');
        expect(
          find.descendant(
            of: card,
            matching: find.byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    'task-checkbox-',
                  ),
            ),
          ),
          findsNothing,
          reason: 'a card task column is no checkbox',
        );
        final writes = _wi172Writes(r).length;

        for (final row in [2, 1]) {
          final marker = _wi172Marker(card, row);
          expect(marker, findsOneWidget);
          await tester.macClick(tester.getCenter(marker));
          await tester.pump();
        }
        await r.waitForSave();

        expect(r.updates, isEmpty);
        expect(_wi172Writes(r), hasLength(writes), reason: 'no CLI write');
        expect(r.segmentText(0), 'Intro line\n');
        final topic = r.h.db.db.select(
          'SELECT content_md FROM notes WHERE id = ?',
          [fixtureTopicId],
        ).single;
        expect(topic['content_md'], 'Intro line\n$_wi172Token\nOutro line\n');
        final blocks = r.h.db.db.select(
          "SELECT text FROM blocks WHERE block_id IN ('wi172b', 'wi172c') "
          'ORDER BY ord',
        );
        expect(
          [for (final b in blocks) b['text']],
          [_wi172Blocks[1], _wi172Blocks[2]],
        );
        for (final (row, marker) in [(1, '- [x] '), (2, '- [ ] ')]) {
          final column = tester.widget<MarkerColumn>(
            find.descendant(
              of: _wi172Marker(card, row),
              matching: find.byType(MarkerColumn),
            ),
          );
          expect(column.marker, marker, reason: 'row $row is not toggled');
          expect(column.readOnly, isTrue);
        }
        _wi172ExpectAllHidden(tester, card, 'after the clicks');
      },
      variant: macOnly,
    );

    testWidgets('cmd clicking a wikilink in a card opens no tab', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: _wi172Vault());
      await r.open(fixtureTopicId);
      r.expectActiveNote(fixtureTopicId);
      final tabs = r.h.read(tabsProvider).tabs.length;
      final link = _wi172TokenRect(
        tester,
        _wi172RowText(r.card(1), 3),
        'Conflict merge',
      );

      await tester.macCmdClick(link.center);
      await pumpFrames(tester);
      await tester.macClick(link.center);
      await pumpFrames(tester);
      await r.waitForSave();

      r.expectActiveNote(fixtureTopicId);
      expect(r.h.read(tabsProvider).tabs, hasLength(tabs));
      expect(
        r.h
            .read(tabsProvider)
            .tabs
            .whereType<NoteTab>()
            .where((t) => t.id == _wi172LinkedId),
        isEmpty,
        reason: 'the linked note never opens',
      );
      expect(r.updates, isEmpty);
    }, variant: macOnly);
  });

  // -------------------------------------------------------------------------
  // AC7: hover and click never reveal a marker
  // -------------------------------------------------------------------------
  group('markers never reveal (AC7)', () {
    testWidgets('hovering and clicking inside a card never reveals a marker', (
      tester,
    ) async {
      final r = await launchSegmented(tester, vault: _wi172Vault());
      await r.open(fixtureTopicId);
      final card = r.card(1);
      _wi172ExpectAllHidden(tester, card, 'opened');

      // Where each row's text starts (just inside its first glyph), and the
      // wikilink.
      final points = [
        for (var row = 0; row < _wi172Shown.length; row++)
          tester.getRect(_wi172RowText(card, row)).centerLeft +
              const Offset(4, 0),
      ];
      final link = _wi172TokenRect(
        tester,
        _wi172RowText(card, 3),
        'Conflict merge',
      ).center;

      // Hovering: a mouse resting over each row, then Cmd held over the
      // wikilink (no Cmd-hover style).
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      for (final (row, at) in points.indexed) {
        await mouse.moveTo(at);
        await tester.pump();
        _wi172ExpectAllHidden(tester, card, 'hovering row $row');
      }
      await mouse.moveTo(link);
      await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
        await tester.pump();
        _wi172ExpectAllHidden(tester, card, 'cmd hover');
        for (final leaf in _wi172VisibleLeaves(
          tester,
          _wi172RowText(card, 3),
        )) {
          expect(
            leaf.style.decoration ?? TextDecoration.none,
            TextDecoration.none,
            reason: 'the run ${leaf.text} has no hover underline',
          );
        }
      });
      await mouse.removePointer();
      await tester.pump();

      // No pointer cursor on a token or a row, Cmd held or not.
      for (final (row, at) in points.indexed) {
        expect(
          await tester.macCursorAt(at),
          isNot(SystemMouseCursors.click),
          reason: 'row $row',
        );
      }
      expect(
        await tester.macHolding([
          LogicalKeyboardKey.metaLeft,
        ], () => tester.macCursorAt(link)),
        isNot(SystemMouseCursors.click),
        reason: 'cmd over the wikilink',
      );

      // Clicking each row's text and each marker column.
      for (final (row, at) in points.indexed) {
        await tester.macClick(at);
        await tester.pump();
        _wi172ExpectAllHidden(tester, card, 'clicked row $row');
        final marker = _wi172Marker(card, row);
        if (marker.evaluate().isNotEmpty) {
          await tester.macClick(tester.getCenter(marker));
          await tester.pump();
          _wi172ExpectAllHidden(tester, card, 'clicked marker $row');
        }
      }
      await tester.macClick(link);
      await tester.pump();
      _wi172ExpectAllHidden(tester, card, 'clicked the wikilink');
    }, variant: macOnly);

    testWidgets(
      'a caret in the text segment next to a card leaves the card markers hidden',
      (tester) async {
        final r = await launchSegmented(tester, vault: _wi172Vault());
        await r.open(fixtureTopicId);
        await r.focusSegment(0);
        expect(r.segmentHasFocus(0), isTrue);
        _wi172ExpectAllHidden(tester, r.card(1), 'segment 0 focused');
        await r.focusSegment(2, offset: 0);
        expect(r.segmentHasFocus(2), isTrue);
        _wi172ExpectAllHidden(tester, r.card(1), 'segment 2 focused');
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: caption, remove, removed stub
  // -------------------------------------------------------------------------
  group('card shell (AC8)', () {
    testWidgets(
      'the card caption still opens the daily note and the remove button still removes the excerpt',
      (tester) async {
        final r = await launchSegmented(tester, vault: _wi172Vault());
        await r.open(fixtureTopicId);
        expect(
          find.descendant(of: r.card(1), matching: find.byType(CardRows)),
          findsOneWidget,
        );

        await r.tapCaption(1);
        r.expectActiveNote(fixtureDailyId);

        await r.open(fixtureTopicId);
        await r.tapRemove(1);
        expect(r.excerptRms, hasLength(1));
        expect(r.excerptRms.single.flag('block-ids'), 'wi172a,wi172e');
        expect(r.excerptRms.single.flag('date'), '2026-09-05');
        expect(r.allCards, findsNothing);
      },
    );

    testWidgets(
      'a removed from 2026-09-05 stub renders as plain fg3 text without card rows',
      (tester) async {
        final r = await launchSegmented(
          tester,
          vault: seedSegmentedVault(
            topicBody: 'Intro line\n![[2026-09-05#^zzzzzz]]\nOutro line\n',
          ),
        );
        await r.open(fixtureTopicId);

        final stub = r.textIn(r.card(1), 'removed from 2026-09-05');
        expect(stub, findsWidgets);
        expect(
          find.descendant(of: r.card(1), matching: find.byType(CardRows)),
          findsNothing,
          reason: 'the stub is not markdown',
        );
        expect(_wi172RowText(r.card(1), 0), findsNothing);
        final rich = find.descendant(
          of: r.card(1),
          matching: find.byWidgetPredicate(
            (w) =>
                w is RichText &&
                w.text.toPlainText() == 'removed from 2026-09-05',
          ),
        );
        for (final leaf in _wi172VisibleLeaves(tester, rich)) {
          expect(leaf.style.color, OmColors.fg3, reason: 'stub fg3');
          expect(leaf.style.fontStyle ?? FontStyle.normal, FontStyle.normal);
          expect(leaf.style.fontWeight ?? FontWeight.w400, FontWeight.w400);
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // D6: the RenderParagraph line-box adapter
  // -------------------------------------------------------------------------
  group('paragraph line boxes (D6)', () {
    const base = TextStyle(fontSize: 13.5, height: 1.7);

    /// Pumps a RichText of [span] [width] wide with live preview's strut
    /// and returns its paragraph's line boxes.
    Future<RenderParagraphLineBoxes> pumpParagraph(
      WidgetTester tester,
      InlineSpan span, {
      double width = 400,
    }) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: RichText(
                key: const Key('wi172-paragraph'),
                text: span,
                strutStyle: livePreviewStrut(),
              ),
            ),
          ),
        ),
      );
      return RenderParagraphLineBoxes(
        tester.renderObject<RenderParagraph>(
          find.byKey(const Key('wi172-paragraph')),
        ),
      );
    }

    testWidgets(
      'paragraph line boxes report one full height line per visual line',
      (tester) async {
        final boxes = await pumpParagraph(
          tester,
          const TextSpan(text: 'ab\ncd\n', style: base),
        );
        expect(boxes.box, same(boxes.paragraph));
        final lines = boxes.lines;
        expect(
          [for (final l in lines) (l.range.start, l.range.end)],
          [(0, 2), (3, 5), (6, 6)],
        );
        for (final (i, line) in lines.indexed) {
          expect(line.top, closeTo(i * _wi172Line, _wi172Y), reason: 'line $i');
          expect(
            line.bottom,
            closeTo((i + 1) * _wi172Line, _wi172Y),
            reason: 'line $i (the empty last line measures too)',
          );
        }

        // 10 columns of the 13.5 px test font: 'aaaa bbbb cccc' wraps.
        final wrapped = await pumpParagraph(
          tester,
          const TextSpan(text: 'aaaa bbbb cccc', style: base),
          width: 10 * 13.5,
        );
        expect(
          [for (final l in wrapped.lines) l.range.start],
          [0, 10],
          reason: 'a wrapped line gives one line box per visual line',
        );
        expect(wrapped.lines.last.top, closeTo(_wi172Line, _wi172Y));
      },
    );

    testWidgets(
      'paragraph line boxes measure a heading line at its own height',
      (tester) async {
        final boxes = await pumpParagraph(
          tester,
          buildLivePreviewSpan('# Title\nbody', style: base, forceHidden: true),
        );
        final lines = boxes.lines;
        expect(lines, hasLength(2));
        expect(lines[0].bottom - lines[0].top, closeTo(40, _wi172Y));
        expect(lines[1].top, closeTo(40, _wi172Y));
        expect(lines[1].bottom - lines[1].top, closeTo(_wi172Line, _wi172Y));
      },
    );

    testWidgets(
      'paragraph line boxes give one full height rect per line a range touches',
      (tester) async {
        final boxes = await pumpParagraph(
          tester,
          const TextSpan(text: 'ab\ncd', style: base),
        );
        expect(boxes.boxesFor(const TextRange.collapsed(1)), isEmpty);
        final rects = boxes.boxesFor(const TextRange(start: 1, end: 4));
        expect(rects, hasLength(2));
        expect(rects[0].left, closeTo(13.5, 0.01));
        expect(rects[0].right, closeTo(27, 0.01));
        expect(rects[0].top, closeTo(0, _wi172Y));
        expect(rects[0].bottom, closeTo(_wi172Line, _wi172Y));
        expect(rects[1].left, closeTo(0, 0.01));
        expect(rects[1].right, closeTo(13.5, 0.01));
        expect(rects[1].top, closeTo(_wi172Line, _wi172Y));
        expect(rects[1].bottom, closeTo(2 * _wi172Line, _wi172Y));
      },
    );

    testWidgets(
      'paragraph line boxes never give a zero height caret at a hidden marker',
      (tester) async {
        final boxes = await pumpParagraph(
          tester,
          buildLivePreviewSpan('**b** x\nnext', style: base, forceHidden: true),
        );
        for (final offset in [0, 1, 2, 4, 9]) {
          final caret = boxes.caretRect(offset);
          final line = offset < 8 ? 0 : 1;
          expect(
            caret.top,
            closeTo(line * _wi172Line, _wi172Y),
            reason: 'caret $offset top',
          );
          expect(
            caret.height,
            closeTo(_wi172Line, _wi172Y),
            reason: 'caret $offset height',
          );
        }
        // The hidden `**` is zero-width: the caret after it sits at x 0, the
        // caret after `b` one column in.
        expect(boxes.caretRect(2).left, closeTo(0, 0.01));
        expect(boxes.caretRect(3).left, closeTo(13.5, 0.01));
      },
    );

    testWidgets('paragraph line boxes find the text offset nearest a point', (
      tester,
    ) async {
      final boxes = await pumpParagraph(
        tester,
        const TextSpan(text: 'ab\ncd', style: base),
      );
      expect(boxes.offsetAt(const Offset(1, 5)), 0);
      expect(boxes.offsetAt(const Offset(14, _wi172Line + 5)), 4);
      expect(boxes.offsetAt(const Offset(200, _wi172Line + 5)), 5);
    });

    testWidgets(
      'paragraph line boxes give a zero width caret and clamp offsets outside the text',
      (tester) async {
        final boxes = await pumpParagraph(
          tester,
          const TextSpan(text: 'ab\ncd', style: base),
        );
        for (final offset in [0, 1, 3, 5]) {
          expect(boxes.caretRect(offset).width, 0, reason: 'caret $offset');
        }
        expect(boxes.caretRect(5).left, closeTo(27, 0.01));
        expect(boxes.caretRect(5).top, closeTo(_wi172Line, _wi172Y));
        for (final past in [6, 99]) {
          expect(
            boxes.caretRect(past),
            boxes.caretRect(5),
            reason: 'offset $past clamps to the text end',
          );
        }
        expect(
          boxes.caretRect(-3),
          boxes.caretRect(0),
          reason: 'a negative offset clamps to the text start',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Verify: contracts documented on CardRows (handoff list)
  // -------------------------------------------------------------------------
  group('card row contracts (verify)', () {
    testWidgets('a card leaves out an empty text and a trailing empty row', (
      tester,
    ) async {
      await _wi172PumpRows(tester, '');
      expect(_wi172Row(_wi172Rows, 0), findsNothing, reason: 'empty text');
      expect(tester.getSize(_wi172Rows).height, 0);

      await _wi172PumpRows(tester, '- tried coyote time\n');
      expect(_wi172Specs('- tried coyote time\n'), hasLength(2));
      expect(_wi172Row(_wi172Rows, 0), findsOneWidget);
      expect(
        _wi172Row(_wi172Rows, 1),
        findsNothing,
        reason: 'the empty prose row after the trailing line break',
      );
      expect(
        tester.getSize(_wi172Rows).height,
        closeTo(_wi172Line, _wi172Y),
        reason: 'no blank line below the item',
      );
    });

    testWidgets(
      'a card code row keeps the editor code insets over a surface1 code box with a line1 border',
      (tester) async {
        const text = 'Intro\n```\nlet x = 1;\n```';
        await _wi172PumpRows(tester, text);
        expect(_wi172Specs(text)[1].kind, RowKind.code);
        final rows = tester.getRect(_wi172Rows);
        final code = _wi172RowText(_wi172Rows, 1);
        final text0 = tester.getRect(code);
        expect(text0.left - rows.left, closeTo(2 * _wi172Col, 0.01));
        expect(rows.right - text0.right, closeTo(10, 0.01));
        expect(_wi172Marker(_wi172Rows, 1), findsNothing);

        final row = tester.getRect(_wi172Row(_wi172Rows, 1));
        final y = _wi172TokenRect(tester, code, 'let').center.dy;
        final px = await _wi172Capture(tester, rows.inflate(4));
        // Glyph-free probes: the left and right insets, beside the code line.
        for (final x in [rows.left + 8, rows.right - 5]) {
          expect(
            px.at(Offset(x, y)),
            _wi172IsColor(OmColors.surface1),
            reason: 'code box at ($x, $y)',
          );
        }
        expect(
          px.at(Offset(rows.left + 0.5, y)),
          _wi172IsColor(Color.alphaBlend(OmColors.line1, OmColors.surface1)),
          reason: 'the 1 px line1 border inside the box',
        );
        expect(
          px.at(Offset(rows.right - 5, row.bottom + 2)),
          _wi172IsColor(OmColors.surface3),
          reason: 'card fill below the code box',
        );
      },
    );

    testWidgets('a card repaints its quote band when its text changes', (
      tester,
    ) async {
      await _wi172PumpRows(tester, '> Caret mapping is the risky part.');
      var rows = tester.getRect(_wi172Rows);
      var row = tester.getRect(_wi172Row(_wi172Rows, 0));
      var px = await _wi172Capture(tester, rows.inflate(4));
      expect(
        px.at(Offset(rows.right - 1, row.center.dy)),
        _wi172IsColor(OmColors.surface4),
      );

      await _wi172PumpRows(tester, 'Caret mapping is the risky part.');
      rows = tester.getRect(_wi172Rows);
      row = tester.getRect(_wi172Row(_wi172Rows, 0));
      px = await _wi172Capture(tester, rows.inflate(4));
      expect(
        px.at(Offset(rows.right - 1, row.center.dy)),
        _wi172IsColor(OmColors.surface3),
        reason: 'a prose row has no band',
      );

      await _wi172PumpRows(
        tester,
        '> Caret mapping is the risky part of every card we render here',
        width: 300,
      );
      rows = tester.getRect(_wi172Rows);
      row = tester.getRect(_wi172Row(_wi172Rows, 0));
      expect(row.height, greaterThan(2 * _wi172Line - 0.01));
      px = await _wi172Capture(tester, rows.inflate(4));
      expect(
        px.at(Offset(rows.right - 1, row.bottom - 1)),
        _wi172IsColor(OmColors.surface4),
        reason: 'the band covers the new wrapped line',
      );
    });

    testWidgets('a card quote band follows the text scale of its rows', (
      tester,
    ) async {
      await _wi172PumpRows(
        tester,
        'Offsets stayed put.\n> Caret mapping is the risky part.',
        textScaler: const TextScaler.linear(1.5),
      );
      final rows = tester.getRect(_wi172Rows);
      final quote = _wi172RowText(_wi172Rows, 1);
      expect(
        tester.renderObject<RenderParagraph>(quote).textScaler,
        const TextScaler.linear(1.5),
        reason: 'card rows take the text scale from MediaQuery',
      );
      final row = tester.getRect(_wi172Row(_wi172Rows, 1));
      expect(row.height, greaterThan(1.4 * _wi172Line));
      final px = await _wi172Capture(tester, rows.inflate(4));
      for (final y in [row.top + 1, row.bottom - 1]) {
        expect(
          px.at(Offset(rows.right - 1, y)),
          _wi172IsColor(OmColors.surface4),
          reason: 'band at y $y of the scaled row',
        );
      }
      expect(
        px.at(Offset(rows.right - 1, row.top - 2)),
        _wi172IsColor(OmColors.surface3),
      );
    });

    testWidgets(
      'only the first card row reads leading frontmatter as frontmatter',
      (tester) async {
        const text = '---\nk: v\n---\n- item\n---\nk: v\n---';
        await _wi172PumpRows(tester, text);
        final specs = _wi172Specs(text);
        expect(
          [for (final s in specs) s.kind],
          [RowKind.prose, RowKind.bullet, RowKind.prose],
        );
        List<(String, TextStyle?)> leaves(InlineSpan span) => [
          for (final l in _wi172Leaves(span)) (l.text, l.own),
        ];
        for (final (r, start) in [(0, true), (2, false)]) {
          final spec = specs[r];
          final rowText = text.substring(spec.textStart, spec.textEnd);
          final rendered = leaves(
            tester.widget<RichText>(_wi172RowText(_wi172Rows, r)).text,
          );
          final expected = leaves(
            buildLivePreviewSpan(
              rowText,
              forceHidden: true,
              atSegmentStart: start,
            ),
          );
          final other = leaves(
            buildLivePreviewSpan(
              rowText,
              forceHidden: true,
              atSegmentStart: !start,
            ),
          );
          expect(other, isNot(expected), reason: 'row $r: inputs differ');
          expect(rendered, expected, reason: 'row $r at segment start $start');
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // Fix round r1 (review-r1): interior empty rows and the D18 code strut,
  // measured against the editor body for the same text.
  // -------------------------------------------------------------------------
  group('card rows match the editor body (verify r1)', () {
    testWidgets(
      'a card renders the daily note blank line between the nested item and the quote as one prose line like the editor body',
      (tester) async {
        final text = markdownFixtures['daily note']!;
        final specs = _wi172Specs(text);
        final blank = [
          for (var r = 1; r < specs.length - 1; r++)
            if (specs[r].kind == RowKind.prose &&
                specs[r].textLength == 0 &&
                specs[r - 1].isItem &&
                specs[r - 1].depth > 0 &&
                specs[r + 1].kind == RowKind.quote)
              r,
        ];
        expect(blank, hasLength(1), reason: 'the fixture has that blank row');
        final b = blank.single;

        await _wi172PumpRows(tester, text);
        final above = tester.getRect(_wi172Row(_wi172Rows, b - 1));
        final gap = tester.getRect(_wi172Row(_wi172Rows, b));
        final below = tester.getRect(_wi172Row(_wi172Rows, b + 1));
        expect(gap.top, closeTo(above.bottom, 0.01), reason: 'no extra gap');
        expect(below.top, closeTo(gap.bottom, 0.01), reason: 'no extra gap');
        expect(
          gap.height,
          closeTo(_wi172Line, _wi172Y),
          reason: 'the blank row is one prose line tall',
        );
        expect(
          below.top - above.bottom,
          closeTo(_wi172Line, _wi172Y),
          reason: 'the quote sits one line below the nested item',
        );
        final card = [
          for (var r = 0; r < specs.length; r++)
            if (_wi172Row(_wi172Rows, r).evaluate().isNotEmpty)
              (r, tester.getRect(_wi172RowText(_wi172Rows, r)).height),
        ];

        // The editor body keeps the same rows, the blank one included, and
        // every row, the blank one included (D22, #189: an empty body row is
        // one prose line), lays out at the card row's height.
        await _wi172PumpBody(tester, text);
        expect(_wi172BodyRow(b), findsOneWidget, reason: 'body blank row');
        expect(
          [for (final (r, _) in card) r],
          [for (var r = 0; r < specs.length; r++) r],
          reason: 'the card shows every row of the fixture',
        );
        expect(_wi172BodyRow(specs.length - 1), findsOneWidget);
        expect(_wi172BodyRow(specs.length), findsNothing);
        for (final (r, height) in card) {
          expect(
            _wi172BodyFieldHeight(tester, r),
            closeTo(height, 0.01),
            reason: 'row $r (${specs[r].kind}) lays out as the body row',
          );
        }
      },
    );

    testWidgets(
      'a card keeps every interior empty row and leaves out only the leading and trailing ones',
      (tester) async {
        const text = '\n- a\n\n> q\n\n```\nx\n```\n\n- end\n';
        final specs = _wi172Specs(text);
        expect(
          [for (final s in specs) (s.kind, s.textLength)],
          [
            (RowKind.prose, 0),
            (RowKind.bullet, 1),
            (RowKind.prose, 0),
            (RowKind.quote, 1),
            (RowKind.prose, 0),
            (RowKind.code, 9),
            (RowKind.prose, 0),
            (RowKind.bullet, 3),
            (RowKind.prose, 0),
          ],
        );
        const empty = [2, 4, 6];

        await _wi172PumpRows(tester, text);
        expect(_wi172Row(_wi172Rows, 0), findsNothing, reason: 'leading');
        expect(
          _wi172Row(_wi172Rows, specs.length - 1),
          findsNothing,
          reason: 'trailing',
        );
        final rows = tester.getRect(_wi172Rows);
        var top = rows.top;
        for (var r = 1; r < specs.length - 1; r++) {
          final row = tester.getRect(_wi172Row(_wi172Rows, r));
          expect(row.top, closeTo(top, 0.01), reason: 'row $r stacks');
          if (empty.contains(r)) {
            expect(
              row.height,
              closeTo(_wi172Line, _wi172Y),
              reason: 'interior empty row $r is one blank line',
            );
          }
          top = row.bottom;
        }
        expect(rows.bottom, closeTo(top, 0.01), reason: 'nothing below');
      },
    );

    testWidgets(
      'a card keeps a leading and a trailing empty item row with its marker',
      (tester) async {
        const text = '- \n- a\n- [ ] ';
        final specs = _wi172Specs(text);
        expect(
          [for (final s in specs) (s.kind, s.textLength)],
          [(RowKind.bullet, 0), (RowKind.bullet, 1), (RowKind.task, 0)],
        );
        await _wi172PumpRows(tester, text);
        for (final r in [0, 1, 2]) {
          expect(_wi172Row(_wi172Rows, r), findsOneWidget, reason: 'row $r');
          expect(_wi172Marker(_wi172Rows, r), findsOneWidget, reason: '$r');
        }
        expect(
          tester.getSize(_wi172Rows).height,
          closeTo(3 * _wi172Line, 3 * _wi172Y),
        );
      },
    );

    testWidgets(
      'a card code row lays out its hidden fence lines 8 px tall like the editor body',
      (tester) async {
        const fence = '```\nlet a = 1;\nlet b = 2;\n```';
        const text = 'Before\n$fence\n- item\nAfter';
        final specs = _wi172Specs(text);
        expect(specs[1].kind, RowKind.code);
        await _wi172PumpRows(tester, text);

        final code = _wi172RowText(_wi172Rows, 1);
        final paragraph = tester.renderObject<RenderParagraph>(code);
        final card = [
          for (final line in RenderParagraphLineBoxes(paragraph).lines)
            line.bottom - line.top,
        ];
        expect(card, hasLength(4));
        for (final (i, h) in card.indexed) {
          expect(
            h,
            moreOrLessEquals(i == 0 || i == 3 ? 8 : _wi172Line, epsilon: 0.1),
            reason: 'card code row line $i',
          );
        }
        expect(
          tester.getRect(code).height,
          moreOrLessEquals(16 + 2 * _wi172Line, epsilon: 0.2),
        );
        for (final r in [0, 2, 3]) {
          expect(
            tester.getRect(_wi172RowText(_wi172Rows, r)).height,
            moreOrLessEquals(_wi172Line, epsilon: _wi172Y),
            reason: 'row $r keeps the body strut',
          );
        }
        final rowText = text.substring(specs[1].textStart, specs[1].textEnd);
        List<(String, TextStyle?)> leaves(InlineSpan span) => [
          for (final l in _wi172Leaves(span)) (l.text, l.own),
        ];
        final rendered = leaves(tester.widget<RichText>(code).text);
        expect(
          rendered,
          leaves(
            buildLivePreviewSpan(rowText, forceHidden: true, codeRow: true),
          ),
          reason: 'the code row renders B1 spans with codeRow',
        );
        expect(
          rendered,
          isNot(leaves(buildLivePreviewSpan(rowText, forceHidden: true))),
          reason: 'codeRow changes the span',
        );

        await _wi172PumpBody(tester, text);
        final editable = _wi172BodyEditable(tester, 1);
        final body = [
          for (final line in RenderEditableLineBoxes(editable).lines)
            line.bottom - line.top,
        ];
        expect(body, hasLength(card.length));
        for (final (i, h) in body.indexed) {
          expect(h, moreOrLessEquals(card[i], epsilon: 0.01), reason: '$i');
        }
      },
    );

    test(
      'the code row strut is an 8 px minimum never forced and the default strut is the body strut',
      () {
        final code = livePreviewStrut(codeRow: true);
        expect(code.fontSize, 8);
        expect(code.height, 1);
        expect(code.forceStrutHeight, isNot(true));
        final body = livePreviewStrut();
        expect(body, livePreviewStrut(codeRow: false));
        expect(body.fontSize, 13.5);
        expect(body.height, 1.7);
        expect(body.forceStrutHeight, isNot(true));
        expect(code, isNot(body));
      },
    );
  });

  // -------------------------------------------------------------------------
  // Fix round r2 (review-r2): a card row's text lays out with the body
  // field's even leading, so its glyphs sit where the body row's do; an
  // empty row keeps one prose line (the r1 ruling).
  // -------------------------------------------------------------------------
  group('card row glyphs match the editor body (verify r2)', () {
    testWidgets(
      'every card row with text places its glyphs where the editor body row does for every markdown fixture',
      (tester) async {
        var compared = 0;
        for (final MapEntry(key: name, value: text)
            in markdownFixtures.entries) {
          final specs = _wi172Specs(text);
          await _wi172PumpRows(tester, text);
          final card = <int, _Wi172CardLine>{};
          for (var r = 0; r < specs.length; r++) {
            if (specs[r].textLength == 0) continue;
            final rich = _wi172RowText(_wi172Rows, r);
            expect(rich, findsOneWidget, reason: '$name card row $r');
            final p = tester.renderObject<RenderParagraph>(rich);
            final plain = p.text.toPlainText();
            card[r] = (
              plain: plain,
              glyphs: _wi172GlyphLines(p.getBoxesForSelection, plain.length),
              height: p.size.height,
              strut: p.strutStyle,
            );
          }

          await _wi172PumpBody(tester, text);
          for (final MapEntry(
                key: r,
                value: (:plain, glyphs: boxes, :height, :strut),
              )
              in card.entries) {
            final why = '$name row $r (${specs[r].kind}) "$plain"';
            expect(_wi172BodyRow(r), findsOneWidget, reason: '$why: body');
            final editable = _wi172BodyEditable(tester, r);
            expect(editable.text!.toPlainText(), plain, reason: '$why: text');
            expect(
              strut,
              editable.strutStyle,
              reason: '$why: the strut of the body field',
            );
            expect(editable.size.height, closeTo(height, 0.01), reason: why);
            final body = _wi172GlyphLines(
              editable.getBoxesForSelection,
              plain.length,
            );
            expect(body, hasLength(boxes.length), reason: '$why: extents');
            for (final (i, box) in body.indexed) {
              expect(
                box.top,
                closeTo(boxes[i].top, 0.01),
                reason: '$why: glyph extent $i top',
              );
              expect(
                box.bottom,
                closeTo(boxes[i].bottom, 0.01),
                reason: '$why: glyph extent $i bottom',
              );
            }
            compared++;
          }
        }
        expect(compared, greaterThanOrEqualTo(100), reason: 'rows compared');
      },
    );

    testWidgets(
      'a card row with text keeps one body line and an empty row stays one prose line under even leading',
      (tester) async {
        const text = '- ship A1\n\n> q';
        final specs = _wi172Specs(text);
        expect(
          [for (final s in specs) (s.kind, s.textLength)],
          [(RowKind.bullet, 7), (RowKind.prose, 0), (RowKind.quote, 1)],
        );
        await _wi172PumpRows(tester, text);
        for (final r in [0, 1, 2]) {
          final p = tester.renderObject<RenderParagraph>(
            _wi172RowText(_wi172Rows, r),
          );
          expect(
            p.size.height,
            closeTo(_wi172Line, _wi172Y),
            reason: 'row $r is one body line',
          );
          final strut = tester
              .widget<RichText>(_wi172RowText(_wi172Rows, r))
              .strutStyle!;
          expect(
            strut.fontSize,
            livePreviewStrut().fontSize,
            reason: 'row $r strut',
          );
          expect(strut.height, livePreviewStrut().height, reason: '$r');
        }
        final textRow = tester.renderObject<RenderParagraph>(
          _wi172RowText(_wi172Rows, 0),
        );
        final glyph = _wi172GlyphLines(
          textRow.getBoxesForSelection,
          'ship A1'.length,
        ).single;
        // Even leading splits the line's extra height evenly above and
        // below the glyphs.
        expect(
          glyph.top,
          closeTo(textRow.size.height - glyph.bottom, 0.5),
          reason: 'the glyphs sit centred in the line, as in the body',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // Fix round r3 (review-r3, gate MUTATION survivors): the row decoration
  // cache, the blank-row trim and the line-box adapter's edges.
  // -------------------------------------------------------------------------
  group('card row cache and line box edges (verify r3)', () {
    testWidgets('a card rebuilt with the same text repaints nothing', (
      tester,
    ) async {
      const text = 'x\n> Caret mapping is the risky part.\n- item `code`';
      await _wi172PumpRows(tester, text);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_wi172BoundaryKey),
      );
      int paints() =>
          boundary.debugSymmetricPaintCount +
          boundary.debugAsymmetricPaintCount;
      boundary.debugResetMetrics();
      await _wi172PumpRows(tester, text);
      await tester.pump();
      expect(paints(), 0, reason: 'same rows, same decorations: no repaint');

      await _wi172PumpRows(tester, 'x\n> Caret mapping is the risky part!');
      expect(paints(), greaterThan(0), reason: 'a changed row repaints');
    });

    testWidgets(
      'a card row that changes only between quote and prose repaints its band',
      (tester) async {
        const quoted = '- x\n> Caret mapping is the risky part.';
        const plain = '- x\nCaret mapping is the risky part.';
        final q = _wi172Specs(quoted)[1];
        final p = _wi172Specs(plain)[1];
        expect((q.kind, p.kind), (RowKind.quote, RowKind.prose));
        expect(
          quoted.substring(q.textStart, q.textEnd),
          plain.substring(p.textStart, p.textEnd),
          reason: 'the row text is the same',
        );
        expect(
          (q.textStart == 0, p.textStart == 0),
          (false, false),
          reason: 'neither row is at the segment start',
        );

        Future<Color> bandProbe(String text) async {
          await _wi172PumpRows(tester, text);
          final rows = tester.getRect(_wi172Rows);
          final row = tester.getRect(_wi172Row(_wi172Rows, 1));
          final px = await _wi172Capture(tester, rows.inflate(4));
          return px.at(Offset(rows.right - 1, row.center.dy));
        }

        expect(await bandProbe(quoted), _wi172IsColor(OmColors.surface4));
        expect(
          await bandProbe(plain),
          _wi172IsColor(OmColors.surface3),
          reason: 'quote to prose drops the band',
        );
        expect(
          await bandProbe(quoted),
          _wi172IsColor(OmColors.surface4),
          reason: 'prose to quote paints the band again',
        );
      },
    );

    testWidgets(
      'a card row that changes only its text repaints its decorations',
      (tester) async {
        const before = 'plain words';
        const after = '```\nlet x = 1;\n```';
        final b = _wi172Specs(before).single;
        final a = _wi172Specs(after).single;
        expect((b.kind, a.kind), (RowKind.prose, RowKind.code));
        expect(
          (b.textStart == 0, a.textStart == 0),
          (true, true),
          reason: 'both rows are at the segment start',
        );

        Future<Color> codeBoxProbe(String text) async {
          await _wi172PumpRows(tester, text);
          final rows = tester.getRect(_wi172Rows);
          final row = tester.getRect(_wi172Row(_wi172Rows, 0));
          final px = await _wi172Capture(tester, rows.inflate(4));
          // The code box's left inset, beside the code line (glyph free).
          return px.at(Offset(rows.left + 8, row.center.dy));
        }

        expect(await codeBoxProbe(before), _wi172IsColor(OmColors.surface3));
        expect(
          await codeBoxProbe(after),
          _wi172IsColor(OmColors.surface1),
          reason: 'the new text paints its code box',
        );
      },
    );

    // The trim keeps every row from the first to the last non-blank row
    // (the gate's card_rows.dart:69 `>=` to `>` mutant is equivalent: the
    // trim loop can only reach `last == first` on a non-blank row).
    for (final (name, text, rows) in [
      ('a card of an empty text renders no row', '', <int>[]),
      (
        'a card of one item and a trailing line break renders only the item',
        '- a\n',
        [0],
      ),
      (
        'a card of one item between line breaks renders only the item',
        '\n- a\n',
        [1],
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _wi172PumpRows(tester, text);
        final specs = _wi172Specs(text);
        expect([
          for (var r = 0; r < specs.length; r++)
            if (_wi172Row(_wi172Rows, r).evaluate().isNotEmpty) r,
        ], rows);
        expect(
          tester.getSize(_wi172Rows).height,
          closeTo(rows.length * _wi172Line, _wi172Y),
        );
      });
    }

    testWidgets(
      'paragraph line boxes measure a paragraph that does not wrap as the paragraph lays it out',
      (tester) async {
        const text = 'aaaa bbbb cccc dddd';
        const width = 10 * 13.5;
        // softWrap false lays the line out at infinite width unless the
        // overflow is an ellipsis (as RenderParagraph does). Cards never
        // ellipsize, so the ellipsis case is not pinned here.
        for (final overflow in [
          TextOverflow.clip,
          TextOverflow.visible,
          TextOverflow.fade,
        ]) {
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: RichText(
                    key: const Key('wi172-nowrap'),
                    softWrap: false,
                    overflow: overflow,
                    text: const TextSpan(
                      text: text,
                      style: TextStyle(fontSize: 13.5, height: 1.7),
                    ),
                    strutStyle: livePreviewStrut(),
                  ),
                ),
              ),
            ),
          );
          final paragraph = tester.renderObject<RenderParagraph>(
            find.byKey(const Key('wi172-nowrap')),
          );
          final boxes = RenderParagraphLineBoxes(paragraph);
          final lines = boxes.lines;
          expect(
            [for (final l in lines) l.range.start],
            [0],
            reason: '$overflow: one line, as the paragraph shows',
          );
          expect(lines.single.top, closeTo(0, _wi172Y), reason: '$overflow');
          expect(
            lines.single.bottom,
            closeTo(paragraph.size.height, _wi172Y),
            reason: '$overflow: the line is the paragraph',
          );
          final own = paragraph
              .getBoxesForSelection(
                const TextSelection(baseOffset: 0, extentOffset: 4),
              )
              .single
              .toRect();
          final measured = boxes.boxesFor(const TextRange(start: 0, end: 4));
          expect(measured, hasLength(1), reason: '$overflow');
          expect(
            measured.single.right,
            closeTo(own.right, 0.01),
            reason: '$overflow: the first word where the paragraph puts it',
          );
          final tail = boxes.boxesFor(
            TextRange(start: text.length - 4, end: text.length),
          );
          expect(
            tail.single.right,
            closeTo(text.length * 13.5, 0.01),
            reason: '$overflow: the line runs past the width unwrapped',
          );
        }
      },
    );

    // The gate's paragraph_line_boxes.dart:134 `>=` to `>` mutant is
    // equivalent: at start == text.length the engine's line boundary ends at
    // text.length, so both paths give text.length.
    testWidgets(
      'paragraph line boxes end with an empty line at the text end after a line break',
      (tester) async {
        for (final (text, ranges) in [
          ('', [(0, 0)]),
          ('a\n', [(0, 1), (2, 2)]),
          ('a\n\n', [(0, 1), (2, 2), (3, 3)]),
        ]) {
          await tester.pumpWidget(
            Directionality(
              textDirection: TextDirection.ltr,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  child: RichText(
                    key: const Key('wi172-end'),
                    text: TextSpan(
                      text: text,
                      style: const TextStyle(fontSize: 13.5, height: 1.7),
                    ),
                    strutStyle: livePreviewStrut(),
                  ),
                ),
              ),
            ),
          );
          final boxes = RenderParagraphLineBoxes(
            tester.renderObject<RenderParagraph>(
              find.byKey(const Key('wi172-end')),
            ),
          );
          final lines = boxes.lines;
          expect(
            [for (final l in lines) (l.range.start, l.range.end)],
            ranges,
            reason: '"$text"',
          );
          expect(
            lines.last.bottom - lines.last.top,
            closeTo(_wi172Line, _wi172Y),
            reason: '"$text": the last line measures a full line',
          );
          expect(
            boxes.caretRect(text.length).top,
            closeTo(lines.last.top, _wi172Y),
            reason: '"$text": the caret at the end sits on the last line',
          );
        }
      },
    );
  });
}

/// One card row measured for the body comparison (verify r2).
typedef _Wi172CardLine = ({
  String plain,
  List<({double top, double bottom})> glyphs,
  double height,
  StrutStyle? strut,
});

/// The vertical extents (top, bottom) of a row text's tight glyph boxes
/// over characters `0..length`, through [boxesFor] (a RenderParagraph's or
/// a RenderEditable's), one per distinct extent, top to bottom. Run splits
/// differ between a RichText and a field, so boxes are not compared one by
/// one.
List<({double top, double bottom})> _wi172GlyphLines(
  List<TextBox> Function(TextSelection) boxesFor,
  int length,
) {
  final seen = <String>{};
  final out = <({double top, double bottom})>[];
  for (final box in boxesFor(
    TextSelection(baseOffset: 0, extentOffset: length),
  )) {
    final key =
        '${box.top.toStringAsFixed(2)}/${box.bottom.toStringAsFixed(2)}';
    if (seen.add(key)) out.add((top: box.top, bottom: box.bottom));
  }
  out.sort((a, b) => a.top.compareTo(b.top));
  return out;
}

// ------------------------------------------------------------- editor body

/// Pumps the editor body (SegmentedBody) of a topic note holding [text], at
/// the card harness's view size, so a card row can be measured against the
/// body row for the same text.
Future<void> _wi172PumpBody(WidgetTester tester, String text) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: SegmentedBody(
            note: Note(
              id: 'topic-172',
              title: 'Cards',
              contentMd: text,
              frontmatter: '{"role":"topic"}',
              version: 3,
              createdAt: 0,
              updatedAt: 0,
              tags: const [],
            ),
            content: text,
            savedVersion: 3,
            onContentChanged: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Editor body row [r] of the first text segment.
Finder _wi172BodyRow(int r) => find.byKey(Key('editor-row-0-$r'));

/// The RenderEditable of editor body row [r].
RenderEditable _wi172BodyEditable(WidgetTester tester, int r) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  visit(tester.renderObject(_wi172BodyRow(r)));
  if (found == null) throw TestFailure('No RenderEditable in body row $r');
  return found!;
}

/// The laid-out height of editor body row [r]'s field.
double _wi172BodyFieldHeight(WidgetTester tester, int r) =>
    _wi172BodyEditable(tester, r).size.height;
