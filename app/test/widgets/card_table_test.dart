// WI #208 (T7, Spec #197 R25, TD6; rulings D12, D14, D16, D18, D19a, D23):
// read-only excerpt cards render a table row with the editor's TableGrid.
// - CardRows on its own: the grid under Key `card-table-<r>` (r = the card
//   row index) with `headerBand: OmColors.surface4`, the card text style
//   (`fg1`), no link controller (never revealed, no Cmd-hover); markers
//   hidden with the editor grid's cell styles (D16); two consecutive tables
//   give two grids with no gap, and a pipe paragraph after a table joins it
//   (D23); non-table rows around a table render as without it.
// - Through the workspace: a card holding a table block shows the grid; a
//   click, a double-click and a Cmd+click on a cell, a wikilink or a URL in
//   it change nothing and open nothing; Cmd-hover shows no pointer cursor.
//
// Face-agnostic (D18): press points and probe points come from the grid's
// `TableGridState.lineBoxes()` seam, never from design numbers. Pixel probes
// (D19a) only in the header band's bottom 4 px inside the first and last
// header cells' padding strips; they assume T4's (#205) painted grid.
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/row_geometry.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/editor/card_rows.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/marker_column.dart';
import 'package:open_memex_app/src/widgets/editor/table_grid.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/editor_scope.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/table_harness.dart';

// ------------------------------------------------------------------ fixtures

/// A table with inline formatting, an aligned last column and two body rows.
const _wi208Table =
    '| Step | Note | Est. h |\n'
    '|:--|:--|--:|\n'
    '| **Marker** parser | *ask* Connor | 1.5 |\n'
    '| Byte offsets | plain | 2 |';

/// A card excerpt: a prose block, then the table block (blocks joined with
/// one `\n`, as `renderExcerpt` does).
const _wi208CardText = 'Timings from the spike:\n$_wi208Table';

/// Every inline token kind in table cells (R20).
const _wi208MarkupTable =
    '| Kind | Shows |\n'
    '|---|---|\n'
    '| **bold** | *it* |\n'
    '| ~~gone~~ | `code` |\n'
    '| [[Note]] | [site](https://example.com) |';

const _wi208BoundaryKey = Key('wi208-boundary');
const _wi208RowsKey = Key('wi208-rows');

/// The card table grid of card row [r] (Key `card-table-<r>`).
Finder _wi208Grid(int r, {Finder? under}) {
  final key = find.byKey(Key('card-table-$r'));
  return under == null ? key : find.descendant(of: under, matching: key);
}

/// The [TableGrid] widget of card row [r].
TableGrid _wi208GridWidget(WidgetTester tester, int r, {Finder? under}) {
  final w = tester.widget(_wi208Grid(r, under: under));
  expect(w, isA<TableGrid>(), reason: 'card-table-$r is a TableGrid');
  return w as TableGrid;
}

/// The laid-out line boxes of card row [r]'s grid.
LineBoxSource _wi208Boxes(WidgetTester tester, int r, {Finder? under}) {
  final state = tester.state<TableGridState>(_wi208Grid(r, under: under));
  return state.lineBoxes() ??
      (throw TestFailure('card-table-$r is not laid out'));
}

/// The global rect of [token]'s glyphs (first visual line) in [table], the
/// text of card row [r]'s grid, through the grid's line-box seam (D18).
Rect _wi208TokenRect(
  WidgetTester tester,
  int r,
  String table,
  String token, {
  Finder? under,
}) {
  final at = table.indexOf(token);
  expect(at, isNonNegative, reason: '"$token" in the table');
  final boxes = _wi208Boxes(tester, r, under: under);
  final rects = boxes.boxesFor(TextRange(start: at, end: at + token.length));
  expect(rects, isNotEmpty, reason: '"$token" has glyph boxes');
  final local = rects.first;
  return Rect.fromPoints(
    boxes.box.localToGlobal(local.topLeft),
    boxes.box.localToGlobal(local.bottomRight),
  );
}

