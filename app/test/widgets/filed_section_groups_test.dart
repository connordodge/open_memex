// WI #397 (F1, Spec #393 requirements 1-7, 14, 19-23): the redesigned
// `Filed from this day` section, design A · Link groups. The header eyebrow
// with `· <n> BLOCKS` and the explainer; topic groups behind a hairline, each
// opened by a topic link row that looks like a wikilink and follows the topic
// note; block rows hanging off a 1 px tree rail with plain-text previews; the
// Not filed header row.
//
// Numbers come from the design pack (design/393-filed-groups/packs/397.md);
// the board wins over the WI for numbers, the Spec for copy (LR1).
//
// Most tests pump the section on its own, 340 px wide on a surface1 box, with
// a real `TabsNotifier` whose navigation goes through a `TabsRecorder` and
// whose new-tab modifier is the `isNewTabModifierPressed` seam. The rail,
// ticks, hairlines, hover background and focus ring are read from the
// rendered pixels, so the tests hold for any widget structure that draws
// them. Fonts are the flutter_test fallback (every glyph 1 em wide), so text
// widths are larger than in the app, and each line box is rounded to whole
// pixels (13 px x 1.4 lays out 18, not 18.2), so heights carry 0.25 px a line.
// Test names use no apostrophes or quotes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/editor/markdown_preview_text.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/activity/filed_section.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/filed_section_fakes.dart';
import '../support/font_fetch_hold.dart';
import '../support/recording_tabs.dart';
import '../support/review_fakes.dart' show openNoteTab;
import '../support/topics_access_doubles.dart';

const _wi397Boundary = Key('wi397-boundary');

Key _link(String topic) => Key('filed-topic-link-$topic');

const _explainer =
    'Where the agent filed this day’s blocks. Move or remove one and the '
    'agent learns from your fix on its next review.';

/// `· <n> BLOCKS` as the header shows it.
String _count(String n) => '· $n';

const _longPreview =
    'a very long preview that keeps going and going so that it cannot fit on '
    'two lines of the right panel however narrow the text is drawn, and then '
    'some more words to be sure about it, and more, and more again';
const _longTitle = 'A very long topic title that goes on and on and on forever';

/// One line in the 294 px preview column at 1x (12.5 px glyphs).
const _shortText = 'short note';

// ---------- pumping ----------

class _S397 {
  _S397(this.server, this.db);

  final F260Server server;
  final FakeVaultDb db;
  final TabsRecorder tabs = TabsRecorder();
  late final ProviderContainer container;

  /// What the `isNewTabModifierPressed` seam answers.
  bool newTab = false;

  TabsState get state => container.read(tabsProvider);

  /// Bumps the revision, so the section re-reads `filing`.
  Future<void> refresh(WidgetTester tester) async {
    container.read(vaultRevisionProvider.notifier).state++;
    await pumpFrames(tester);
  }
}

/// Pumps the section alone, [width] wide at text scale [scale], on a
/// surface1 box inside a [RepaintBoundary] keyed [_wi397Boundary].
Future<_S397> _pump397(
  WidgetTester tester, {
  F260Server Function(FakeVaultDb db)? server,
  double width = 340,
  double scale = 1.0,
}) async {
  final db = f260Db();
  final srv = (server ?? f260DefaultServer)(db);
  final cli = f260Cli(db, srv);
  final note = db.getNote(f260DailyId)!;
  final dir = Directory.systemTemp.createTempSync('wi397');
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final s = _S397(srv, db);
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
      selectedNoteIdProvider.overrideWith((_) => f260DailyId),
      tabsProvider.overrideWith(
        (ref) => TabsNotifier(
          store: UiStateStore(vaultPath: dir.path),
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => s.newTab,
          navigationObserver: s.tabs.observer,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  s.container = container;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: OmColors.surface1,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 1000,
              child: SingleChildScrollView(
                child: RepaintBoundary(
                  key: _wi397Boundary,
                  child: ColoredBox(
                    color: OmColors.surface1,
                    child: FiledSection(note: note),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  expect(find.byKey(f260Section), findsOneWidget);
  return s;
}

/// A day of [topics] and [notFiled] blocks.
F260Server Function(FakeVaultDb) _day(
  List<F260Topic> topics, [
  List<(String, String)> notFiled = const [],
]) =>
    (db) => F260Server(db, topics: topics, notFiled: [...notFiled]);

// ---------- reading ----------

Finder _inLink(String topic, Finder what) =>
    find.descendant(of: find.byKey(_link(topic)), matching: what);

Finder _inSection(Finder what) =>
    find.descendant(of: find.byKey(f260Section), matching: what);

RenderParagraph _para(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget);
  return tester.renderObject<RenderParagraph>(text);
}

TextStyle _style(WidgetTester tester, Finder text) =>
    _para(tester, text).text.style!;

/// Global y of [text]'s first alphabetic baseline.
double _baseline(WidgetTester tester, Finder text) {
  final box = _para(tester, text);
  final painter = TextPainter(
    text: box.text,
    textDirection: box.textDirection,
    textScaler: box.textScaler,
  )..layout(maxWidth: box.size.width + 1);
  final baseline = painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  painter.dispose();
  return box.localToGlobal(Offset.zero).dy + baseline;
}

/// The preview paragraph of the row [row]: its widest Text that is not a
/// button label.
Finder _preview(Key row, String text) =>
    find.descendant(of: find.byKey(row), matching: find.text(text));

void _expectFamily(TextStyle actual, TextStyle expected, String what) {
  expect(actual.fontFamily, expected.fontFamily, reason: '$what family');
}

// ---------- pixels ----------

class _Px397 {
  _Px397(this._bytes, this._width, this._height, this._origin);

  final ByteData _bytes;
  final int _width;
  final int _height;
  final Offset _origin;

  /// The pixel holding global point ([x], [y]).
  Color at(double x, double y) {
    final ix = (x - _origin.dx).floor().clamp(0, _width - 1);
    final iy = (y - _origin.dy).floor().clamp(0, _height - 1);
    final i = (iy * _width + ix) * 4;
    return Color.fromARGB(
      _bytes.getUint8(i + 3),
      _bytes.getUint8(i),
      _bytes.getUint8(i + 1),
      _bytes.getUint8(i + 2),
    );
  }

  /// Global bottom edge of the captured section.
  double get bottom => _origin.dy + _height;
}

Future<_Px397> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_wi397Boundary),
  );
  final origin = boundary.localToGlobal(Offset.zero);
  final image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: 1.0),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final px = _Px397(bytes, image.width, image.height, origin);
  image.dispose();
  return px;
}

int _c255(double v) => (v * 255.0).round() & 0xff;

/// Sum of the channel differences of [a] and [b].
int _dist(Color a, Color b) =>
    (_c255(a.r) - _c255(b.r)).abs() +
    (_c255(a.g) - _c255(b.g)).abs() +
    (_c255(a.b) - _c255(b.b)).abs();

Color _over(Color c) => Color.alphaBlend(c, OmColors.surface1);

final _line1 = _over(OmColors.line1);
final _line3 = _over(OmColors.line3);

/// How much of [full] (drawn over surface1) the pixel [px] holds, 0..1.
double _strength(Color px, Color full) =>
    _dist(px, OmColors.surface1) / _dist(full, OmColors.surface1);

/// The amount of [full] in the pixel column at [x] from [y0] to [y1]
/// (global), in pixels, and its centre.
({double sum, double centre}) _vscan(
  _Px397 px,
  double x,
  double y0,
  double y1,
  Color full,
) {
  var sum = 0.0;
  var moment = 0.0;
  for (var y = y0.floor(); y < y1.ceil(); y++) {
    final t = _strength(px.at(x, y + 0.5), full);
    sum += t;
    moment += t * (y + 0.5);
  }
  return (sum: sum, centre: sum == 0 ? double.nan : moment / sum);
}

/// The same along the pixel row at [y], from [x0] to [x1].
({double sum, double centre}) _hscan(
  _Px397 px,
  double y,
  double x0,
  double x1,
  Color full,
) {
  var sum = 0.0;
  var moment = 0.0;
  for (var x = x0.floor(); x < x1.ceil(); x++) {
    final t = _strength(px.at(x + 0.5, y), full);
    sum += t;
    moment += t * (x + 0.5);
  }
  return (sum: sum, centre: sum == 0 ? double.nan : moment / sum);
}

/// Expects the rail of the row at [r] to end at its tick: the rail column
/// (x 21) holds exactly the rail from the row's top to y 15, over the pixel
/// rows from [r].top + 10 to [r].top + 24 (counted whole pixels, so a
/// fractional row top does not shift it). A rail that stops a pixel short
/// (the tick's corner missing) or runs a pixel on changes the sum by 1.
void _expectRailStopsAtTick(_Px397 px, Rect r, String name) {
  final first = (r.top + 10).floor();
  final column = _vscan(px, 21.5, r.top + 10, r.top + 24, _line3);
  expect(
    column.sum,
    closeTo(r.top + 15 - first, 0.15),
    reason: 'the rail ends at its tick, y 15 of the row ($name)',
  );
}

/// The tick of the row at [r]: 8 px of line3 right of the rail (x 22 to 30),
/// summed over the pixel rows it blurs across.
void _expectTickLength(_Px397 px, Rect r, String name) {
  var length = 0.0;
  for (var y = (r.top + 11).floor(); y < (r.top + 18).ceil(); y++) {
    length += _hscan(px, y + 0.5, 22, 35, _line3).sum;
  }
  expect(
    length,
    closeTo(8, 0.3),
    reason: 'the tick runs from x 22 to x 30, after the rail ($name)',
  );
}

/// The largest difference from [bg] inside [area].
int _maxDiff(_Px397 px, Rect area, Color bg) {
  var most = 0;
  for (var y = area.top.floor(); y < area.bottom.ceil(); y++) {
    for (var x = area.left.floor(); x < area.right.ceil(); x++) {
      final d = _dist(px.at(x + 0.5, y + 0.5), bg);
      if (d > most) most = d;
    }
  }
  return most;
}

/// Where the hover arrow of [link] sits: 12 px wide, 12 px from the right.
Rect _arrowArea(Rect link) => Rect.fromLTRB(
  link.right - 28,
  link.center.dy - 7,
  link.right - 8,
  link.center.dy + 7,
);

// ---------- semantics ----------

List<SemanticsNode> _nodes397(WidgetTester tester) {
  final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
  final out = <SemanticsNode>[];
  void visit(SemanticsNode n) {
    out.add(n);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(owner.rootSemanticsNode!);
  return out;
}

SemanticsNode? _nodeLabelled(WidgetTester tester, String label) {
  final hits = [
    for (final n in _nodes397(tester))
      if (n.label == label) n,
  ];
  return hits.length == 1 ? hits.single : null;
}

bool _isLink(SemanticsNode n) => n.getSemanticsData().flagsCollection.isLink;

bool _hasTap(SemanticsNode n) =>
    n.getSemanticsData().hasAction(SemanticsAction.tap);

bool _isFocusable(SemanticsNode n) =>
    n.getSemanticsData().flagsCollection.isFocused != ui.Tristate.none;

// ---------- input ----------

Future<TestGesture> _mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  addTearDown(mouse.removePointer);
  await tester.pump();
  return mouse;
}

MouseCursor? get _cursor =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

Rect? get _focusedRect => FocusManager.instance.primaryFocus?.rect;

bool _focusInside(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget, reason: '$key');
  final r = _focusedRect;
  if (r == null) return false;
  return tester.getRect(find.byKey(key)).inflate(0.5).contains(r.center);
}

/// Tabs once from nothing focused: the first focus stop of the section.
Future<void> _tab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

/// Tabs until the topic link [key] holds the focus, however many other stops
/// (such as fix buttons) lie between two links: the test must not depend on
/// one Tab per link.
Future<void> _tabToLink(WidgetTester tester, Key key) async {
  for (var i = 0; i < 12; i++) {
    await _tab(tester);
    if (_focusInside(tester, key)) return;
  }
  fail('Tab never reached $key');
}

Future<void> _focusFirstLink(WidgetTester tester) async {
  await _tab(tester);
  expect(
    _focusInside(tester, _link(f260Loop)),
    isTrue,
    reason: 'the first Tab stops on the first topic link',
  );
}

// ---------- the app ----------

/// The whole app on the default day with a [TabsRecorder] on the real
/// `tabsProvider`, the daily note active and the Activity tab showing.
Future<(WorkspaceHarness, TabsRecorder)> _pumpApp397(
  WidgetTester tester,
) async {
  final db = f260Db();
  final srv = f260DefaultServer(db);
  final cli = f260Cli(db, srv);
  final tabs = TabsRecorder();
  final h = await pumpWorkspace(
    tester,
    db: db,
    cli: cli,
    overrides: [AccessDoubles().override, tabs.override],
  );
  await openNoteTab(tester, h, f260DailyId);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state =
      RightPanelTab.activity;
  await pumpFrames(tester);
  expect(find.byKey(f260Section), findsOneWidget);
  return (h, tabs);
}