/// Pumps [CardRows] of [text], [width] wide, on the card's `surface3` fill
/// inside a repaint boundary (for pixel probes), at text scale 1.
Future<void> _wi208PumpRows(
  WidgetTester tester,
  String text, {
  double width = 736,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: _wi208BoundaryKey,
            child: Container(
              color: OmColors.surface3,
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: width,
                child: CardRows(key: _wi208RowsKey, text: text),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder get _wi208Rows => find.byKey(_wi208RowsKey);

/// Row [r]'s text holder (Key `card-row-text-<r>`).
Finder _wi208RowTextKey(int r) => find.descendant(
  of: _wi208Rows,
  matching: find.byKey(Key('card-row-text-$r')),
);

/// Row [r]'s text (Key `card-row-text-<r>`): its RichText.
Finder _wi208RowText(int r) => find.descendant(
  of: find.descendant(
    of: _wi208Rows,
    matching: find.byKey(Key('card-row-text-$r')),
  ),
  matching: find.byType(RichText),
);

// --------------------------------------------------------------- span leaves

/// One leaf of a span tree: its text and its effective (merged) style.
typedef _Wi208Leaf = ({String text, TextStyle style, bool recognizer});

/// Every non-empty text leaf of [root], in order.
List<_Wi208Leaf> _wi208Leaves(InlineSpan root) {
  final out = <_Wi208Leaf>[];
  void visit(InlineSpan span, TextStyle inherited) {
    final style = span.style == null ? inherited : inherited.merge(span.style);
    if (span is TextSpan) {
      final text = span.text;
      if (text != null && text.isNotEmpty) {
        out.add((
          text: text,
          style: style,
          recognizer: span.recognizer != null,
        ));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    } else {
      out.add((text: '￼', style: style, recognizer: false));
    }
  }

  visit(root, const TextStyle());
  return out;
}

/// Whether [leaf] shows: not a zero-size hidden marker, not transparent.
bool _wi208Shows(_Wi208Leaf leaf) =>
    leaf.style.fontSize != 0 &&
    (leaf.style.color == null || leaf.style.color!.a > 0);

/// The visible leaves of every RichText under [scope], in tree order.
List<_Wi208Leaf> _wi208VisibleLeaves(WidgetTester tester, Finder scope) => [
  for (final w in tester.widgetList<RichText>(
    find.descendant(of: scope, matching: find.byType(RichText)),
  ))
    ..._wi208Leaves(w.text).where(_wi208Shows),
];

/// The visible text under [scope], joined.
String _wi208Visible(WidgetTester tester, Finder scope) =>
    [for (final l in _wi208VisibleLeaves(tester, scope)) l.text].join();

/// A comparable description of a leaf's token styling (everything but its
/// colour, size and font family).
String _wi208Shape(_Wi208Leaf l) =>
    '${l.text}|w=${l.style.fontWeight ?? FontWeight.w400}'
    '|i=${l.style.fontStyle ?? FontStyle.normal}'
    '|d=${l.style.decoration ?? TextDecoration.none}'
    '|ds=${l.style.decorationStyle}'
    '|dc=${l.style.decorationColor}'
    '|bg=${l.style.backgroundColor}';

// ------------------------------------------------------------------- pixels

/// Pixels of a region of the repaint boundary.
class _Wi208Pixels {
  _Wi208Pixels(this._bytes, this.width, this.height, this.rect, this.ratio);

  final ByteData _bytes;
  final int width;
  final int height;
  final Rect rect;
  final double ratio;

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

Future<_Wi208Pixels> _wi208Capture(
  WidgetTester tester,
  Rect region, {
  double ratio = 4,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_wi208BoundaryKey),
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
  final pixels = _Wi208Pixels(
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
class _Wi208Near extends Matcher {
  const _Wi208Near(this.expected);

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

// ---------------------------------------------------------------- workspace

const _wi208LinkedId = 'topic-wi208-conflict';
const _wi208Url = 'https://example.com/wi208';

/// The workspace card's table block: a resolved wikilink and a URL in cells.
const _wi208LinkTable =
    '| Step | Link | Est. h |\n'
    '|:--|:--|--:|\n'
    '| Marker parser | [[Conflict merge]] | 1.5 |\n'
    '| Byte offsets | [site]($_wi208Url) | 2 |';

/// A V5 vault whose topic body is `Intro line`, a card of [blocks] (card
/// 1), `Outro line`; the blocks are daily blocks `wi208a`.., and the topic
/// note `Conflict merge` exists (a link that opened would open a tab).
({FakeVaultDb db, FakeMemexCli cli}) _wi208Vault(List<String> blocks) {
  final ids = [for (var i = 0; i < blocks.length; i++) 'wi208${'abcdef'[i]}'];
  final token = blocks.length == 1
      ? '![[2026-09-05#^${ids.first}]]'
      : '![[2026-09-05#^${ids.first}..^${ids.last}]]';
  final vault = seedSegmentedVault(
    topicBody: 'Intro line\n$token\nOutro line\n',
  );
  for (final (i, text) in blocks.indexed) {
    vault.db.seedBlock(fixtureDailyId, ids[i], ord: 3 + i, text: text);
  }
  vault.db.seedTopicNote(_wi208LinkedId, 'Conflict merge');
  return vault;
}

/// Launches the workspace on [vault] with [opener] as the URL opener and
/// opens the topic note.
Future<SegmentedEditorRobot> _wi208Launch(
  WidgetTester tester,
  ({FakeVaultDb db, FakeMemexCli cli}) vault,
  UrlOpener opener,
) async {
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    overrides: [urlOpenerProvider.overrideWithValue(opener)],
  );
  final r = SegmentedEditorRobot(tester, h);
  await r.open(fixtureTopicId);
  return r;
}

/// Whether the primary focus sits inside [scope].
bool _wi208FocusInside(Finder scope) {
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

/// What a display-only card must keep across a gesture: every text
/// segment's selection and focus, and the card grid's painted spans.
typedef _Wi208Snapshot = ({
  List<TextSelection> selections,
  List<bool> focused,
  List<String> spans,
});

_Wi208Snapshot _wi208Snap(
  WidgetTester tester,
  SegmentedEditorRobot r,
  Finder grid,
) => (
  selections: [for (final s in r.allSegments) s.selection],
  focused: [for (final s in r.allSegments) s.focusedRow != null],
  spans: [for (final l in _wi208VisibleLeaves(tester, grid)) _wi208Shape(l)],
);

/// Expects the card [card] to still show its grid [grid] as before: no
/// field, no focus, no selection change, the same painted spans.
void _wi208ExpectUnchanged(
  WidgetTester tester,
  SegmentedEditorRobot r,
  Finder card,
  Finder grid,
  _Wi208Snapshot before,
  String why,
) {
  expect(grid, findsOneWidget, reason: '$why: the grid still shows');
  expect(
    find.descendant(of: card, matching: find.byType(EditableText)),
    findsNothing,
    reason: '$why: no field (no caret, no reveal) in the card',
  );
  expect(_wi208FocusInside(card), isFalse, reason: '$why: no focus in card');
  final after = _wi208Snap(tester, r, grid);
  expect(after.selections, before.selections, reason: '$why: selections');
  expect(after.focused, before.focused, reason: '$why: segment focus');
  expect(after.spans, before.spans, reason: '$why: painted spans');
}

/// A primary double-click at global [at]: two clicks inside the double-tap
/// window (after its minimum gap), then the window passes.
Future<void> _wi208DoubleClick(WidgetTester tester, Offset at) async {
  await tester.macClick(at);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.macClick(at);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: the card grid, surface4 band, fg1 text
  // -------------------------------------------------------------------------
  group('card table grid (AC1)', () {
    testWidgets(
      'a card table row renders as a TableGrid keyed card-table-r with the surface4 band and no link controller',
      (tester) async {
        await _wi208PumpRows(tester, _wi208CardText);
        final specs = splitRows(_wi208CardText, atSegmentStart: true);
        expect(
          [for (final s in specs) s.kind],
          [RowKind.prose, RowKind.table],
          reason: 'fixture: a prose row then a table row',
        );

        expect(_wi208Grid(1, under: _wi208Rows), findsOneWidget);
        final grid = _wi208GridWidget(tester, 1, under: _wi208Rows);
        expect(
          grid.text,
          _wi208CardText.substring(specs[1].textStart, specs[1].textEnd),
          reason: 'the grid shows the table row text',
        );
        expect(grid.text, _wi208Table);
        expect(grid.headerBand, OmColors.surface4, reason: 'card band');
        expect(grid.links, isNull, reason: 'no link state: never revealed');
        expect(
          _wi208Grid(0, under: _wi208Rows),
          findsNothing,
          reason: 'the prose row is no grid',
        );
        expect(
          _wi208Visible(tester, _wi208RowTextKey(0)),
          'Timings from the spike:',
          reason: 'the prose row still renders as card row text',
        );

        // The table text is painted once, by the grid only.
        final holders = find.descendant(
          of: _wi208Rows,
          matching: find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText().contains('offsets'),
          ),
        );
        expect(holders, findsOneWidget, reason: 'one painter of the cell');
        expect(
          find.descendant(
            of: _wi208Grid(1, under: _wi208Rows),
            matching: holders,
          ),
          findsOneWidget,
          reason: 'the cell is painted inside the grid',
        );
      },
    );

    testWidgets(
      'a card table grid sits inside its card-row-r and the row is the grid size',
      (tester) async {
        await _wi208PumpRows(tester, _wi208CardText);
        final row = find.descendant(
          of: _wi208Rows,
          matching: find.byKey(const ValueKey('card-row-1')),
        );
        expect(row, findsOneWidget, reason: 'the table row keeps card-row-1');
        expect(
          find.descendant(of: row, matching: _wi208Grid(1)),
          findsOneWidget,
          reason: 'card-table-1 is a descendant of card-row-1',
        );
        expect(
          tester.getSize(row),
          tester.getSize(_wi208Grid(1, under: _wi208Rows)),
          reason: 'no decoration wrapper adds padding around the grid',
        );
      },
    );

    testWidgets(
      'a card table lays its cells out in the card text style in fg1',
      (tester) async {
        await _wi208PumpRows(tester, _wi208CardText);
        final grid = _wi208GridWidget(tester, 1, under: _wi208Rows);
        expect(grid.style.color, OmColors.fg1, reason: 'card text is fg1');
        expect(grid.style.fontSize, monoFontSize, reason: 'card body size');

        final leaves = _wi208VisibleLeaves(
          tester,
          _wi208Grid(1, under: _wi208Rows),
        );
        final shown = [for (final l in leaves) l.text].join();
        for (final word in ['Step', 'Marker', 'ask', 'Byte offsets', '1.5']) {
          expect(shown, contains(word), reason: '"$word" shows');
        }
        for (final l in leaves) {
          if (l.text.trim().isEmpty) continue;
          expect(
            l.style.color,
            OmColors.fg1,
            reason: 'the run "${l.text}" is fg1, never fg0',
          );
        }
      },
    );

    testWidgets(
      'a card table grid takes the card row style with even leading and the surface4 band',
      (tester) async {
        await _wi208PumpRows(tester, _wi208CardText);
        final grid = _wi208GridWidget(tester, 1, under: _wi208Rows);
        expect(
          grid.style.leadingDistribution,
          TextLeadingDistribution.even,
          reason: 'a card row with text lays out with even leading',
        );
        expect(grid.style.height, 1.7, reason: 'the card body line height');
        expect(grid.headerBand, OmColors.surface4, reason: 'card band color');
        expect(grid.links, isNull, reason: 'no link controller in a card');
      },
    );

    testWidgets(
      'the card table header band bottom 4 px padding strips are surface4',
      (tester) async {
        // Assumes T4's (#205) painted grid: T3's stub paints no band.
        await _wi208PumpRows(tester, _wi208CardText);
        final gridFinder = _wi208Grid(1, under: _wi208Rows);
        expect(gridFinder, findsOneWidget);
        final boxes = _wi208Boxes(tester, 1, under: _wi208Rows);
        final gridRect = tester.getRect(gridFinder);

        // The band ends where the first body row starts.
        final firstBody = _wi208Table.indexOf('| **Marker**');
        final bandBottom = lineHolding(boxes.lines, firstBody).top;
        // The first header cell's glyphs, and the last (right aligned) one's.
        final step = boxes
            .boxesFor(
              TextRange(
                start: _wi208Table.indexOf('Step'),
                end: _wi208Table.indexOf('Step') + 4,
              ),
            )
            .first;
        final est = boxes
            .boxesFor(
              TextRange(
                start: _wi208Table.indexOf('Est. h'),
                end: _wi208Table.indexOf('Est. h') + 6,
              ),
            )
            .first;
        expect(step.left, greaterThan(1), reason: 'a left padding strip');
        expect(
          est.right,
          lessThan(boxes.box.size.width - 1),
          reason: 'a right padding strip',
        );
        final y = bandBottom - 2;
        final left = boxes.box.localToGlobal(Offset(step.left / 2, y));
        final right = boxes.box.localToGlobal(
          Offset((est.right + boxes.box.size.width) / 2, y),
        );
        final outside = Offset(gridRect.left - 10, left.dy);

        final pixels = await _wi208Capture(
          tester,
          Rect.fromLTRB(
            gridRect.left - 12,
            gridRect.top,
            gridRect.right,
            gridRect.bottom,
          ),
        );
        expect(
          pixels.at(outside),
          const _Wi208Near(OmColors.surface3),
          reason: 'the card fill beside the table',
        );
        expect(
          pixels.at(left),
          const _Wi208Near(OmColors.surface4),
          reason: 'band bottom, first cell left padding',
        );
        expect(
          pixels.at(right),
          const _Wi208Near(OmColors.surface4),
          reason: 'band bottom, last cell right padding',
        );
      },
    );

    testWidgets(
      'an excerpt card holding a table block shows a card-table grid',
      (tester) async {
        final r = await _wi208Launch(
          tester,
          _wi208Vault(['Timings from the spike:', _wi208LinkTable]),
          RecordingUrlOpener(),
        );
        final card = r.card(1);
        expect(card, findsOneWidget);
        expect(_wi208Grid(1, under: card), findsOneWidget);
        final grid = _wi208GridWidget(tester, 1, under: card);
        expect(grid.text, _wi208LinkTable);
        expect(grid.headerBand, OmColors.surface4);
        expect(grid.links, isNull);
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC2: display only (R25, D14)
  // -------------------------------------------------------------------------
  group('display only (AC2)', () {
    testWidgets(
      'clicking and double clicking a card table cell changes no selection and reveals nothing',
      (tester) async {
        final opener = RecordingUrlOpener();
        final r = await _wi208Launch(
          tester,
          _wi208Vault(['Timings from the spike:', _wi208LinkTable]),
          opener,
        );
        final card = r.card(1);
        final grid = _wi208Grid(1, under: card);
        expect(grid, findsOneWidget);
        final tabChanges = <TabsState>[];
        final sub = r.h.container.listen(
          tabsProvider,
          (_, next) => tabChanges.add(next),
        );
        addTearDown(sub.close);
        final before = _wi208Snap(tester, r, grid);
        final cell = _wi208TokenRect(
          tester,
          1,
          _wi208LinkTable,
          'parser',
          under: card,
        ).center;
        final link = _wi208TokenRect(
          tester,
          1,
          _wi208LinkTable,
          'Conflict merge',
          under: card,
        ).center;

        await tester.macClick(cell);
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
        _wi208ExpectUnchanged(tester, r, card, grid, before, 'click a cell');

        await _wi208DoubleClick(tester, cell);
        _wi208ExpectUnchanged(tester, r, card, grid, before, 'double click');

        await tester.macClick(link);
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
        _wi208ExpectUnchanged(tester, r, card, grid, before, 'click a link');

        await r.waitForSave();
        expect(tabChanges, isEmpty, reason: 'no tab opened or focused');
        expect(opener.opened, isEmpty, reason: 'no URL opened');
        expect(r.updates, isEmpty, reason: 'no write');
      },
      variant: macOnly,
    );

    testWidgets(
      'cmd clicking a wikilink and a url in a card table opens nothing',
      (tester) async {
        final opener = RecordingUrlOpener();
        final r = await _wi208Launch(
          tester,
          _wi208Vault(['Timings from the spike:', _wi208LinkTable]),
          opener,
        );
        r.expectActiveNote(fixtureTopicId);
        final card = r.card(1);
        final grid = _wi208Grid(1, under: card);
        expect(grid, findsOneWidget);
        final tabChanges = <TabsState>[];
        final sub = r.h.container.listen(
          tabsProvider,
          (_, next) => tabChanges.add(next),
        );
        addTearDown(sub.close);
        final tabs = r.h.read(tabsProvider).tabs.length;
        final before = _wi208Snap(tester, r, grid);

        for (final token in ['Conflict merge', 'site', 'Byte']) {
          final at = _wi208TokenRect(
            tester,
            1,
            _wi208LinkTable,
            token,
            under: card,
          ).center;
          await tester.macCmdClick(at);
          await pumpFrames(tester);
          await tester.pump(
            kDoubleTapTimeout + const Duration(milliseconds: 1),
          );
          _wi208ExpectUnchanged(
            tester,
            r,
            card,
            grid,
            before,
            'cmd click $token',
          );
        }
        await r.waitForSave();

        r.expectActiveNote(fixtureTopicId);
        expect(r.h.read(tabsProvider).tabs, hasLength(tabs));
        expect(
          r.h
              .read(tabsProvider)
              .tabs
              .whereType<NoteTab>()
              .where((t) => t.id == _wi208LinkedId),
          isEmpty,
          reason: 'the linked note never opens',
        );
        expect(tabChanges, isEmpty, reason: 'tabsProvider never changes');
        expect(opener.opened, isEmpty, reason: 'the URL opener is not called');
        expect(r.updates, isEmpty);
      },
      variant: macOnly,
    );

    testWidgets(
      'cmd hovering a card table link shows no pointer cursor and no hover style',
      (tester) async {
        final r = await _wi208Launch(
          tester,
          _wi208Vault(['Timings from the spike:', _wi208LinkTable]),
          RecordingUrlOpener(),
        );
        final card = r.card(1);
        final grid = _wi208Grid(1, under: card);
        expect(grid, findsOneWidget);
        final before = _wi208Snap(tester, r, grid);
        final points = {
          for (final token in ['Conflict merge', 'site', 'Marker'])
            token: _wi208TokenRect(
              tester,
              1,
              _wi208LinkTable,
              token,
              under: card,
            ).center,
        };

        for (final MapEntry(key: token, value: at) in points.entries) {
          expect(
            await tester.macCursorAt(at),
            isNot(SystemMouseCursors.click),
            reason: 'over $token',
          );
          expect(
            await tester.macHolding([
              LogicalKeyboardKey.metaLeft,
            ], () => tester.macCursorAt(at)),
            isNot(SystemMouseCursors.click),
            reason: 'cmd over $token',
          );
        }

        // A mouse resting on the wikilink with Cmd held: no hover style.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: points['Conflict merge']!);
        await tester.pump();
        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          await tester.pump();
          _wi208ExpectUnchanged(tester, r, card, grid, before, 'cmd hover');
        });
        await mouse.removePointer();
        await tester.pump();
      },
      variant: macOnly,
    );

    testWidgets(
      'a card table adds no gesture recognizer mouse region or span recognizer',
      (tester) async {
        await _wi208PumpRows(tester, 'Intro\n$_wi208MarkupTable');
        final grid = _wi208Grid(1, under: _wi208Rows);
        expect(grid, findsOneWidget);
        for (final type in [GestureDetector, RawGestureDetector, MouseRegion]) {
          expect(
            find.descendant(of: grid, matching: find.byType(type)),
            findsNothing,
            reason: 'no $type in the grid',
          );
          expect(
            find
                .ancestor(of: grid, matching: find.byType(type))
                .evaluate()
                .where(
                  (e) => find
                      .descendant(
                        of: _wi208Rows,
                        matching: find.byElementPredicate(
                          (x) => identical(x, e),
                        ),
                      )
                      .evaluate()
                      .isNotEmpty,
                ),
            isEmpty,
            reason: 'no $type between the card rows and the grid',
          );
        }
        for (final l in _wi208VisibleLeaves(tester, grid)) {
          expect(l.recognizer, isFalse, reason: 'the run "${l.text}"');
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC3: markers hidden, the editor grid's cell styles (D16)
  // -------------------------------------------------------------------------
  group('markers hidden (AC3)', () {
    testWidgets('card table cells hide every inline marker', (tester) async {
      await _wi208PumpRows(tester, 'Intro\n$_wi208MarkupTable');
      final grid = _wi208Grid(1, under: _wi208Rows);
      expect(grid, findsOneWidget);
      final shown = _wi208Visible(tester, grid);
      for (final marker in ['**', '`', '[[', ']]', '~~', '](', 'https://']) {
        expect(shown, isNot(contains(marker)), reason: '"$marker" is hidden');
      }
      for (final word in ['bold', 'it', 'gone', 'code', 'Note', 'site']) {
        expect(shown, contains(word), reason: '"$word" shows');
      }
    });

    testWidgets(
      'card table cells carry the same token styles as the editor grid cells',
      (tester) async {
        // The editor's rendered grid of the same table (wikilink resolved).
        await pumpTable(
          tester,
          '$_wi208MarkupTable\n',
          titles: [NoteTitle(id: 'note-wi208', title: 'Note', updatedAt: 0)],
        );
        await tester.pump();
        await tester.pump();
        expectTableRendered(0, 0);
        final editorGrid = tester.widget<TableGrid>(tableGrid(0, 0));
        final editorBase = editorGrid.style.color;
        final editor = _wi208VisibleLeaves(tester, tableGrid(0, 0));
        expect(editor, isNotEmpty);

        await _wi208PumpRows(tester, 'Intro\n$_wi208MarkupTable');
        final cardGrid = _wi208Grid(1, under: _wi208Rows);
        expect(cardGrid, findsOneWidget);
        final card = _wi208VisibleLeaves(tester, cardGrid);

        expect(
          [for (final l in card) _wi208Shape(l)],
          [for (final l in editor) _wi208Shape(l)],
          reason: 'same runs, weights, slants, decorations and fills',
        );
        for (final (i, l) in card.indexed) {
          final e = editor[i];
          final expected = e.style.color == editorBase
              ? OmColors.fg1
              : e.style.color;
          expect(
            l.style.color,
            expected,
            reason: 'run "${l.text}": the token colour, or fg1 for base text',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC4: several tables, joined pipe paragraph (D23)
  // -------------------------------------------------------------------------
  group('several tables (AC4, D23)', () {
    const first = '| a | b |\n|---|---|\n| 1 | 2 |';
    const second = '| c | d |\n|---|---|\n| 3 | 4 |';

    testWidgets(
      'two consecutive tables in a card render two grids with no gap',
      (tester) async {
        await _wi208PumpRows(tester, [first, second].join('\n'));
        final g0 = _wi208Grid(0, under: _wi208Rows);
        final g1 = _wi208Grid(1, under: _wi208Rows);
        expect(g0, findsOneWidget);
        expect(g1, findsOneWidget);
        expect(_wi208GridWidget(tester, 0, under: _wi208Rows).text, first);
        expect(_wi208GridWidget(tester, 1, under: _wi208Rows).text, second);
        for (final r in [0, 1]) {
          expect(
            _wi208GridWidget(tester, r, under: _wi208Rows).headerBand,
            OmColors.surface4,
          );
        }
        final a = tester.getRect(g0);
        final b = tester.getRect(g1);
        expect(a.height, greaterThan(0));
        expect(b.top - a.bottom, closeTo(0, 0.01), reason: 'no gap (0 px)');
        expect(b.left, closeTo(a.left, 0.01), reason: 'same left edge');
        expect(b.width, closeTo(a.width, 0.01), reason: 'same width');
      },
    );

    testWidgets(
      'a pipe paragraph after a card table renders as a body row of it',
      (tester) async {
        const text = '$first\nTotals | 3';
        await _wi208PumpRows(tester, text);
        final grid = _wi208Grid(0, under: _wi208Rows);
        expect(grid, findsOneWidget);
        expect(
          _wi208GridWidget(tester, 0, under: _wi208Rows).text,
          text,
          reason: 'the paragraph is part of the table text',
        );
        expect(_wi208Visible(tester, grid), contains('Totals'));
        expect(
          find.descendant(
            of: _wi208Rows,
            matching: find.byKey(const Key('card-row-1')),
          ),
          findsNothing,
          reason: 'no second card row',
        );
        expect(_wi208Grid(1, under: _wi208Rows), findsNothing);
      },
    );

    testWidgets('an excerpt of two table blocks shows two grids in one card', (
      tester,
    ) async {
      final r = await _wi208Launch(
        tester,
        _wi208Vault([first, second]),
        RecordingUrlOpener(),
      );
      final card = r.card(1);
      expect(_wi208Grid(0, under: card), findsOneWidget);
      expect(_wi208Grid(1, under: card), findsOneWidget);
      expect(_wi208GridWidget(tester, 0, under: card).text, first);
      expect(_wi208GridWidget(tester, 1, under: card).text, second);
      final a = tester.getRect(_wi208Grid(0, under: card));
      final b = tester.getRect(_wi208Grid(1, under: card));
      expect(b.top - a.bottom, closeTo(0, 0.01), reason: 'no gap (0 px)');
    });

    testWidgets(
      'an excerpt whose block after a table is a pipe paragraph joins it as a body row',
      (tester) async {
        final r = await _wi208Launch(
          tester,
          _wi208Vault([first, 'Totals | 3']),
          RecordingUrlOpener(),
        );
        final card = r.card(1);
        expect(_wi208Grid(0, under: card), findsOneWidget);
        expect(
          _wi208GridWidget(tester, 0, under: card).text,
          '$first\nTotals | 3',
        );
        expect(_wi208Grid(1, under: card), findsNothing);
        expect(
          find.descendant(
            of: card,
            matching: find.byKey(const Key('card-row-1')),
          ),
          findsNothing,
          reason: 'the paragraph is no card row of its own',
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // AC5: non-table rows render as before
  // -------------------------------------------------------------------------
  group('non-table rows (AC5)', () {
    const before =
        'Intro prose with **bold**\n'
        '- bullet item\n'
        '- [ ] task item\n'
        '1. numbered item\n'
        '> quoted line\n'
        '```\n'
        'code line\n'
        '```';
    const table = '| a | b |\n|---|---|\n| 1 | 2 |';
    const after = 'After prose';

    /// Each card row's rect (relative to the rows' top left), visible span
    /// shapes and colours, and marker column, for rows [rows].
    List<String> describeRows(WidgetTester tester, Iterable<int> rows) {
      final origin = tester.getTopLeft(_wi208Rows);
      return [
        for (final r in rows)
          [
            'row $r',
            tester
                .getRect(
                  find.descendant(
                    of: _wi208Rows,
                    matching: find.byKey(Key('card-row-$r')),
                  ),
                )
                .shift(-origin)
                .toString(),
            tester.getRect(_wi208RowText(r)).shift(-origin).toString(),
            for (final l in _wi208VisibleLeaves(
              tester,
              find.descendant(
                of: _wi208Rows,
                matching: find.byKey(Key('card-row-text-$r')),
              ),
            ))
              '${_wi208Shape(l)}|c=${l.style.color}',
            for (final m in tester.widgetList<MarkerColumn>(
              find.descendant(
                of: find.descendant(
                  of: _wi208Rows,
                  matching: find.byKey(Key('card-row-$r')),
                ),
                matching: find.byType(MarkerColumn),
              ),
            ))
              'marker ${m.marker} ${m.width} ${m.readOnly}',
          ].join(' / '),
      ];
    }

    testWidgets(
      'prose item quote and code card rows around a table render as without it',
      (tester) async {
        final kinds = [
          for (final s in splitRows(
            '$before\n$table\n$after',
            atSegmentStart: true,
          ))
            s.kind,
        ];
        expect(kinds, [
          RowKind.prose,
          RowKind.bullet,
          RowKind.task,
          RowKind.numbered,
          RowKind.quote,
          RowKind.code,
          RowKind.table,
          RowKind.prose,
        ], reason: 'fixture rows');

        // Without the table.
        await _wi208PumpRows(tester, '$before\n$after');
        final plainRows = describeRows(tester, [0, 1, 2, 3, 4, 5]);
        final plainAfter = describeRows(tester, [6]);
        final plainAfterHeight = tester.getRect(_wi208RowText(6)).height;

        // With the table between the code row and the last prose row.
        await _wi208PumpRows(tester, '$before\n$table\n$after');
        expect(_wi208Grid(6, under: _wi208Rows), findsOneWidget);
        expect(_wi208GridWidget(tester, 6, under: _wi208Rows).text, table);
        expect(
          describeRows(tester, [0, 1, 2, 3, 4, 5]),
          plainRows,
          reason: 'rows above the table render exactly as before',
        );

        // The row after the table: same spans and height, right below it.
        final gridRect = tester.getRect(_wi208Grid(6, under: _wi208Rows));
        final afterRect = tester.getRect(_wi208RowText(7));
        expect(_wi208Visible(tester, _wi208RowTextKey(7)), after);
        expect(afterRect.height, closeTo(plainAfterHeight, 0.01));
        expect(
          afterRect.top - gridRect.bottom,
          closeTo(0, 0.01),
          reason: 'the next row starts right below the grid',
        );
        String spansOnly(String row) => row.split(' / ').skip(3).join(' / ');
        expect(
          spansOnly(describeRows(tester, [7]).single),
          spansOnly(plainAfter.single),
          reason: 'the row after the table renders its spans as before',
        );
      },
    );
  });
}