void main() {
  holdFontFetches();

  group('header (AC1, AC2)', () {
    testWidgets(
      'the header shows the eyebrow and the uppercased block count on one baseline',
      (tester) async {
        // 600 px: the fallback font is too wide for both on one line at 340.
        await _pump397(tester, width: 600);

        final eyebrow = _inSection(find.text('FILED FROM THIS DAY'));
        final count = _inSection(find.text(_count('4 BLOCKS')));
        expect(eyebrow, findsOneWidget);
        expect(count, findsOneWidget);

        final e = _style(tester, eyebrow);
        final want = OmType.eyebrow();
        expect(e.fontSize, want.fontSize);
        expect(e.fontWeight, want.fontWeight);
        expect(e.letterSpacing, want.letterSpacing);
        expect(e.color, OmColors.fg2);
        _expectFamily(e, want, 'eyebrow');

        final c = _style(tester, count);
        expect(c.fontSize, 10.5);
        expect(c.letterSpacing, 0.8);
        expect(c.color, OmColors.fg2);
        _expectFamily(c, OmType.mono(size: 10.5), 'count');

        final er = tester.getRect(eyebrow);
        final cr = tester.getRect(count);
        expect(er.left, closeTo(16, 0.5), reason: '16 px side padding');
        expect(er.top, closeTo(14, 0.5), reason: '14 px top padding');
        expect(
          cr.left,
          closeTo(er.right + 8, 0.5),
          reason: 'the count follows the eyebrow 8 px after it',
        );
        expect(cr.top, lessThan(er.bottom), reason: 'on the same line');
        expect(
          _baseline(tester, count),
          closeTo(_baseline(tester, eyebrow), 0.3),
          reason: 'eyebrow and count share a baseline',
        );
      },
    );

    testWidgets(
      'the block count counts every row shown and a block in two topics twice',
      (tester) async {
        await _pump397(
          tester,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [
                (f260B1, f260B1Text),
                (f260B2, f260B2Text),
              ]),
              // b1 is filed in Economy too: it is shown, and counted, twice.
              F260Topic(f260Economy, 'Economy', [
                (f260B1, f260B1Text),
                (f260B3, f260B3Text),
              ]),
              // A topic with no blocks shows nothing and counts nothing.
              F260Topic(f260Sleep, 'Sleep'),
            ],
            [(f260N1, f260N1Text)],
          ),
        );

        expect(find.byKey(f260Row(f260Economy, f260B1)), findsOneWidget);
        expect(_inSection(find.text(_count('5 BLOCKS'))), findsOneWidget);
        expect(_inSection(find.textContaining('BLOCK')), findsOneWidget);
      },
    );

    testWidgets('the block count reads 1 BLOCK for a single filed row', (
      tester,
    ) async {
      final s = await _pump397(
        tester,
        server: _day([
          F260Topic(f260Economy, 'Economy', [(f260B3, f260B3Text)]),
        ]),
      );

      expect(_inSection(find.text(_count('1 BLOCK'))), findsOneWidget);
      expect(_inSection(find.textContaining('BLOCKS')), findsNothing);

      // A second row makes it plural.
      s.server.notFiled.add((f260N1, f260N1Text));
      await s.refresh(tester);
      expect(_inSection(find.text(_count('2 BLOCKS'))), findsOneWidget);
    });

    testWidgets('a day with one unfiled block only reads 1 BLOCK', (
      tester,
    ) async {
      await _pump397(tester, server: _day([], [(f260N1, f260N1Text)]));

      expect(_inSection(find.text(_count('1 BLOCK'))), findsOneWidget);
    });

    testWidgets(
      'the explainer under the header says what a fix does in 12 px fg2 sans',
      (tester) async {
        await _pump397(tester);

        final explainer = _inSection(find.text(_explainer));
        expect(explainer, findsOneWidget);
        final st = _style(tester, explainer);
        expect(st.fontSize, 12);
        expect(st.height, 1.5);
        expect(st.color, OmColors.fg2);
        _expectFamily(st, OmType.sans(size: 12), 'explainer');

        final r = tester.getRect(explainer);
        expect(r.left, closeTo(16, 0.5), reason: '16 px left padding');
        expect(
          r.right,
          closeTo(340 - 16, 0.5),
          reason: 'a wrapping explainer fills the width less 16 px',
        );
        final header = [
          tester.getRect(_inSection(find.text('FILED FROM THIS DAY'))),
          tester.getRect(_inSection(find.text(_count('4 BLOCKS')))),
        ];
        final headerBottom = header
            .map((e) => e.bottom)
            .reduce((a, b) => a > b ? a : b);
        expect(
          r.top,
          closeTo(headerBottom + 4, 0.5),
          reason: 'under the header, after its 4 px bottom padding',
        );
      },
    );
  });

  group('topic groups (AC3)', () {
    testWidgets(
      'each topic group opens with a line1 hairline and 4 px top and 8 px bottom padding',
      (tester) async {
        await _pump397(tester);
        final px = await _capture(tester);

        final explainer = tester.getRect(_inSection(find.text(_explainer)));
        final loop = tester.getRect(find.byKey(_link(f260Loop)));
        final economy = tester.getRect(find.byKey(_link(f260Economy)));
        final lastLoopRow = tester.getRect(
          find.byKey(f260Row(f260Loop, f260B2)),
        );

        for (final (name, link) in [
          ('Player Loop', loop),
          ('Economy', economy),
        ]) {
          final hair = _vscan(px, 170, link.top - 8, link.top, _line1);
          expect(
            hair.sum,
            closeTo(1, 0.3),
            reason: 'one 1 px line1 hairline above $name',
          );
          expect(
            hair.centre,
            closeTo(link.top - 4.5, 0.5),
            reason: '4 px top padding between the hairline and $name',
          );
        }
        // The first hairline follows the explainer's 10 px bottom padding.
        final first = _vscan(px, 170, explainer.bottom, loop.top, _line1);
        expect(first.sum, closeTo(1, 0.3));
        expect(first.centre, closeTo(explainer.bottom + 10.5, 0.5));
        // 8 px bottom padding after a group's last row.
        final between = _vscan(
          px,
          170,
          lastLoopRow.bottom,
          economy.top,
          _line1,
        );
        expect(between.sum, closeTo(1, 0.3), reason: 'one hairline only');
        expect(between.centre, closeTo(lastLoopRow.bottom + 8.5, 0.5));
      },
    );
  });

  group('topic link row (AC4, AC5, AC6, AC7)', () {
    testWidgets(
      'a topic link row lays out its icon title and digits only count with 7 12 7 16 padding',
      (tester) async {
        await _pump397(tester);

        final link = find.byKey(_link(f260Loop));
        expect(link, findsOneWidget);
        final row = tester.getRect(link);
        expect(row.left, closeTo(0, 0.5));
        expect(row.width, closeTo(340, 0.5), reason: 'the full panel width');
        expect(
          row.height,
          closeTo(32.2, 0.25),
          reason: '7 + 18.2 (13 px x 1.4) + 7',
        );

        final iconF = _inLink(f260Loop, find.byIcon(LucideIcons.fileText));
        expect(iconF, findsOneWidget);
        final icon = tester.widget<Icon>(iconF);
        expect(icon.size, 12);
        expect(icon.color, OmColors.fg2);
        final ir = tester.getRect(iconF);
        expect(ir.left, closeTo(16, 0.5), reason: '16 px left padding');
        expect(ir.center.dy, closeTo(row.center.dy, 0.5));

        final titleF = _inLink(f260Loop, find.text('Player Loop'));
        expect(titleF, findsOneWidget);
        final tr = tester.getRect(titleF);
        expect(tr.left, closeTo(ir.right + 8, 0.5), reason: '8 px gap');
        expect(tr.top, closeTo(row.top + 7, 0.5), reason: '7 px top padding');
        expect(tr.bottom, closeTo(row.bottom - 7, 0.5), reason: '7 px bottom');
        final title = _style(tester, titleF);
        expect(title.fontSize, 13);
        expect(title.fontWeight, FontWeight.w500);
        expect(title.color, OmColors.accent);
        _expectFamily(
          title,
          OmType.sans(size: 13, weight: FontWeight.w500),
          'title',
        );
        final tp = _para(tester, titleF);
        expect(tp.maxLines, 1);
        expect(tp.overflow, TextOverflow.ellipsis);

        final countF = _inLink(f260Loop, find.text('2'));
        expect(countF, findsOneWidget, reason: 'digits only');
        final cr = tester.getRect(countF);
        expect(
          cr.left,
          closeTo(tr.right + 8, 0.5),
          reason: 'the count sits 8 px after the title',
        );
        final count = _style(tester, countF);
        expect(count.fontSize, 10.5);
        expect(count.color, OmColors.fg2);
        _expectFamily(count, OmType.mono(size: 10.5), 'count');

        expect(
          _inLink(f260Economy, find.text('1')),
          findsOneWidget,
          reason: 'Economy holds one block',
        );
      },
    );

    testWidgets(
      'a long topic title stays on one line and ellipsizes before its count',
      (tester) async {
        await _pump397(
          tester,
          server: _day([
            F260Topic(f260Loop, _longTitle, [(f260B1, _shortText)]),
          ]),
        );

        final row = tester.getRect(find.byKey(_link(f260Loop)));
        final titleF = _inLink(f260Loop, find.text(_longTitle));
        final countF = _inLink(f260Loop, find.text('1'));
        expect(tester.takeException(), isNull);
        expect(_para(tester, titleF).didExceedMaxLines, isTrue);
        expect(row.height, closeTo(32.2, 0.25), reason: 'still one line');
        final tr = tester.getRect(titleF);
        final cr = tester.getRect(countF);
        expect(cr.left, closeTo(tr.right + 8, 0.5));
        expect(
          cr.right,
          lessThanOrEqualTo(row.right - 12 + 0.5),
          reason: 'the count keeps its place inside the 12 px right padding',
        );
      },
    );

    testWidgets(
      'hovering a topic link shows surface3 an underlined title the arrow and a click cursor and leaving restores the rest state',
      (tester) async {
        await _pump397(tester);
        final link = find.byKey(_link(f260Loop));
        final row = tester.getRect(link);
        final titleF = _inLink(f260Loop, find.text('Player Loop'));
        final bgAt = Offset(8, row.center.dy);

        // At rest: no background, no underline, no arrow.
        var px = await _capture(tester);
        expect(_dist(px.at(bgAt.dx, bgAt.dy), OmColors.surface1), lessThan(5));
        expect(
          _style(tester, titleF).decoration ?? TextDecoration.none,
          TextDecoration.none,
        );
        expect(
          _maxDiff(px, _arrowArea(row), OmColors.surface1),
          lessThan(8),
          reason: 'no arrow at rest',
        );

        final mouse = await _mouseAt(tester, const Offset(700, 900));
        await mouse.moveTo(row.center);
        await tester.pump();

        px = await _capture(tester);
        expect(
          _dist(px.at(bgAt.dx, bgAt.dy), OmColors.surface3),
          lessThan(5),
          reason: 'surface3 while hovered',
        );
        final hovered = _style(tester, titleF);
        expect(hovered.decoration, TextDecoration.underline);
        expect(
          hovered.decorationColor ?? hovered.color,
          OmColors.accent,
          reason: 'underlined in the title colour',
        );
        final arrowF = _inLink(f260Loop, find.byIcon(LucideIcons.arrowUpRight));
        expect(arrowF, findsOneWidget);
        final arrow = tester.widget<Icon>(arrowF);
        expect(arrow.size, 12);
        expect(arrow.color, OmColors.fg2);
        expect(
          tester.getRect(arrowF).right,
          closeTo(row.right - 12, 0.5),
          reason: 'right-aligned inside the 12 px right padding',
        );
        expect(
          _maxDiff(px, _arrowArea(row), OmColors.surface3),
          greaterThan(40),
          reason: 'the arrow is drawn',
        );
        expect(_cursor, SystemMouseCursors.click);

        // The other link stays at rest.
        final economy = tester.getRect(find.byKey(_link(f260Economy)));
        expect(
          _dist(px.at(8, economy.center.dy), OmColors.surface1),
          lessThan(5),
        );
        expect(
          _style(
                tester,
                _inLink(f260Economy, find.text('Economy')),
              ).decoration ??
              TextDecoration.none,
          TextDecoration.none,
        );

        await mouse.moveTo(const Offset(700, 900));
        await tester.pump();
        px = await _capture(tester);
        expect(_dist(px.at(bgAt.dx, bgAt.dy), OmColors.surface1), lessThan(5));
        expect(
          _style(tester, titleF).decoration ?? TextDecoration.none,
          TextDecoration.none,
        );
        expect(_maxDiff(px, _arrowArea(row), OmColors.surface1), lessThan(8));
        expect(_cursor, isNot(SystemMouseCursors.click));
      },
    );

    testWidgets(
      'Tab stops on each topic link and draws a 2 px accent ring inset by 2 px',
      (tester) async {
        await _pump397(tester);
        final loop = tester.getRect(find.byKey(_link(f260Loop)));
        final economy = tester.getRect(find.byKey(_link(f260Economy)));

        void expectRing(_Px397 px, Rect r, {required bool shown}) {
          final y = r.center.dy;
          for (final x in [2.5, 3.5, r.right - 3.5, r.right - 2.5]) {
            final d = _dist(px.at(x, y), OmColors.accent);
            if (shown) {
              expect(d, lessThan(12), reason: 'ring at x $x');
            } else {
              expect(d, greaterThan(200), reason: 'no ring at x $x');
            }
          }
          for (final x in [0.5, 1.5, 4.5, r.right - 4.5, r.right - 0.5]) {
            expect(
              _dist(px.at(x, y), OmColors.surface1),
              lessThan(5),
              reason: 'inset by 2 px and 2 px wide, x $x',
            );
          }
          if (shown) {
            final top = _vscan(px, 170, r.top - 1, r.top + 6, OmColors.accent);
            expect(top.sum, closeTo(2, 0.4), reason: '2 px top edge');
            expect(top.centre, closeTo(r.top + 3, 0.5));
          }
        }

        var px = await _capture(tester);
        expectRing(px, loop, shown: false);
        expectRing(px, economy, shown: false);

        await _focusFirstLink(tester);
        px = await _capture(tester);
        expectRing(px, loop, shown: true);
        expectRing(px, economy, shown: false);

        await _tabToLink(tester, _link(f260Economy));
        px = await _capture(tester);
        expectRing(px, loop, shown: false);
        expectRing(px, economy, shown: true);
      },
    );

    testWidgets(
      'a topic link is one link node labelled with its title and block count',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump397(tester);

        for (final label in ['Player Loop, 2 blocks', 'Economy, 1 block']) {
          final node = _nodeLabelled(tester, label);
          expect(node, isNotNull, reason: 'one node labelled $label');
          expect(_isLink(node!), isTrue, reason: '$label is a link');
          expect(
            node.childrenCount,
            0,
            reason: 'the title and count are not read again',
          );
        }
        final links = [
          for (final n in _nodes397(tester))
            if (_isLink(n)) n.label,
        ];
        expect(
          links,
          unorderedEquals(['Player Loop, 2 blocks', 'Economy, 1 block']),
          reason: 'only topic links are links: not Not filed, not the rows',
        );
        handle.dispose();
      },
    );

    testWidgets('a semantics tap on a topic link follows the topic note once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final s = await _pump397(tester);

      final node = _nodeLabelled(tester, 'Player Loop, 2 blocks');
      expect(node, isNotNull);
      expect(_hasTap(node!), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await pumpFrames(tester);

      expect(s.tabs.followed, [const NoteTab(f260Loop)]);
      handle.dispose();
    });
  });

  group('following a topic link (AC8, AC9)', () {
    testWidgets('clicking a topic link follows the topic note once in place', (
      tester,
    ) async {
      final s = await _pump397(tester);

      await tester.tap(find.byKey(_link(f260Loop)));
      await pumpFrames(tester);

      expect(s.tabs.followed, [const NoteTab(f260Loop)]);
      expect(s.tabs.navigated, [const NoteTab(f260Loop)], reason: 'in place');
      expect(s.state.activeTab, const NoteTab(f260Loop));

      await tester.tap(find.byKey(_link(f260Economy)));
      await pumpFrames(tester);
      expect(s.tabs.followed, [
        const NoteTab(f260Loop),
        const NoteTab(f260Economy),
      ]);
    });

    testWidgets(
      'clicking a topic link with the new tab modifier held opens or focuses a tab',
      (tester) async {
        final s = await _pump397(tester);
        s.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab(f260DailyId));
        await pumpFrames(tester);
        s.newTab = true;

        await tester.tap(find.byKey(_link(f260Loop)));
        await pumpFrames(tester);

        expect(s.tabs.followed, [const NoteTab(f260Loop)]);
        expect(s.tabs.navigated, isEmpty, reason: 'not in place');
        expect(s.state.tabs, [
          const NoteTab(f260DailyId),
          const NoteTab(f260Loop),
        ]);
        expect(s.state.activeTab, const NoteTab(f260Loop));

        // Again: the open tab is focused, not opened twice.
        s.container
            .read(tabsProvider.notifier)
            .openOrFocus(const NoteTab(f260DailyId));
        await tester.tap(find.byKey(_link(f260Loop)));
        await pumpFrames(tester);
        expect(s.state.tabs, hasLength(2));
        expect(s.state.activeTab, const NoteTab(f260Loop));
      },
    );

    testWidgets(
      'in the app a topic link click opens the topic note in the active tab and a Cmd click opens a new tab',
      (tester) async {
        final (h, tabs) = await _pumpApp397(tester);
        final before = h.container.read(tabsProvider).tabs.length;

        await tester.tap(find.byKey(_link(f260Loop)));
        await pumpFrames(tester);
        var state = h.container.read(tabsProvider);
        expect(tabs.followed, [const NoteTab(f260Loop)]);
        expect(state.activeTab, const NoteTab(f260Loop));
        expect(state.tabs, hasLength(before), reason: 'in place');
        expect(state.canGoBack, isTrue);

        // Back to the day, then Cmd-click Economy.
        h.container.read(tabsProvider.notifier).back();
        await pumpFrames(tester);
        expect(
          h.container.read(tabsProvider).activeTab,
          const NoteTab(f260DailyId),
        );
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        try {
          await tester.tap(find.byKey(_link(f260Economy)));
          await pumpFrames(tester);
        } finally {
          await tester.sendKeyUpEvent(
            LogicalKeyboardKey.metaLeft,
            platform: 'macos',
          );
          await tester.pump();
        }
        state = h.container.read(tabsProvider);
        expect(tabs.followed.last, const NoteTab(f260Economy));
        expect(state.activeTab, const NoteTab(f260Economy));
        expect(state.tabs, hasLength(before + 1));
        expect(state.tabs, contains(const NoteTab(f260DailyId)));
      },
    );

    testWidgets(
      'Enter on a focused topic link follows once in place and a held Enter does not repeat',
      (tester) async {
        final s = await _pump397(tester);
        await _focusFirstLink(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(s.tabs.followed, [const NoteTab(f260Loop)]);
        expect(s.tabs.navigated, [const NoteTab(f260Loop)], reason: 'in place');
        expect(s.state.activeTab, const NoteTab(f260Loop));
      },
    );

    testWidgets(
      'Space on a focused topic link follows once and a held Space does not repeat',
      (tester) async {
        final s = await _pump397(tester);
        await _focusFirstLink(tester);
        await _tabToLink(tester, _link(f260Economy));

        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        await pumpFrames(tester);

        expect(s.tabs.followed, [const NoteTab(f260Economy)]);
        expect(s.tabs.navigated, [const NoteTab(f260Economy)]);
      },
    );

    testWidgets('Cmd Enter on a focused topic link does nothing', (
      tester,
    ) async {
      final s = await _pump397(tester);
      await _focusFirstLink(tester);

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter, platform: 'macos');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await pumpFrames(tester);

      expect(s.tabs.followed, isEmpty);
      expect(s.tabs.navigated, isEmpty);

      // Enter alone still works afterwards: the link kept its focus.
      expect(_focusInside(tester, _link(f260Loop)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester);
      expect(s.tabs.followed, [const NoteTab(f260Loop)]);
    });
  });

  group('block rows (AC10, AC11)', () {
    testWidgets(
      'block rows have 3 10 3 36 padding and a 30 px minimum height',
      (tester) async {
        await _pump397(
          tester,
          server: _day([
            F260Topic(f260Loop, 'Player Loop', [
              (f260B1, _longPreview),
              (f260B2, _shortText),
            ]),
          ]),
        );

        for (final (block, text) in [
          (f260B1, _longPreview),
          (f260B2, _shortText),
        ]) {
          final rowKey = f260Row(f260Loop, block);
          final row = tester.getRect(find.byKey(rowKey));
          final preview = tester.getRect(_preview(rowKey, text));
          expect(row.left, closeTo(0, 0.5), reason: '$block row from x 0');
          expect(row.width, closeTo(340, 0.5), reason: '$block full width');
          expect(row.height, greaterThanOrEqualTo(30), reason: '$block min');
          expect(
            preview.left,
            closeTo(row.left + 36, 0.5),
            reason: '36 px left padding ($block)',
          );
          // TEST-CHANGE (WI #398, Spec #393 F2 layout): the fix buttons
          // are a hidden 56 px column (50 px of buttons and a 6 px gap) at the
          // right of the row, not a Wrap under the preview, and the preview
          // is inset 3 px more so the buttons centre on its first line.
          expect(
            preview.top - row.top,
            closeTo(3 + 3, 0.3),
            reason: '3 px row padding and 3 px preview inset on top ($block)',
          );
          expect(
            preview.right,
            lessThanOrEqualTo(row.right - 10 - 56 + 0.3),
            reason: '10 px right padding and the button column ($block)',
          );
        }
        // The wrapping preview fills the row less its 10 px right padding and
        // the 56 px button column, exactly.
        final long = tester.getRect(
          _preview(f260Row(f260Loop, f260B1), _longPreview),
        );
        final row = tester.getRect(find.byKey(f260Row(f260Loop, f260B1)));
        expect(long.right, closeTo(row.right - 10 - 56, 0.3));
        expect(
          row.bottom - long.bottom,
          closeTo(3 + 3, 0.3),
          reason: '3 px row padding and 3 px preview inset on the bottom',
        );
        // A one-line row is 31 px: its 25 px button column and 3 px padding.
        final short = tester.getRect(find.byKey(f260Row(f260Loop, f260B2)));
        expect(short.height, closeTo(31, 0.3));
      },
    );

    testWidgets(
      'a 1 px line3 rail at x 21 ticks into each row at y 14 and stops at the last row tick',
      (tester) async {
        await _pump397(tester);
        final px = await _capture(tester);

        Rect row(Key k) => tester.getRect(find.byKey(k));
        final rows = {
          'b1 (first of two)': (row(f260Row(f260Loop, f260B1)), false),
          'b2 (last of Player Loop)': (row(f260Row(f260Loop, f260B2)), true),
          'b3 (only row of Economy)': (row(f260Row(f260Economy, f260B3)), true),
          'n1 (only Not filed row)': (row(f260NotFiledRow(f260N1)), true),
        };
        for (final MapEntry(key: name, value: (r, last)) in rows.entries) {
          expect(r.height, greaterThan(22), reason: name);
          // The rail runs from the row's top at x 21, 1 px wide.
          final top = _hscan(px, r.top + 3.5, 16, 27, _line3);
          expect(top.sum, closeTo(1, 0.3), reason: 'rail near the top, $name');
          expect(top.centre, closeTo(21.5, 0.3), reason: 'rail at x 21, $name');
          // The tick: 9 x 1 px at y 14, from x 21.
          final tick = _vscan(px, 26.5, r.top + 10, r.top + 19, _line3);
          expect(tick.sum, closeTo(1, 0.3), reason: 'one tick, $name');
          expect(
            tick.centre,
            closeTo(r.top + 14.5, 0.5),
            reason: 'tick at y 14, $name',
          );
          _expectTickLength(px, r, name);
          // Below the tick the rail goes on, except on a group's last row.
          final below = _hscan(px, r.top + 20.5, 16, 27, _line3);
          if (last) {
            expect(
              below.sum,
              lessThan(0.2),
              reason: 'stops at the tick, $name',
            );
            _expectRailStopsAtTick(px, r, name);
          } else {
            expect(below.sum, closeTo(1, 0.3), reason: 'runs on, $name');
            final bottom = _hscan(px, r.bottom - 1.5, 16, 27, _line3);
            expect(bottom.sum, closeTo(1, 0.3), reason: 'to the bottom, $name');
          }
        }
        // The rail starts at the first row: none beside the topic link row
        // (read above its 12 px icon).
        final link = tester.getRect(find.byKey(_link(f260Loop)));
        expect(_hscan(px, link.top + 3.5, 16, 27, _line3).sum, lessThan(0.2));
      },
    );

    testWidgets(
      'a block row previews the plain text of its markdown without quotes and with the full text in a tooltip',
      (tester) async {
        const md = '- **coyote** time for [ledge](https://example.com) jumps';
        const plain = 'coyote time for ledge jumps';
        expect(markdownPreviewText(md), plain, reason: 'the U1 reduction');
        await _pump397(
          tester,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [(f260B1, md)]),
            ],
            [(f260N1, '> call the **dentist**')],
          ),
        );

        for (final (rowKey, text) in [
          (f260Row(f260Loop, f260B1), plain),
          (
            f260NotFiledRow(f260N1),
            markdownPreviewText('> call the **dentist**'),
          ),
        ]) {
          final row = find.byKey(rowKey);
          expect(_preview(rowKey, text), findsOneWidget, reason: '$rowKey');
          expect(
            find.descendant(of: row, matching: find.textContaining('"')),
            findsNothing,
            reason: 'no quotes around the preview ($rowKey)',
          );
          expect(
            find.descendant(of: row, matching: find.textContaining('**')),
            findsNothing,
            reason: 'no markdown in the preview ($rowKey)',
          );
          final tips = tester
              .widgetList<Tooltip>(
                find.descendant(of: row, matching: find.byType(Tooltip)),
              )
              .map((t) => t.message)
              .toList();
          expect(tips, contains(text), reason: 'full plain text ($rowKey)');
          expect(
            tips.where((m) => (m ?? '').contains('"')),
            isEmpty,
            reason: 'no quoted tooltip ($rowKey)',
          );
        }
      },
    );

    testWidgets(
      'a long preview clamps at two lines with an ellipsis in sans 12.5 fg1',
      (tester) async {
        await _pump397(
          tester,
          server: _day([
            F260Topic(f260Loop, 'Player Loop', [
              (f260B1, _longPreview),
              (f260B2, _shortText),
            ]),
          ]),
        );

        final longF = _preview(f260Row(f260Loop, f260B1), _longPreview);
        final shortF = _preview(f260Row(f260Loop, f260B2), _shortText);
        final p = _para(tester, longF);
        expect(p.maxLines, 2);
        expect(p.overflow, TextOverflow.ellipsis);
        expect(p.didExceedMaxLines, isTrue);
        final st = _style(tester, longF);
        expect(st.fontSize, 12.5);
        expect(st.height, 1.45);
        expect(st.color, OmColors.fg1);
        _expectFamily(st, OmType.sans(size: 12.5), 'preview');
        expect(
          tester.getSize(longF).height,
          closeTo(2 * 12.5 * 1.45, 0.5),
          reason: 'two lines',
        );
        expect(
          tester.getSize(shortF).height,
          closeTo(12.5 * 1.45, 0.25),
          reason: 'one line',
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == _longPreview,
          ),
          findsOneWidget,
          reason: 'the full text in the tooltip',
        );
      },
    );
  });

  group('Not filed (AC12)', () {
    testWidgets(
      'the Not filed group comes last under an inbox header row and is absent when empty',
      (tester) async {
        final s = await _pump397(tester);

        final title = _inSection(find.text('Not filed'));
        expect(title, findsOneWidget);
        final inbox = _inSection(find.byIcon(LucideIcons.inbox));
        expect(inbox, findsOneWidget);
        final top = tester.getRect(title).top;
        for (final k in [
          _link(f260Loop),
          f260Row(f260Loop, f260B2),
          _link(f260Economy),
          f260Row(f260Economy, f260B3),
        ]) {
          expect(tester.getRect(find.byKey(k)).bottom, lessThanOrEqualTo(top));
        }
        expect(
          tester.getRect(find.byKey(f260NotFiledRow(f260N1))).top,
          greaterThanOrEqualTo(tester.getRect(title).bottom),
        );

        s.server.notFiled.clear();
        await s.refresh(tester);
        expect(find.byKey(f260Section), findsOneWidget);
        expect(_inSection(find.text('Not filed')), findsNothing);
        expect(_inSection(find.byIcon(LucideIcons.inbox)), findsNothing);
      },
    );

    testWidgets(
      'the Not filed header row has the topic link row geometry with fg1 title and its count',
      (tester) async {
        await _pump397(
          tester,
          server: _day(
            [
              F260Topic(f260Economy, 'Economy', [(f260B3, f260B3Text)]),
            ],
            [(f260N1, f260N1Text), ('n2', 'buy milk')],
          ),
        );
        final px = await _capture(tester);

        final titleF = _inSection(find.text('Not filed'));
        final tr = tester.getRect(titleF);
        final st = _style(tester, titleF);
        expect(st.fontSize, 13);
        expect(st.fontWeight, FontWeight.w500);
        expect(st.color, OmColors.fg1);
        _expectFamily(
          st,
          OmType.sans(size: 13, weight: FontWeight.w500),
          'Not filed',
        );
        expect(tr.height, closeTo(18.2, 0.25), reason: '13 px x 1.4');

        final iconF = _inSection(find.byIcon(LucideIcons.inbox));
        final icon = tester.widget<Icon>(iconF);
        expect(icon.size, 12);
        expect(icon.color, OmColors.fg2);
        final ir = tester.getRect(iconF);
        expect(ir.left, closeTo(16, 0.5));
        expect(ir.center.dy, closeTo(tr.center.dy, 0.5));
        expect(tr.left, closeTo(ir.right + 8, 0.5));

        // Its count: digits only, 8 px after the title, mono 10.5 fg2.
        final countF = find.byWidgetPredicate(
          (w) => w is Text && w.data == '2',
        );
        final counts = _inSection(countF);
        expect(counts, findsOneWidget);
        final cr = tester.getRect(counts);
        expect(cr.left, closeTo(tr.right + 8, 0.5));
        expect(cr.center.dy, closeTo(tr.center.dy, 1));
        final cs = _style(tester, counts);
        expect(cs.fontSize, 10.5);
        expect(cs.color, OmColors.fg2);
        _expectFamily(cs, OmType.mono(size: 10.5), 'Not filed count');

        // 32.2 px tall like a topic link row: hairline, 4, 7, title, 7, row.
        final economyLast = tester.getRect(
          find.byKey(f260Row(f260Economy, f260B3)),
        );
        final hair = _vscan(px, 170, economyLast.bottom, tr.top, _line1);
        expect(hair.sum, closeTo(1, 0.3), reason: 'its group hairline');
        expect(
          tr.top,
          closeTo(hair.centre + 0.5 + 4 + 7, 0.5),
          reason: '4 px group padding and 7 px row padding above the title',
        );
        expect(
          tester.getRect(find.byKey(f260NotFiledRow(f260N1))).top,
          closeTo(tr.bottom + 7, 0.5),
          reason: '7 px row padding under the title',
        );
      },
    );

    testWidgets(
      'the Not filed header has no hover background no arrow no click cursor and no link semantics',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pump397(tester);
        final tr = tester.getRect(_inSection(find.text('Not filed')));
        final header = Rect.fromLTRB(0, tr.top - 7, 340, tr.bottom + 7);

        final mouse = await _mouseAt(tester, const Offset(700, 900));
        await mouse.moveTo(Offset(170, header.center.dy));
        await tester.pump();
        final px = await _capture(tester);
        expect(
          _dist(px.at(8, header.center.dy), OmColors.surface1),
          lessThan(5),
          reason: 'no hover background',
        );
        expect(
          _maxDiff(px, _arrowArea(header), OmColors.surface1),
          lessThan(8),
          reason: 'no arrow',
        );
        expect(_inSection(find.byIcon(LucideIcons.arrowUpRight)), findsNothing);
        expect(_cursor, isNot(SystemMouseCursors.click));
        expect(
          _style(tester, _inSection(find.text('Not filed'))).decoration ??
              TextDecoration.none,
          TextDecoration.none,
        );

        await mouse.moveTo(const Offset(700, 900));
        await tester.pump();
        await tester.tapAt(Offset(170, header.center.dy));
        await pumpFrames(tester);
        expect(s.tabs.followed, isEmpty, reason: 'a header, not a link');

        final notFiled = [
          for (final n in _nodes397(tester))
            if (n.label.contains('Not filed')) n,
        ];
        expect(notFiled, isNotEmpty);
        for (final n in notFiled) {
          expect(_isLink(n), isFalse, reason: n.label);
          expect(_hasTap(n), isFalse, reason: n.label);
          expect(_isFocusable(n), isFalse, reason: n.label);
        }
        // The Not filed header is drawn though: the inbox icon is there.
        expect(_inSection(find.byIcon(LucideIcons.inbox)), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets('Tab never stops on the Not filed header', (tester) async {
      await _pump397(tester);
      final header = tester
          .getRect(_inSection(find.text('Not filed')))
          .inflate(7);

      // TEST-CHANGE (WI #398, Spec #393 requirement 9): the fix buttons are
      // focus stops too; Tab still stops only on topic links and rows.
      final rows = [
        for (final k in [
          f260Row(f260Loop, f260B1),
          f260Row(f260Loop, f260B2),
          f260Row(f260Economy, f260B3),
          f260NotFiledRow(f260N1),
        ])
          tester.getRect(find.byKey(k)),
      ];
      final seen = <String>{};
      for (var i = 0; i < 16; i++) {
        await _tab(tester);
        final r = _focusedRect;
        expect(r, isNotNull);
        expect(
          header.contains(r!.center),
          isFalse,
          reason: 'Tab $i is not on the Not filed header',
        );
        // Other stops (the fix buttons of F2) may lie between the links.
        if (_focusInside(tester, _link(f260Loop))) {
          seen.add('loop');
        } else if (_focusInside(tester, _link(f260Economy))) {
          seen.add('economy');
        } else if (!rows.any((row) => row.contains(r.center))) {
          fail('Tab $i stopped outside the topic links and rows: $r');
        }
      }
      expect(seen, {'loop', 'economy'});
    });
  });

  group('closing hairline (AC13)', () {
    testWidgets('the section closes with one hairline after the last group', (
      tester,
    ) async {
      await _pump397(tester);
      final px = await _capture(tester);

      final last = tester.getRect(find.byKey(f260NotFiledRow(f260N1)));
      final closing = _vscan(px, 170, last.bottom, px.bottom, _line1);
      expect(closing.sum, closeTo(1, 0.3), reason: 'one hairline, not two');
      expect(
        closing.centre,
        closeTo(last.bottom + 8.5, 0.5),
        reason: 'after the group 8 px bottom padding',
      );
      expect(
        px.bottom,
        closeTo(last.bottom + 9, 0.5),
        reason: 'the hairline ends the section',
      );
    });
  });

  group('scale and width (AC15)', () {
    testWidgets(
      'at 1.5x in the 340 px panel titles ellipsize previews keep two lines and the count wraps under the eyebrow',
      (tester) async {
        await _pump397(
          tester,
          scale: 1.5,
          server: _day(
            [
              F260Topic(f260Loop, _longTitle, [
                (f260B1, _longPreview),
                (f260B2, _shortText),
              ]),
            ],
            [(f260N1, _longPreview)],
          ),
        );
        expect(tester.takeException(), isNull, reason: 'no overflow');

        final eyebrow = tester.getRect(
          _inSection(find.text('FILED FROM THIS DAY')),
        );
        final count = tester.getRect(_inSection(find.text(_count('3 BLOCKS'))));
        expect(count.left, closeTo(16, 0.5), reason: 'wrapped to the left');
        expect(count.top, greaterThanOrEqualTo(eyebrow.bottom - 0.5));
        expect(count.right, lessThanOrEqualTo(340));

        final titleF = _inLink(f260Loop, find.text(_longTitle));
        expect(_para(tester, titleF).didExceedMaxLines, isTrue);
        expect(
          tester.getRect(find.byKey(_link(f260Loop))).height,
          closeTo(7 + 13 * 1.5 * 1.4 + 7, 0.35),
          reason: 'one title line at 1.5x',
        );
        for (final rowKey in [
          f260Row(f260Loop, f260B1),
          f260NotFiledRow(f260N1),
        ]) {
          final p = _para(tester, _preview(rowKey, _longPreview));
          expect(p.maxLines, 2, reason: '$rowKey');
          expect(p.didExceedMaxLines, isTrue, reason: '$rowKey');
          expect(
            tester.getSize(_preview(rowKey, _longPreview)).height,
            closeTo(2 * 12.5 * 1.5 * 1.45, 0.6),
          );
        }
        for (final k in [
          _link(f260Loop),
          f260Row(f260Loop, f260B1),
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260NotFiledRow(f260N1),
          f260FileIn(f260N1),
        ]) {
          final r = tester.getRect(find.byKey(k));
          expect(r.left, greaterThanOrEqualTo(0), reason: '$k');
          expect(r.right, lessThanOrEqualTo(340), reason: '$k');
        }
      },
    );

    testWidgets('at 280 px previews wrap without overflow', (tester) async {
      // 20 glyphs (250 px): one line in the 294 px column at 340, two in the
      // 234 px one at 280 (or the 178 px one beside a button column).
      const medium = 'twenty glyphs, okay.';
      await _pump397(
        tester,
        width: 280,
        server: _day(
          [
            F260Topic(f260Loop, 'Player Loop', [(f260B1, medium)]),
          ],
          [(f260N1, _longPreview)],
        ),
      );
      expect(tester.takeException(), isNull, reason: 'no overflow at 280');

      final rowKey = f260Row(f260Loop, f260B1);
      final p = _preview(rowKey, medium);
      expect(_para(tester, p).didExceedMaxLines, isFalse);
      expect(
        tester.getSize(p).height,
        closeTo(2 * 12.5 * 1.45, 0.5),
        reason: 'wrapped to two lines',
      );
      expect(tester.getRect(p).left, closeTo(36, 0.5));
      // TEST-CHANGE (WI #398): the 56 px fix button column takes the width.
      expect(tester.getRect(p).right, closeTo(280 - 10 - 56, 0.3));
      final row = tester.getRect(find.byKey(rowKey));
      expect(tester.getRect(p).top - row.top, closeTo(3 + 3, 0.3));
      for (final k in [rowKey, f260NotFiledRow(f260N1), _link(f260Loop)]) {
        expect(tester.getRect(find.byKey(k)).right, lessThanOrEqualTo(280));
      }
    });
  });

  group('keys (AC16)', () {
    testWidgets(
      'every WI 260 key stays and each topic link row carries filed-topic-link',
      (tester) async {
        await _pump397(tester);

        for (final k in [
          f260Section,
          _link(f260Loop),
          _link(f260Economy),
          f260Row(f260Loop, f260B1),
          f260Row(f260Loop, f260B2),
          f260Row(f260Economy, f260B3),
          f260NotFiledRow(f260N1),
        ]) {
          expect(find.byKey(k), findsOneWidget, reason: '$k');
        }
        for (final k in [
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260Move(f260Economy, f260B3),
          f260Remove(f260Economy, f260B3),
          f260FileIn(f260N1),
        ]) {
          expect(
            find.byWidgetPredicate((w) => w is OmButton && w.key == k),
            findsOneWidget,
            reason: '$k is on an OmButton',
          );
        }
        expect(
          tester.getRect(find.byKey(_link(f260Loop))).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(f260Row(f260Loop, f260B1))).top + 0.5,
          ),
          reason: 'the topic link row heads its group',
        );

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        for (final k in [
          f260TopicField,
          f260WhyField,
          f260Confirm,
          f260Cancel,
        ]) {
          expect(find.byKey(k), findsOneWidget, reason: '$k');
        }
        await f260Tap(tester, f260Cancel);
        expect(find.byKey(f260Confirm), findsNothing);
      },
    );
  });

  // Verify-mode pins: contracts the implementer's handoff listed as unread.
  group('pinned contracts (AC5, AC6, AC7, AC9, AC10)', () {
    /// Collects the key events that bubble past the focused link to the root
    /// focus scope: a link that handles an event does not pass it on.
    List<KeyEvent> bubbled() {
      final seen = <KeyEvent>[];
      final root = FocusManager.instance.rootScope;
      final before = root.onKeyEvent;
      root.onKeyEvent = (node, event) {
        seen.add(event);
        return KeyEventResult.ignored;
      };
      addTearDown(() => root.onKeyEvent = before);
      return seen;
    }

    testWidgets('numpad Enter on a focused topic link follows once in place', (
      tester,
    ) async {
      final s = await _pump397(tester);
      await _focusFirstLink(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.numpadEnter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.numpadEnter);
      await pumpFrames(tester);

      expect(s.tabs.followed, [const NoteTab(f260Loop)]);
      expect(s.tabs.navigated, [const NoteTab(f260Loop)], reason: 'in place');
    });

    testWidgets(
      'the topic link keeps Enter and Space presses and repeats to itself but lets Cmd Enter and key ups bubble',
      (tester) async {
        final s = await _pump397(tester);
        await _focusFirstLink(tester);
        final seen = bubbled();

        // A press and its repeats are the link's: nothing reaches the parent.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
        expect(seen.whereType<KeyDownEvent>(), isEmpty, reason: 'down handled');
        expect(seen.whereType<KeyRepeatEvent>(), isEmpty, reason: 'repeat');

        // Releases are not handled: they bubble.
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
        expect(seen.whereType<KeyUpEvent>().map((e) => e.logicalKey), [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
        ]);

        // Other keys bubble.
        seen.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        expect(seen.whereType<KeyDownEvent>(), hasLength(1));

        // Cmd+Enter is unbound: the Enter bubbles past the link.
        seen.clear();
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.enter,
          platform: 'macos',
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.enter,
          platform: 'macos',
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.metaLeft,
          platform: 'macos',
        );
        expect(
          seen.whereType<KeyDownEvent>().map((e) => e.logicalKey),
          contains(LogicalKeyboardKey.enter),
          reason: 'Cmd+Enter is not handled by the link',
        );
        expect(s.tabs.followed, [
          const NoteTab(f260Loop),
          const NoteTab(f260Loop),
        ], reason: 'only the Enter and the Space followed');
      },
    );

    testWidgets('a topic link node is focusable and reports its focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump397(tester);

      ui.Tristate focused(String label) => _nodeLabelled(
        tester,
        label,
      )!.getSemanticsData().flagsCollection.isFocused;

      expect(focused('Player Loop, 2 blocks'), ui.Tristate.isFalse);
      expect(focused('Economy, 1 block'), ui.Tristate.isFalse);
      await _focusFirstLink(tester);
      expect(focused('Player Loop, 2 blocks'), ui.Tristate.isTrue);
      expect(focused('Economy, 1 block'), ui.Tristate.isFalse);
      await _tabToLink(tester, _link(f260Economy));
      expect(focused('Player Loop, 2 blocks'), ui.Tristate.isFalse);
      expect(focused('Economy, 1 block'), ui.Tristate.isTrue);
      handle.dispose();
    });

    testWidgets(
      'a failed File in shows its error under the Not filed row and it can be dismissed',
      (tester) async {
        final s = await _pump397(tester);
        s.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
        await f260Tap(tester, f260FileIn(f260N1));
        await f260Tap(tester, f260Option(f260Economy));
        await f260Tap(tester, f260Confirm);

        // TEST-CHANGE (WI #398, Spec #393 requirement 13): the error sits
        // directly under its row, outside the row's own box.
        final row = find.byKey(f260NotFiledRow(f260N1));
        final error = find.descendant(
          of: find.byKey(f260Section),
          matching: f260Error,
        );
        expect(error, findsOneWidget, reason: 'the error sits under the row');
        expect(
          tester.getRect(error).top,
          closeTo(tester.getRect(row).bottom + 2, 0.5),
          reason: 'directly under the Not filed row',
        );

        await f260Tap(tester, const Key('inline-error-dismiss'));

        expect(error, findsNothing);
        expect(row, findsOneWidget, reason: 'the row stays');
      },
    );

    testWidgets('hovering never narrows the title: the arrow keeps its space', (
      tester,
    ) async {
      await _pump397(
        tester,
        server: _day([
          F260Topic(f260Loop, _longTitle, [(f260B1, _shortText)]),
        ]),
      );
      final titleF = _inLink(f260Loop, find.text(_longTitle));
      final countF = _inLink(f260Loop, find.text('1'));
      final title = tester.getRect(titleF);
      final count = tester.getRect(countF);
      expect(
        tester.getRect(find.byKey(_link(f260Loop))).right - 12 - count.right,
        closeTo(8 + 12, 0.5),
        reason:
            'at rest the count sits 8 px + a 12 px arrow slot from the edge',
      );

      final mouse = await _mouseAt(tester, const Offset(700, 900));
      await mouse.moveTo(tester.getCenter(find.byKey(_link(f260Loop))));
      await tester.pump();

      expect(tester.getRect(titleF), title, reason: 'the title keeps its box');
      expect(tester.getRect(countF), count, reason: 'the count does not move');
    });

    testWidgets('the rail and ticks keep their pixels at 1.5x text scale', (
      tester,
    ) async {
      await _pump397(tester, scale: 1.5);
      final px = await _capture(tester);
      final b1 = tester.getRect(find.byKey(f260Row(f260Loop, f260B1)));
      final b2 = tester.getRect(find.byKey(f260Row(f260Loop, f260B2)));
      expect(b1.height, greaterThan(30));

      for (final (name, r, last) in [('b1', b1, false), ('b2', b2, true)]) {
        final rail = _hscan(px, r.top + 3.5, 16, 27, _line3);
        expect(rail.sum, closeTo(1, 0.3), reason: 'rail, $name');
        expect(rail.centre, closeTo(21.5, 0.3), reason: 'x 21, $name');
        final tick = _vscan(px, 26.5, r.top + 10, r.top + 19, _line3);
        expect(tick.sum, closeTo(1, 0.3), reason: 'tick, $name');
        expect(tick.centre, closeTo(r.top + 14.5, 0.5), reason: 'y 14, $name');
        _expectTickLength(px, r, name);
        final below = _hscan(px, r.top + 20.5, 16, 27, _line3);
        if (last) {
          expect(below.sum, lessThan(0.2), reason: 'stops, $name');
          _expectRailStopsAtTick(px, r, name);
        } else {
          expect(below.sum, closeTo(1, 0.3), reason: 'runs on, $name');
          final bottom = _hscan(px, r.bottom - 1.5, 16, 27, _line3);
          expect(bottom.sum, closeTo(1, 0.3), reason: 'to the bottom, $name');
        }
      }
    });

    testWidgets(
      'removing the last block of a group moves the rail stop to the new last row',
      (tester) async {
        final s = await _pump397(tester);
        final b1 = f260Row(f260Loop, f260B1);
        var r = tester.getRect(find.byKey(b1));
        var px = await _capture(tester);
        expect(
          _hscan(px, r.top + 20.5, 16, 27, _line3).sum,
          closeTo(1, 0.3),
          reason: 'b1 is not last: the rail runs on',
        );

        s.server.topics.first.blocks.removeAt(1);
        await s.refresh(tester);

        expect(find.byKey(f260Row(f260Loop, f260B2)), findsNothing);
        r = tester.getRect(find.byKey(b1));
        px = await _capture(tester);
        expect(
          _hscan(px, r.top + 20.5, 16, 27, _line3).sum,
          lessThan(0.2),
          reason: 'b1 is now the last row: its rail stops at the tick',
        );
        _expectRailStopsAtTick(px, r, 'b1 as the last row');
        expect(_hscan(px, r.top + 3.5, 16, 27, _line3).sum, closeTo(1, 0.3));
      },
    );
  });
}
