// WI #398 (F2, Spec #393 requirements 8-13, 21-22): the fixes of design A ·
// Link groups. Compact 24 px icon `OmButton`s (`Move to…`, `Remove from
// <Topic title>`, `File in…`) that are hidden at rest but stay focus stops
// and semantics buttons, revealed on row hover or keyboard focus over a
// surface2 row; per-row in-flight and error state keyed by (topic note id,
// block id); focus after a cancelled dialog and after a fix that removes its
// row.
//
// Numbers come from the design pack (design/393-filed-groups/packs/398.md);
// the board wins over the WI for numbers, the lead rulings and Connor's
// in-flight ruling over the board (buttons centred on the preview's first
// line, the in-flight spinner and label overlaying the end of the preview's
// first line left of the 50 px button column, no reflow).
//
// Most tests pump the section on its own, 340 px wide on a surface1 box, with
// recording vault-access doubles (so the writes are counted) over the #260
// fake server. Hidden or shown, backgrounds, hover fills and the focus ring
// are read from the rendered pixels, so the tests hold for any widget
// structure that draws them. Fonts are the flutter_test fallback (every glyph
// a solid 1 em box). Test names use no apostrophes or quotes.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/widgets/activity/filed_section.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/filed_section_fakes.dart';
import '../support/font_fetch_hold.dart';
import '../support/recording_tabs.dart';
import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';

const _wi398Boundary = Key('wi398-boundary');

Key _link(String topic) => Key('filed-topic-link-$topic');

/// A preview with no break opportunity: its first line is solid glyph boxes
/// up to the preview's right edge (the flutter_test font), and it wraps to
/// two lines.
final _solidPreview = 'coyotetimeforledgejumps' * 6;

/// One line in the 238 px preview column at 1x (12.5 px glyphs).
const _shortText = 'short note';

// ---------- pumping ----------

class _S398 {
  _S398(this.server, this.db, this.doubles, this.vaultPath, this.cli);

  final F260Server server;
  final FakeVaultDb db;
  final AccessDoubles doubles;
  final String vaultPath;
  final FakeMemexCli cli;
  final TabsRecorder tabs = TabsRecorder();
  late final ProviderContainer container;

  RecordingFeedbackAccess get feedback => doubles.feedbackAt(vaultPath);

  List<RecordedCall> get moves => feedback.callsTo('moveBlock');
  List<RecordedCall> get removes => feedback.callsTo('removeBlock');
  List<RecordedCall> get files => feedback.callsTo('fileBlock');
  List<RecordedCall> get writes => [...moves, ...removes, ...files];
}

/// Pumps the section alone, [width] wide at text scale [scale], on a
/// surface1 box inside a [RepaintBoundary] keyed [_wi398Boundary], with
/// recording vault-access doubles.
Future<_S398> _pump398(
  WidgetTester tester, {
  F260Server Function(FakeVaultDb db)? server,
  double width = 340,
  double scale = 1.0,
}) async {
  final db = f260Db();
  final srv = (server ?? f260DefaultServer)(db);
  final cli = f260Cli(db, srv);
  final note = db.getNote(f260DailyId)!;
  final dir = Directory.systemTemp.createTempSync('wi398');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // A leftover temp dir must not fail the test.
    }
  });
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final doubles = AccessDoubles();
  final s = _S398(srv, db, doubles, dir.path, cli);
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
      selectedNoteIdProvider.overrideWith((_) => f260DailyId),
      doubles.override,
      tabsProvider.overrideWith(
        (ref) => TabsNotifier(
          store: UiStateStore(vaultPath: dir.path),
          onPersistedSelection: (_) {},
          isNewTabModifierPressed: () => false,
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
                  key: _wi398Boundary,
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

/// The default day with block `b1` also filed under Economy (`day_filing`
/// lists a block under every topic note that holds it).
F260Server Function(FakeVaultDb) get _sharedB1Day => _day(
  [
    F260Topic(f260Loop, 'Player Loop', [
      (f260B1, f260B1Text),
      (f260B2, f260B2Text),
    ]),
    F260Topic(f260Economy, 'Economy', [(f260B1, f260B1Text)]),
  ],
  [(f260N1, f260N1Text)],
);

// ---------- reading ----------

Rect _rect(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget, reason: '$key');
  return tester.getRect(find.byKey(key));
}

/// The preview Text of the row [row].
/// (A shown tooltip draws the same text as a rich Text, which this skips.)
Finder _preview(Key row, String text) => find.descendant(
  of: find.byKey(row),
  matching: find.byWidgetPredicate((w) => w is Text && w.data == text),
);

RenderParagraph _para(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget);
  return tester.renderObject<RenderParagraph>(text);
}

/// Global y of the centre of [text]'s first line box.
double _firstLineCentre(WidgetTester tester, Finder text) {
  final p = _para(tester, text);
  final boxes = p.getBoxesForSelection(
    const TextSelection(baseOffset: 0, extentOffset: 1),
    boxHeightStyle: ui.BoxHeightStyle.max,
  );
  expect(boxes, isNotEmpty);
  final b = boxes.first;
  return p.localToGlobal(Offset(0, (b.top + b.bottom) / 2)).dy;
}

OmButton _button(WidgetTester tester, Key key) {
  expect(
    find.byWidgetPredicate((w) => w is OmButton && w.key == key),
    findsOneWidget,
    reason: '$key is on an OmButton',
  );
  return tester.widget<OmButton>(find.byKey(key));
}

bool _enabled(WidgetTester tester, Key key) =>
    _button(tester, key).onPressed != null;

/// The product of every opacity between [what] and the section: what a
/// person sees of it (0 hidden, 0.4 disabled).
double _opacity(WidgetTester tester, Finder what) {
  expect(what, findsOneWidget, reason: 'the icon of the button');
  final stop = tester.renderObject(find.byKey(f260Section));
  RenderObject? r = tester.renderObject(what);
  var o = 1.0;
  while (r != null && r != stop) {
    if (r is RenderOpacity) o *= r.opacity;
    if (r is RenderAnimatedOpacity) o *= r.opacity.value;
    r = r.parent;
  }
  return o;
}

Finder _iconIn(Key key) =>
    find.descendant(of: find.byKey(key), matching: find.byType(Icon));

Finder _inRow(Key row, Finder what) =>
    find.descendant(of: find.byKey(row), matching: what);

// ---------- pixels ----------

class _Px398 {
  _Px398(this._bytes, this._width, this._height, this._origin);

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
}

Future<_Px398> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_wi398Boundary),
  );
  final origin = boundary.localToGlobal(Offset.zero);
  final image = (await tester.runAsync(
    () => boundary.toImage(pixelRatio: 1.0),
  ))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final px = _Px398(bytes, image.width, image.height, origin);
  image.dispose();
  return px;
}

int _c255(double v) => (v * 255.0).round() & 0xff;

/// Sum of the channel differences of [a] and [b].
int _dist(Color a, Color b) =>
    (_c255(a.r) - _c255(b.r)).abs() +
    (_c255(a.g) - _c255(b.g)).abs() +
    (_c255(a.b) - _c255(b.b)).abs();

/// The largest difference from [bg] inside [area].
int _maxDiff(_Px398 px, Rect area, Color bg) {
  var most = 0;
  for (var y = area.top.floor(); y < area.bottom.ceil(); y++) {
    for (var x = area.left.floor(); x < area.right.ceil(); x++) {
      final d = _dist(px.at(x + 0.5, y + 0.5), bg);
      if (d > most) most = d;
    }
  }
  return most;
}

/// The amount of [full] (drawn over surface1) in the pixel row at [y] from
/// [x0] to [x1], in pixels.
double _hsum(_Px398 px, double y, double x0, double x1, Color full) {
  var sum = 0.0;
  for (var x = x0.floor(); x < x1.ceil(); x++) {
    sum +=
        _dist(px.at(x + 0.5, y), OmColors.surface1) /
        _dist(full, OmColors.surface1);
  }
  return sum;
}

/// The background of the row [row]: a pixel in its 10 px right padding, by
/// its top edge, and one left of the rail.
void _expectRowBg(_Px398 px, Rect row, Color bg, String what) {
  for (final p in [
    Offset(row.right - 4, row.top + 1.5),
    Offset(row.left + 8, row.top + 1.5),
  ]) {
    expect(
      _dist(px.at(p.dx, p.dy), bg),
      lessThan(8),
      reason: '$what: row background at $p is $bg, got ${px.at(p.dx, p.dy)}',
    );
  }
}

/// Whether anything is drawn inside the button [button] over [bg].
bool _drawn(_Px398 px, Rect button, Color bg) =>
    _maxDiff(px, button.deflate(1), bg) > 60;

bool _blank(_Px398 px, Rect button, Color bg) =>
    _maxDiff(px, button.deflate(1), bg) < 10;

// ---------- semantics ----------

List<SemanticsNode> _nodes(WidgetTester tester) {
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

List<SemanticsNode> _labelled(WidgetTester tester, String label) => [
  for (final n in _nodes(tester))
    if (n.label == label) n,
];

bool _isButton(SemanticsNode n) =>
    n.getSemanticsData().flagsCollection.isButton;

bool _hasTap(SemanticsNode n) =>
    n.getSemanticsData().hasAction(SemanticsAction.tap);

bool _isDisabled(SemanticsNode n) =>
    n.getSemanticsData().flagsCollection.isEnabled == ui.Tristate.isFalse;

// ---------- input ----------

Future<TestGesture> _mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  addTearDown(mouse.removePointer);
  await pumpFrames(tester);
  return mouse;
}

/// Far outside the 340 px section.
const _away = Offset(700, 950);

/// Whether the primary focus is the widget with [key] or inside it.
bool _hasFocus(WidgetTester tester, Key key) {
  expect(find.byKey(key), findsOneWidget, reason: '$key');
  final el = tester.element(find.byKey(key));
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx == el) return true;
  var inside = false;
  ctx.visitAncestorElements((a) {
    if (a == el) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

String _focusName(WidgetTester tester) =>
    '${FocusManager.instance.primaryFocus}';

Future<void> _tab(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

/// Tabs from where focus is until [key] holds it (at most [max] Tabs).
Future<void> _tabTo(WidgetTester tester, Key key, {int max = 12}) async {
  for (var i = 0; i < max; i++) {
    await _tab(tester);
    if (_hasFocus(tester, key)) {
      await pumpFrames(tester);
      return;
    }
  }
  fail('Tab never reached $key (focus: ${_focusName(tester)})');
}

/// Moves focus straight to the focusable OmButton [key] (no traversal).
Future<void> _focusOn(WidgetTester tester, Key key) async {
  final focus = find.descendant(
    of: find.byKey(key),
    matching: find.byType(Focus),
  );
  expect(focus, findsWidgets, reason: '$key is a focus stop');
  final inner = find.descendant(
    of: focus.first,
    matching: find.byType(Semantics),
  );
  expect(inner, findsWidgets, reason: '$key focus child');
  Focus.of(tester.element(inner.first)).requestFocus();
  await pumpFrames(tester);
  expect(_hasFocus(tester, key), isTrue, reason: '$key took focus');
}

Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await pumpFrames(tester);
}

/// Hovers the centre of [key] with a mouse and taps it with a touch, in one
/// step, leaving the mouse there.
Future<TestGesture> _hoverTap(WidgetTester tester, Key key) async {
  final mouse = await _mouseAt(tester, tester.getCenter(find.byKey(key)));
  await tester.tap(find.byKey(key));
  await pumpFrames(tester);
  return mouse;
}

/// Confirms the open dialog: picks [target] first for Move to and File in.
Future<void> _confirm(WidgetTester tester, {String? target}) async {
  if (target != null) await f260Tap(tester, f260Option(target));
  await f260Tap(tester, f260Confirm);
}

/// The three fixes of the default day: the button, the dialog target (null
/// for Remove), the recorded method and the in-flight label.
const _fixes = <(String, String?, String, String)>[
  ('move', f260Economy, 'moveBlock', 'Moving'),
  ('remove', null, 'removeBlock', 'Removing'),
  ('file', f260Level, 'fileBlock', 'Filing'),
];

Key _fixKey(String fix) => switch (fix) {
  'move' => f260Move(f260Loop, f260B1),
  'remove' => f260Remove(f260Loop, f260B2),
  _ => f260FileIn(f260N1),
};

Key _fixRow(String fix) => switch (fix) {
  'move' => f260Row(f260Loop, f260B1),
  'remove' => f260Row(f260Loop, f260B2),
  _ => f260NotFiledRow(f260N1),
};

void main() {
  holdFontFetches();

  group('the fix buttons (AC1)', () {
    testWidgets(
      'each topic row has a Move to and a Remove from topic icon button and each Not filed row a File in icon button',
      (tester) async {
        await _pump398(tester);

        for (final (key, icon, tip) in <(Key, IconData, String)>[
          (f260Move(f260Loop, f260B1), LucideIcons.arrowRightLeft, 'Move to…'),
          (
            f260Remove(f260Loop, f260B1),
            LucideIcons.x,
            'Remove from Player Loop',
          ),
          (f260Move(f260Loop, f260B2), LucideIcons.arrowRightLeft, 'Move to…'),
          (
            f260Remove(f260Loop, f260B2),
            LucideIcons.x,
            'Remove from Player Loop',
          ),
          (
            f260Move(f260Economy, f260B3),
            LucideIcons.arrowRightLeft,
            'Move to…',
          ),
          (
            f260Remove(f260Economy, f260B3),
            LucideIcons.x,
            'Remove from Economy',
          ),
          (f260FileIn(f260N1), LucideIcons.folderInput, 'File in…'),
        ]) {
          final b = _button(tester, key);
          expect(b.label, isNull, reason: '$key is icon only');
          expect(b.icon, icon, reason: '$key icon');
          expect(b.tooltip, tip, reason: '$key tooltip');
          expect(b.focusable, isTrue, reason: '$key focusable');
          expect(b.size, 24, reason: '$key size');
          expect(b.kind, OmButtonKind.ghost, reason: '$key ghost');
          expect(b.hoverBackground, OmColors.surface4, reason: '$key hover');
          final r = _rect(tester, key);
          expect(r.width, closeTo(24, 0.5), reason: '$key 24 wide');
          expect(r.height, closeTo(24, 0.5), reason: '$key 24 tall');
          final i = tester.widget<Icon>(_iconIn(key));
          expect(i.size, 13, reason: '$key 13 px icon');
          expect(i.color, OmColors.fg1, reason: '$key fg1 icon');
          expect(
            find.descendant(of: find.byKey(key), matching: find.byType(Text)),
            findsNothing,
            reason: '$key draws no text',
          );
        }
        expect(find.byKey(f260FileIn(f260B1)), findsNothing);
        expect(find.byKey(f260Move(f260Loop, f260N1)), findsNothing);
        expect(find.byKey(f260Remove(f260Loop, f260N1)), findsNothing);
      },
    );

    testWidgets(
      'at rest every fix button is a semantics button with its label and a tap action',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump398(tester);

        for (final (label, n) in [
          ('Move to…', 3),
          ('Remove from Player Loop', 2),
          ('Remove from Economy', 1),
          ('File in…', 1),
        ]) {
          final nodes = _labelled(tester, label);
          expect(nodes, hasLength(n), reason: '$label nodes at rest');
          for (final node in nodes) {
            expect(_isButton(node), isTrue, reason: '$label is a button');
            expect(_hasTap(node), isTrue, reason: '$label has a tap action');
            expect(node.childrenCount, 0, reason: '$label is one leaf node');
          }
        }
        handle.dispose();
      },
    );

    testWidgets(
      'the fix buttons sit right aligned 10 px from the row edge 2 px apart and centred on the preview first line',
      (tester) async {
        await _pump398(
          tester,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [
                (f260B1, _shortText),
                (f260B2, _solidPreview),
              ]),
            ],
            [(f260N1, _shortText)],
          ),
        );

        for (final (rowKey, text) in [
          (f260Row(f260Loop, f260B1), _shortText),
          (f260Row(f260Loop, f260B2), _solidPreview),
        ]) {
          final block = rowKey == f260Row(f260Loop, f260B1) ? f260B1 : f260B2;
          final row = _rect(tester, rowKey);
          final move = _rect(tester, f260Move(f260Loop, block));
          final remove = _rect(tester, f260Remove(f260Loop, block));
          final preview = tester.getRect(_preview(rowKey, text));
          final line = _firstLineCentre(tester, _preview(rowKey, text));
          expect(
            remove.right,
            closeTo(row.right - 10, 0.5),
            reason: 'Remove 10 px from the right edge ($block)',
          );
          expect(
            remove.left - move.right,
            closeTo(2, 0.5),
            reason: '2 px between the buttons ($block)',
          );
          for (final (name, r) in [('Move', move), ('Remove', remove)]) {
            expect(
              r.center.dy,
              closeTo(line, 1),
              reason: '$name centred on the first preview line ($block)',
            );
          }
          expect(
            preview.right,
            lessThanOrEqualTo(move.left + 0.5),
            reason: 'the preview sits left of the button column ($block)',
          );
          expect(
            preview.width,
            closeTo(238, 0.5),
            reason: 'board: 340 - 36 - 10 - 50 - 6 ($block)',
          );
        }

        final nfRow = _rect(tester, f260NotFiledRow(f260N1));
        final fileIn = _rect(tester, f260FileIn(f260N1));
        final nfLine = _firstLineCentre(
          tester,
          _preview(f260NotFiledRow(f260N1), _shortText),
        );
        expect(fileIn.right, closeTo(nfRow.right - 10, 0.5));
        expect(fileIn.center.dy, closeTo(nfLine, 1));
      },
    );

    testWidgets('a fix button has 6 px corners and a surface4 hover fill', (
      tester,
    ) async {
      await _pump398(tester);
      final move = _rect(tester, f260Move(f260Loop, f260B1));
      final remove = _rect(tester, f260Remove(f260Loop, f260B1));

      await _mouseAt(tester, move.center);
      final px = await _capture(tester);

      expect(
        _dist(px.at(move.left + 4.5, move.top + 4.5), OmColors.surface4),
        lessThan(8),
        reason: 'the hovered Move to fills surface4',
      );
      expect(
        _dist(px.at(move.left + 0.5, move.top + 0.5), OmColors.surface2),
        lessThan(8),
        reason: 'a 6 px corner leaves the row background in the box corner',
      );
      expect(
        _dist(px.at(remove.left + 4.5, remove.top + 4.5), OmColors.surface2),
        lessThan(8),
        reason: 'the Remove that is not hovered shows the row background',
      );
    });

    testWidgets(
      'keyboard focus on a fix button draws the 2 px accent ring inside it over surface4',
      (tester) async {
        await _pump398(tester);

        await _tabTo(tester, f260Remove(f260Loop, f260B1));
        final remove = _rect(tester, f260Remove(f260Loop, f260B1));
        final move = _rect(tester, f260Move(f260Loop, f260B1));
        final px = await _capture(tester);

        expect(
          _dist(px.at(remove.left + 1, remove.center.dy), OmColors.accent),
          lessThan(24),
          reason: 'the ring on the left edge',
        );
        expect(
          _dist(px.at(remove.right - 1, remove.center.dy), OmColors.accent),
          lessThan(24),
          reason: 'the ring on the right edge',
        );
        expect(
          _dist(px.at(remove.left + 4.5, remove.top + 4.5), OmColors.surface4),
          lessThan(8),
          reason: 'the focus fill is surface4',
        );
        expect(
          _dist(px.at(move.left + 1, move.center.dy), OmColors.surface2),
          lessThan(8),
          reason: 'no ring on the button that is not focused',
        );
      },
    );
  });

  group('hidden at rest (AC2, AC3)', () {
    testWidgets(
      'at rest the fix buttons are not drawn and the preview keeps its width when the row is revealed',
      (tester) async {
        await _pump398(
          tester,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [
                (f260B1, _solidPreview),
                (f260B2, _shortText),
              ]),
            ],
            [(f260N1, _shortText)],
          ),
        );
        final rowKey = f260Row(f260Loop, f260B1);
        final previewAtRest = tester.getRect(_preview(rowKey, _solidPreview));
        final moveAtRest = _rect(tester, f260Move(f260Loop, f260B1));
        final rest = await _capture(tester);

        for (final key in [
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260Move(f260Loop, f260B2),
          f260Remove(f260Loop, f260B2),
          f260FileIn(f260N1),
        ]) {
          expect(
            _blank(rest, _rect(tester, key), OmColors.surface1),
            isTrue,
            reason: '$key is not drawn at rest',
          );
        }
        _expectRowBg(rest, _rect(tester, rowKey), OmColors.surface1, 'rest');

        final mouse = await _mouseAt(tester, previewAtRest.center);
        expect(
          tester.getRect(_preview(rowKey, _solidPreview)),
          previewAtRest,
          reason: 'hover reveals without reflow',
        );
        expect(_rect(tester, f260Move(f260Loop, f260B1)), moveAtRest);

        await mouse.moveTo(_away);
        await pumpFrames(tester);
        await _tabTo(tester, f260Move(f260Loop, f260B1));
        expect(
          tester.getRect(_preview(rowKey, _solidPreview)),
          previewAtRest,
          reason: 'focus reveals without reflow',
        );
      },
    );

    testWidgets(
      'a touch tap on a hidden fix button opens no dialog and writes nothing',
      (tester) async {
        final s = await _pump398(tester);

        for (final key in [
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260FileIn(f260N1),
        ]) {
          await tester.tap(find.byKey(key), warnIfMissed: false);
          await pumpFrames(tester);
          expect(find.byKey(f260Confirm), findsNothing, reason: '$key');
          expect(find.byType(Dialog), findsNothing, reason: '$key');
        }
        expect(s.feedback.calls.where((c) => c.method != 'filing'), isEmpty);

        // Revealed by the pointer, the same tap opens its dialog.
        await _hoverTap(tester, f260Move(f260Loop, f260B1));
        expect(find.byKey(f260Confirm), findsOneWidget);
      },
    );
  });

  group('reveal on hover and focus (AC4)', () {
    testWidgets(
      'the pointer over a row reveals its buttons on surface2 and leaving the row hides them',
      (tester) async {
        await _pump398(tester);
        final b1 = f260Row(f260Loop, f260B1);
        final b2 = f260Row(f260Loop, f260B2);
        final n1 = f260NotFiledRow(f260N1);

        final mouse = await _mouseAt(
          tester,
          tester.getCenter(_preview(b1, f260B1Text)),
        );
        var px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface2, 'b1 hovered');
        for (final key in [
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
        ]) {
          expect(
            _drawn(px, _rect(tester, key), OmColors.surface2),
            isTrue,
            reason: '$key shows on hover',
          );
        }
        _expectRowBg(px, _rect(tester, b2), OmColors.surface1, 'b2 at rest');
        expect(
          _blank(
            px,
            _rect(tester, f260Move(f260Loop, f260B2)),
            OmColors.surface1,
          ),
          isTrue,
          reason: 'another row stays hidden',
        );

        await mouse.moveTo(tester.getCenter(_preview(b2, f260B2Text)));
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface1, 'b1 left');
        expect(
          _blank(
            px,
            _rect(tester, f260Move(f260Loop, f260B1)),
            OmColors.surface1,
          ),
          isTrue,
          reason: 'leaving b1 hides its buttons',
        );
        _expectRowBg(px, _rect(tester, b2), OmColors.surface2, 'b2 hovered');
        expect(
          _drawn(
            px,
            _rect(tester, f260Remove(f260Loop, f260B2)),
            OmColors.surface2,
          ),
          isTrue,
        );

        await mouse.moveTo(tester.getCenter(_preview(n1, f260N1Text)));
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, n1), OmColors.surface2, 'n1 hovered');
        expect(
          _drawn(px, _rect(tester, f260FileIn(f260N1)), OmColors.surface2),
          isTrue,
          reason: 'File in shows on hover',
        );

        await mouse.moveTo(_away);
        await pumpFrames(tester);
        px = await _capture(tester);
        for (final (row, button) in [
          (b1, f260Move(f260Loop, f260B1)),
          (b2, f260Move(f260Loop, f260B2)),
          (n1, f260FileIn(f260N1)),
        ]) {
          _expectRowBg(px, _rect(tester, row), OmColors.surface1, '$row out');
          expect(
            _blank(px, _rect(tester, button), OmColors.surface1),
            isTrue,
            reason: '$button hidden after the pointer left',
          );
        }
      },
    );

    testWidgets(
      'keyboard focus on a fix button reveals its row on surface2 and focus moving out hides it',
      (tester) async {
        await _pump398(tester);
        final b1 = f260Row(f260Loop, f260B1);
        final b2 = f260Row(f260Loop, f260B2);

        await _tabTo(tester, f260Move(f260Loop, f260B1));
        var px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface2, 'b1 focused');
        expect(
          _drawn(
            px,
            _rect(tester, f260Remove(f260Loop, f260B1)),
            OmColors.surface2,
          ),
          isTrue,
          reason: 'the row of the focused button shows both buttons',
        );
        _expectRowBg(px, _rect(tester, b2), OmColors.surface1, 'b2 at rest');

        await _tab(tester);
        expect(_hasFocus(tester, f260Remove(f260Loop, f260B1)), isTrue);
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface2, 'Remove b1');

        await _tab(tester);
        expect(_hasFocus(tester, f260Move(f260Loop, f260B2)), isTrue);
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface1, 'focus left b1');
        expect(
          _blank(
            px,
            _rect(tester, f260Move(f260Loop, f260B1)),
            OmColors.surface1,
          ),
          isTrue,
          reason: 'b1 hides once focus moved out',
        );
        _expectRowBg(px, _rect(tester, b2), OmColors.surface2, 'b2 focused');
        expect(
          _drawn(
            px,
            _rect(tester, f260Remove(f260Loop, f260B2)),
            OmColors.surface2,
          ),
          isTrue,
        );

        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b2), OmColors.surface1, 'unfocused');
        expect(
          _blank(
            px,
            _rect(tester, f260Move(f260Loop, f260B2)),
            OmColors.surface1,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'a row stays revealed while focused after the pointer leaves and while hovered after focus leaves',
      (tester) async {
        await _pump398(tester);
        final b1 = f260Row(f260Loop, f260B1);
        final move = f260Move(f260Loop, f260B1);

        final mouse = await _mouseAt(
          tester,
          tester.getCenter(_preview(b1, f260B1Text)),
        );
        await _tabTo(tester, move);
        await mouse.moveTo(_away);
        await pumpFrames(tester);
        var px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface2, 'focus only');
        expect(_drawn(px, _rect(tester, move), OmColors.surface2), isTrue);

        await mouse.moveTo(tester.getCenter(_preview(b1, f260B1Text)));
        await pumpFrames(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface2, 'hover only');
        expect(_drawn(px, _rect(tester, move), OmColors.surface2), isTrue);

        await mouse.moveTo(_away);
        await pumpFrames(tester);
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, b1), OmColors.surface1, 'neither');
        expect(_blank(px, _rect(tester, move), OmColors.surface1), isTrue);
      },
    );
  });

  group('focus order and semantics (AC5, AC6)', () {
    testWidgets(
      'Tab visits each topic link then its rows Move to and Remove top to bottom then each Not filed File in',
      (tester) async {
        await _pump398(
          tester,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [
                (f260B1, f260B1Text),
                (f260B2, f260B2Text),
              ]),
              F260Topic(f260Economy, 'Economy', [(f260B3, f260B3Text)]),
            ],
            [(f260N1, f260N1Text), ('n2', 'buy milk')],
          ),
        );

        final order = [
          _link(f260Loop),
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
          f260Move(f260Loop, f260B2),
          f260Remove(f260Loop, f260B2),
          _link(f260Economy),
          f260Move(f260Economy, f260B3),
          f260Remove(f260Economy, f260B3),
          f260FileIn(f260N1),
          f260FileIn('n2'),
        ];
        for (final (i, key) in order.indexed) {
          await _tab(tester);
          expect(
            _hasFocus(tester, key),
            isTrue,
            reason: 'Tab ${i + 1} stops on $key (focus: ${_focusName(tester)})',
          );
        }
      },
    );

    testWidgets('a semantics tap on a hidden fix button opens its dialog', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final s = await _pump398(
        tester,
        server: _day(
          [
            F260Topic(f260Loop, 'Player Loop', [(f260B1, f260B1Text)]),
          ],
          [(f260N1, f260N1Text)],
        ),
      );
      final px = await _capture(tester);
      for (final key in [
        f260Move(f260Loop, f260B1),
        f260Remove(f260Loop, f260B1),
        f260FileIn(f260N1),
      ]) {
        expect(
          _blank(px, _rect(tester, key), OmColors.surface1),
          isTrue,
          reason: '$key hidden',
        );
      }

      for (final (label, title) in [
        ('Move to…', 'Move to…'),
        ('Remove from Player Loop', null),
        ('File in…', 'File in…'),
      ]) {
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        final nodes = _labelled(tester, label);
        expect(nodes, hasLength(1), reason: label);
        nodes.single.owner!.performAction(nodes.single.id, SemanticsAction.tap);
        await pumpFrames(tester);
        expect(find.byKey(f260Confirm), findsOneWidget, reason: label);
        if (title != null) {
          expect(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.text(title),
            ),
            findsOneWidget,
            reason: '$label opens its own dialog',
          );
        }
        await f260Tap(tester, f260Cancel);
        expect(find.byKey(f260Confirm), findsNothing);
      }
      expect(s.writes, isEmpty, reason: 'Cancel writes nothing');
      handle.dispose();
    });
  });

  group('focus after a cancelled dialog (AC8)', () {
    testWidgets(
      'Cancel on a dialog opened by a pointer returns focus to its fix button',
      (tester) async {
        final s = await _pump398(tester);

        for (final (fix, _, _, _) in _fixes) {
          FocusManager.instance.primaryFocus?.unfocus();
          await pumpFrames(tester);
          await f260Tap(tester, _fixKey(fix));
          expect(find.byKey(f260Cancel), findsOneWidget, reason: fix);
          await f260Tap(tester, f260Cancel);
          expect(find.byKey(f260Cancel), findsNothing);
          expect(
            _hasFocus(tester, _fixKey(fix)),
            isTrue,
            reason: 'focus back on ${_fixKey(fix)} (${_focusName(tester)})',
          );
        }
        expect(s.writes, isEmpty);
      },
    );

    testWidgets(
      'Esc on a dialog opened from the keyboard returns focus to its fix button',
      (tester) async {
        final s = await _pump398(tester);

        for (final (fix, _, _, _) in _fixes) {
          await _tabTo(tester, _fixKey(fix), max: 20);
          await _enter(tester);
          expect(find.byKey(f260Cancel), findsOneWidget, reason: fix);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await pumpFrames(tester);
          expect(find.byKey(f260Cancel), findsNothing, reason: fix);
          expect(
            _hasFocus(tester, _fixKey(fix)),
            isTrue,
            reason: 'focus back on ${_fixKey(fix)} (${_focusName(tester)})',
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await pumpFrames(tester);
        }
        expect(s.writes, isEmpty);
      },
    );
  });

  group('in flight (AC9, AC10)', () {
    testWidgets(
      'a running fix keeps its buttons visible and disabled at 40 percent with a spinner and its label left of the column',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pump398(
          tester,
          server: _day([
            F260Topic(f260Loop, 'Player Loop', [
              (f260B1, _solidPreview),
              (f260B2, f260B2Text),
            ]),
            F260Topic(f260Economy, 'Economy', [(f260B3, f260B3Text)]),
          ]),
        );
        final rowKey = f260Row(f260Loop, f260B1);
        final moveKey = f260Move(f260Loop, f260B1);
        final removeKey = f260Remove(f260Loop, f260B1);
        final previewAtRest = tester.getRect(_preview(rowKey, _solidPreview));
        s.feedback.gate('moveBlock');

        final mouse = await _hoverTap(tester, moveKey);
        final move0 = _rect(tester, moveKey);
        await _confirm(tester, target: f260Economy);
        expect(s.moves, hasLength(1));
        await mouse.moveTo(_away);
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);

        // The buttons: still shown, disabled, at 40 %.
        expect(_enabled(tester, moveKey), isFalse);
        expect(_enabled(tester, removeKey), isFalse);
        for (final key in [moveKey, removeKey]) {
          expect(
            _opacity(tester, _iconIn(key)),
            closeTo(0.4, 0.01),
            reason: '$key at 40 %',
          );
        }
        final px = await _capture(tester);
        _expectRowBg(px, _rect(tester, rowKey), OmColors.surface2, 'in flight');
        expect(_drawn(px, _rect(tester, moveKey), OmColors.surface2), isTrue);
        expect(_drawn(px, _rect(tester, removeKey), OmColors.surface2), isTrue);
        expect(_rect(tester, moveKey), move0, reason: 'the column stays put');

        // The spinner and its label, left of the column.
        final spinner = _inRow(rowKey, find.byIcon(LucideIcons.loaderCircle));
        expect(spinner, findsOneWidget);
        final icon = tester.widget<Icon>(spinner);
        expect(icon.size, 14);
        expect(icon.color, OmColors.accent);
        final label = _inRow(rowKey, find.text('Moving'));
        expect(label, findsOneWidget);
        final st = _para(tester, label).text.style!;
        expect(st.fontSize, 10.5);
        expect(st.color, OmColors.fg2);
        expect(st.fontFamily, OmType.mono(size: 10.5).fontFamily);
        final sr = tester.getRect(spinner);
        final lr = tester.getRect(label);
        expect(sr.width, closeTo(14, 0.5));
        expect(
          lr.right,
          closeTo(move0.left, 1),
          reason: 'right-aligned against the button column',
        );
        expect(lr.left - sr.right, closeTo(6, 0.5), reason: '6 px gap');
        expect(sr.center.dy, closeTo(move0.center.dy, 1));
        expect(lr.center.dy, closeTo(move0.center.dy, 1));
        expect(
          _dist(
            px.at((sr.right + lr.left) / 2, move0.center.dy),
            OmColors.surface2,
          ),
          lessThan(8),
          reason: 'a surface2 backing covers the end of the first line',
        );
        expect(
          tester.getRect(_preview(rowKey, _solidPreview)),
          previewAtRest,
          reason: 'the preview does not reflow',
        );
        expect(_labelled(tester, 'Moving'), isNotEmpty);
        final moveNode = _labelled(tester, 'Move to…');
        expect(moveNode.where(_isDisabled), hasLength(1));

        s.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
        expect(find.byIcon(LucideIcons.loaderCircle), findsNothing);
        expect(find.text('Moving'), findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'the in flight label is one leaf semantics node that goes with the fix',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pump398(
          tester,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [(f260B1, f260B1Text)]),
            ],
            [(f260N1, f260N1Text)],
          ),
        );
        expect(_labelled(tester, 'Moving'), isEmpty, reason: 'nothing runs');
        s.feedback.gate('moveBlock');

        await _tabTo(tester, f260Move(f260Loop, f260B1));
        await _enter(tester);
        await _confirm(tester, target: f260Economy);
        await pumpFrames(tester);
        expect(s.moves, hasLength(1));

        final nodes = _labelled(tester, 'Moving');
        expect(nodes, hasLength(1), reason: 'one node, not the text too');
        expect(nodes.single.childrenCount, 0, reason: 'a leaf');
        expect(_labelled(tester, 'Removing'), isEmpty);
        expect(_labelled(tester, 'Filing'), isEmpty);

        s.feedback.gates['moveBlock']!.single.complete();
        await pumpFrames(tester);
        expect(_labelled(tester, 'Moving'), isEmpty, reason: 'fix ended');
        handle.dispose();
      },
    );

    testWidgets(
      'the in flight overlay hides the preview text under it that shows again when the fix ends',
      (tester) async {
        final s = await _pump398(
          tester,
          server: _day([
            F260Topic(f260Loop, 'Player Loop', [
              (f260B1, _solidPreview),
              (f260B2, f260B2Text),
            ]),
          ]),
        );
        final rowKey = f260Row(f260Loop, f260B1);
        final moveKey = f260Move(f260Loop, f260B1);
        s.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
        s.feedback.gate('removeBlock');

        await f260Tap(tester, f260Remove(f260Loop, f260B1));
        await f260Tap(tester, f260Confirm);
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        final label = _inRow(rowKey, find.text('Removing'));
        expect(label, findsOneWidget);
        final spinner = _inRow(rowKey, find.byIcon(LucideIcons.loaderCircle));
        final gapX =
            (tester.getRect(spinner).right + tester.getRect(label).left) / 2;
        final y = _rect(tester, moveKey).center.dy;
        var px = await _capture(tester);
        expect(_dist(px.at(gapX, y), OmColors.surface2), lessThan(8));

        s.feedback.gates['removeBlock']!.single.complete();
        await pumpFrames(tester);
        expect(f260Error, findsOneWidget, reason: 'the fix failed');
        expect(find.text('Removing'), findsNothing);
        px = await _capture(tester);
        expect(
          _dist(px.at(gapX, y), OmColors.fg1),
          lessThan(60),
          reason: 'the covered first-line glyphs show again',
        );
      },
    );

    testWidgets('each fix shows its own in flight label', (tester) async {
      final s = await _pump398(tester);
      for (final (fix, target, method, word) in _fixes) {
        s.feedback.gate(method);
        await f260Tap(tester, _fixKey(fix));
        await _confirm(tester, target: target);
        expect(
          _inRow(_fixRow(fix), find.text(word)),
          findsOneWidget,
          reason: '$fix shows $word',
        );
        expect(
          _inRow(_fixRow(fix), find.byIcon(LucideIcons.loaderCircle)),
          findsOneWidget,
          reason: '$fix spinner',
        );
        for (final other in ['Moving', 'Removing', 'Filing']) {
          if (other == word) continue;
          expect(find.text(other), findsNothing, reason: '$fix not $other');
        }
        s.server.nextWriteError = null;
        s.feedback.failNext(method, MemexException('stop', code: 'internal'));
        s.feedback.gates[method]!.single.complete();
        await pumpFrames(tester);
        expect(find.text(word), findsNothing, reason: '$fix ended');
        await f260Tap(tester, const Key('inline-error-dismiss'));
      }
    });

    testWidgets(
      'two taps on a fix button in the same frame open one dialog and write once',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pump398(tester);
        // Two semantics taps (an assistive double activation) in one frame.
        for (final (fix, _, _, _) in _fixes) {
          final node = tester.getSemantics(find.byKey(_fixKey(fix)));
          node.owner!.performAction(node.id, SemanticsAction.tap);
          node.owner!.performAction(node.id, SemanticsAction.tap);
          await pumpFrames(tester);
          var dialogs = 0;
          while (find.byKey(f260Cancel).evaluate().isNotEmpty && dialogs < 3) {
            dialogs++;
            await f260Tap(tester, f260Cancel);
          }
          expect(dialogs, 1, reason: '$fix: two semantics taps, one dialog');
        }
        expect(s.writes, isEmpty);
        handle.dispose();

        // Two pointer taps in one frame, each confirmed.
        for (final (fix, target, method, _) in _fixes) {
          final key = _fixKey(fix);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: tester.getCenter(find.byKey(key)));
          await pumpFrames(tester);
          await tester.tap(find.byKey(key));
          await tester.tap(find.byKey(key), warnIfMissed: false);
          await pumpFrames(tester);
          await mouse.removePointer();
          await pumpFrames(tester);

          expect(find.byKey(f260Confirm), findsOneWidget, reason: fix);
          var dialogs = 0;
          while (find.byKey(f260Confirm).evaluate().isNotEmpty && dialogs < 3) {
            dialogs++;
            await _confirm(tester, target: target);
          }
          expect(dialogs, 1, reason: '$fix opened one dialog');
          expect(s.feedback.callsTo(method), hasLength(1), reason: fix);
        }
        expect(s.writes, hasLength(3));
      },
    );

    testWidgets(
      'a held Enter on a fix button opens one dialog and writes once',
      (tester) async {
        final s = await _pump398(tester);

        // Every fix, not only Move to: each is its own press path.
        for (final (fix, target, method, _) in _fixes) {
          s.feedback.gate(method);
          final key = _fixKey(fix);
          List<RecordedCall> calls() => s.feedback.callsTo(method);

          await _focusOn(tester, key);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
          await pumpFrames(tester);
          expect(find.byKey(f260Confirm), findsOneWidget, reason: fix);
          await _confirm(tester, target: target);
          expect(find.byKey(f260Confirm), findsNothing, reason: fix);
          expect(calls(), hasLength(1), reason: '$fix: one write');

          // While the fix runs its button keeps focus and ignores Enter.
          expect(
            _hasFocus(tester, key),
            isTrue,
            reason: '$fix: ${_focusName(tester)}',
          );
          await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
          await pumpFrames(tester);
          expect(find.byKey(f260Confirm), findsNothing, reason: '$fix: busy');
          expect(calls(), hasLength(1), reason: '$fix: still one write');
          s.feedback.gates[method]!.single.complete();
          await pumpFrames(tester);
          expect(calls(), hasLength(1), reason: '$fix: ended with one write');
          if (fix == 'move') {
            expect(s.cli.callsFor('excerpt move'), hasLength(1));
          }
        }
        expect(s.writes, hasLength(3));
      },
    );

    testWidgets(
      'a press on a fix button while its fix runs writes nothing more and its focus stays',
      (tester) async {
        final s = await _pump398(tester);
        s.feedback.gate('removeBlock');
        final remove = f260Remove(f260Loop, f260B1);
        final move = f260Move(f260Loop, f260B1);

        await _tabTo(tester, remove);
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        expect(s.removes, hasLength(1));
        expect(_hasFocus(tester, remove), isTrue, reason: _focusName(tester));

        await _enter(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await pumpFrames(tester);
        await _hoverTap(tester, move);
        await tester.tap(find.byKey(remove), warnIfMissed: false);
        await pumpFrames(tester);
        expect(find.byKey(f260Confirm), findsNothing, reason: 'no dialog');
        expect(s.writes, hasLength(1));
        expect(
          _hasFocus(tester, remove),
          isTrue,
          reason: 'a disabled focusable button keeps focus (LR3)',
        );
        s.feedback.gates['removeBlock']!.single.complete();
        await pumpFrames(tester);
        expect(s.writes, hasLength(1));
      },
    );
  });

  group('per-row state (AC11)', () {
    testWidgets(
      'a fix in flight on a block under one topic leaves the same block under another topic live',
      (tester) async {
        final s = await _pump398(tester, server: _sharedB1Day);
        s.feedback.gate('removeBlock');

        await f260Tap(tester, f260Remove(f260Loop, f260B1));
        await f260Tap(tester, f260Confirm);
        expect(s.removes, hasLength(1));

        expect(_enabled(tester, f260Move(f260Loop, f260B1)), isFalse);
        expect(_enabled(tester, f260Remove(f260Loop, f260B1)), isFalse);
        for (final key in [
          f260Move(f260Economy, f260B1),
          f260Remove(f260Economy, f260B1),
          f260Move(f260Loop, f260B2),
          f260Remove(f260Loop, f260B2),
          f260FileIn(f260N1),
        ]) {
          expect(_enabled(tester, key), isTrue, reason: '$key stays live');
        }
        expect(find.byIcon(LucideIcons.loaderCircle), findsOneWidget);
        expect(
          _inRow(
            f260Row(f260Loop, f260B1),
            find.byIcon(LucideIcons.loaderCircle),
          ),
          findsOneWidget,
          reason: 'the spinner is on the Player Loop row of b1',
        );
        expect(
          _opacity(tester, _iconIn(f260Move(f260Economy, f260B1))),
          anyOf(0.0, 1.0),
          reason: 'the Economy row of b1 is not dimmed',
        );

        // The same block under Economy can be fixed meanwhile.
        await f260Tap(tester, f260Move(f260Economy, f260B1));
        await _confirm(tester, target: f260Sleep);
        expect(s.moves, hasLength(1));
        expect(s.moves.single.args['fromTopicNoteId'], f260Economy);
        expect(s.moves.single.args['blockId'], f260B1);

        s.feedback.gates['removeBlock']!.single.complete();
        await pumpFrames(tester);
        expect(find.byIcon(LucideIcons.loaderCircle), findsNothing);
      },
    );

    testWidgets(
      'a failed fix shows its error only under its own topic row of the block',
      (tester) async {
        final s = await _pump398(tester, server: _sharedB1Day);
        s.server.nextWriteError = FakeMemexCli.error(
          'internal',
          'topic note not found: Level Design',
        );

        await f260Tap(tester, f260Remove(f260Loop, f260B1));
        await f260Tap(tester, f260Confirm);
        expect(s.removes, hasLength(1));

        expect(f260Error, findsOneWidget, reason: 'one error, one row');
        final err = tester.getRect(f260Error);
        final loopB1 = _rect(tester, f260Row(f260Loop, f260B1));
        final loopB2 = _rect(tester, f260Row(f260Loop, f260B2));
        expect(err.top, greaterThanOrEqualTo(loopB1.top));
        expect(err.bottom, lessThanOrEqualTo(loopB2.top + 0.5));
        for (final key in [
          f260Move(f260Economy, f260B1),
          f260Remove(f260Economy, f260B1),
          f260Move(f260Loop, f260B1),
        ]) {
          expect(_enabled(tester, key), isTrue, reason: '$key');
        }
      },
    );
  });

  group('focus after a fix (AC12)', () {
    testWidgets(
      'a keyboard Move to that takes its row out moves focus to the next row first fix button',
      (tester) async {
        final s = await _pump398(tester);

        await _tabTo(tester, f260Move(f260Loop, f260B1));
        await _enter(tester);
        await _confirm(tester, target: f260Economy);
        await pumpFrames(tester);

        expect(s.moves, hasLength(1));
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        expect(
          _hasFocus(tester, f260Move(f260Loop, f260B2)),
          isTrue,
          reason: 'next row of Player Loop (${_focusName(tester)})',
        );
      },
    );

    testWidgets(
      'a keyboard Remove with a row after it moves focus to that row first fix button not its Remove',
      (tester) async {
        final s = await _pump398(tester);

        await _tabTo(tester, f260Remove(f260Loop, f260B1));
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);

        expect(s.removes, hasLength(1));
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        expect(
          _hasFocus(tester, f260Move(f260Loop, f260B2)),
          isTrue,
          reason: 'the next row first button (${_focusName(tester)})',
        );
        expect(
          _hasFocus(tester, f260Remove(f260Loop, f260B2)),
          isFalse,
          reason: 'not the same kind of button as the gone one',
        );
      },
    );

    testWidgets(
      'a keyboard Remove on the last row of a group moves focus to its topic link',
      (tester) async {
        final s = await _pump398(tester);

        await _tabTo(tester, f260Remove(f260Loop, f260B2));
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);

        expect(s.removes, hasLength(1));
        expect(find.byKey(f260Row(f260Loop, f260B2)), findsNothing);
        expect(
          _hasFocus(tester, _link(f260Loop)),
          isTrue,
          reason: 'the Player Loop link (${_focusName(tester)})',
        );
      },
    );

    testWidgets(
      'a keyboard fix that empties its group moves focus to the first focus stop of the section',
      (tester) async {
        final s = await _pump398(tester);

        await _tabTo(tester, f260Remove(f260Economy, f260B3), max: 20);
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);
        expect(s.removes, hasLength(1));
        expect(find.byKey(_link(f260Economy)), findsNothing);
        expect(
          _hasFocus(tester, _link(f260Loop)),
          isTrue,
          reason: 'the first topic link (${_focusName(tester)})',
        );

        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        // The Not filed group has no topic link: b3 and n1 are not filed now.
        await _tabTo(tester, f260FileIn(f260N1), max: 20);
        await _enter(tester);
        await _confirm(tester, target: f260Level);
        await pumpFrames(tester);
        expect(s.files, hasLength(1));
        expect(
          _hasFocus(tester, f260FileIn(f260B3)),
          isTrue,
          reason: 'the next Not filed row (${_focusName(tester)})',
        );
        await _enter(tester);
        await _confirm(tester, target: f260Level);
        await pumpFrames(tester);
        expect(s.files, hasLength(2));
        expect(find.byKey(f260NotFiledRow(f260B3)), findsNothing);
        expect(
          _hasFocus(tester, _link(f260Loop)),
          isTrue,
          reason: 'Not filed emptied: the first focus stop',
        );
      },
    );

    testWidgets(
      'a keyboard fix that empties the last topic group moves focus to the first Not filed File in',
      (tester) async {
        final s = await _pump398(tester);

        await _tabTo(tester, f260Remove(f260Economy, f260B3), max: 20);
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);
        await _tabTo(tester, f260Remove(f260Loop, f260B2), max: 20);
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);
        expect(s.removes, hasLength(2));
        expect(_hasFocus(tester, _link(f260Loop)), isTrue);

        await _tabTo(tester, f260Remove(f260Loop, f260B1), max: 20);
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);

        expect(s.removes, hasLength(3));
        expect(find.byKey(_link(f260Loop)), findsNothing);
        expect(find.byKey(_link(f260Economy)), findsNothing);
        expect(
          _hasFocus(tester, f260FileIn(f260N1)),
          isTrue,
          reason: 'the first Not filed row (${_focusName(tester)})',
        );
      },
    );

    testWidgets(
      'a failed keyboard fix keeps focus on its button and its buttons visible',
      (tester) async {
        final s = await _pump398(tester);
        s.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
        final move = f260Move(f260Loop, f260B1);

        await _tabTo(tester, move);
        await _enter(tester);
        await _confirm(tester, target: f260Economy);
        await pumpFrames(tester);

        expect(s.moves, hasLength(1));
        expect(f260Error, findsOneWidget);
        expect(_hasFocus(tester, move), isTrue, reason: _focusName(tester));
        expect(_enabled(tester, move), isTrue);
        final px = await _capture(tester);
        expect(
          _drawn(
            px,
            _rect(tester, f260Remove(f260Loop, f260B1)),
            OmColors.surface2,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'a failed keyboard fix keeps the focus ring and the focused semantics on its button through the error and its dismissal',
      (tester) async {
        final handle = tester.ensureSemantics();
        final s = await _pump398(tester);
        s.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
        final move = f260Move(f260Loop, f260B1);
        final remove = f260Remove(f260Loop, f260B1);

        bool semanticsFocused(Key key) =>
            tester
                .getSemantics(find.byKey(key))
                .getSemanticsData()
                .flagsCollection
                .isFocused ==
            ui.Tristate.isTrue;

        Future<void> expectFocusedLook(String when) async {
          expect(_hasFocus(tester, move), isTrue, reason: '$when focus');
          expect(semanticsFocused(move), isTrue, reason: '$when semantics');
          expect(semanticsFocused(remove), isFalse, reason: '$when sibling');
          final px = await _capture(tester);
          final r = _rect(tester, move);
          expect(
            _dist(px.at(r.left + 1, r.center.dy), OmColors.accent),
            lessThan(24),
            reason: '$when: the 2 px ring is on the left edge',
          );
          expect(
            _dist(px.at(r.right - 1, r.center.dy), OmColors.accent),
            lessThan(24),
            reason: '$when: the 2 px ring is on the right edge',
          );
          expect(
            _dist(px.at(r.left + 4.5, r.top + 4.5), OmColors.surface4),
            lessThan(8),
            reason: '$when: the focus fill is surface4',
          );
        }

        await _tabTo(tester, move);
        await expectFocusedLook('before the fix');
        await _enter(tester);
        await _confirm(tester, target: f260Economy);
        await pumpFrames(tester);
        expect(f260Error, findsOneWidget);
        // The dialog was confirmed with the pointer: a key press puts the
        // focus highlight back to keyboard mode, as for a keyboard user.
        await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
        await pumpFrames(tester);
        await expectFocusedLook('after the failure');

        // Dismissing the error keeps the focus where it is.
        await f260Tap(tester, const Key('inline-error-dismiss'));
        expect(f260Error, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
        await pumpFrames(tester);
        await expectFocusedLook('after the dismissal');
        handle.dispose();
      },
    );

    testWidgets(
      'a pointer run fix that takes its row out moves no focus and leaves the other rows at rest',
      (tester) async {
        final s = await _pump398(tester);

        await f260MoveTo(
          tester,
          from: f260Loop,
          block: f260B1,
          target: f260Economy,
        );
        await pumpFrames(tester);
        expect(s.moves, hasLength(1));
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);

        for (final key in [
          f260Move(f260Loop, f260B2),
          f260Move(f260Economy, f260B1),
          _link(f260Loop),
        ]) {
          expect(_hasFocus(tester, key), isFalse, reason: '$key not focused');
        }
        final px = await _capture(tester);
        for (final key in [
          f260Move(f260Loop, f260B2),
          f260Move(f260Economy, f260B1),
        ]) {
          expect(
            _blank(px, _rect(tester, key), OmColors.surface1),
            isTrue,
            reason: '$key stays hidden',
          );
        }
      },
    );
  });

  group('failure (AC13)', () {
    testWidgets(
      'a failed fix keeps its row buttons visible until the error is dismissed',
      (tester) async {
        final s = await _pump398(tester);
        s.server.nextWriteError = FakeMemexCli.error('internal', 'boom');
        final rowKey = f260Row(f260Loop, f260B1);

        await f260Tap(tester, f260Remove(f260Loop, f260B1));
        await f260Tap(tester, f260Confirm);
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        expect(f260Error, findsOneWidget);

        var px = await _capture(tester);
        _expectRowBg(px, _rect(tester, rowKey), OmColors.surface2, 'failed');
        for (final key in [
          f260Move(f260Loop, f260B1),
          f260Remove(f260Loop, f260B1),
        ]) {
          expect(
            _drawn(px, _rect(tester, key), OmColors.surface2),
            isTrue,
            reason: '$key stays visible after the failure',
          );
          expect(_enabled(tester, key), isTrue);
        }
        expect(
          _blank(
            px,
            _rect(tester, f260Move(f260Loop, f260B2)),
            OmColors.surface1,
          ),
          isTrue,
          reason: 'other rows stay at rest',
        );

        await f260Tap(tester, const Key('inline-error-dismiss'));
        FocusManager.instance.primaryFocus?.unfocus();
        await pumpFrames(tester);
        expect(f260Error, findsNothing);
        expect(s.removes, hasLength(1));
        px = await _capture(tester);
        _expectRowBg(px, _rect(tester, rowKey), OmColors.surface1, 'dismissed');
        expect(
          _blank(
            px,
            _rect(tester, f260Move(f260Loop, f260B1)),
            OmColors.surface1,
          ),
          isTrue,
          reason: 'dismissed: the row is at rest again',
        );
      },
    );

    testWidgets(
      'the inline error sits under its row indented 36 px with the rail interrupted beside it',
      (tester) async {
        final s = await _pump398(tester);
        s.server.nextWriteError = FakeMemexCli.error(
          'internal',
          'topic note not found: Level Design',
        );

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await _confirm(tester, target: f260Level);
        expect(s.moves, hasLength(1));
        expect(f260Error, findsOneWidget);

        final row = _rect(tester, f260Row(f260Loop, f260B1));
        final next = _rect(tester, f260Row(f260Loop, f260B2));
        final err = tester.getRect(f260Error);
        expect(err.left, closeTo(row.left + 36, 0.5), reason: '36 px indent');
        expect(err.right, closeTo(row.right - 10, 0.5), reason: '10 px right');
        expect(
          err.top,
          closeTo(row.bottom + 2, 0.5),
          reason: 'directly under the row, outside it, 2 px down',
        );
        expect(next.top, greaterThanOrEqualTo(err.bottom - 0.5));
        expect(
          find.descendant(
            of: f260Error,
            matching: find.byKey(const Key('inline-error-dismiss')),
          ),
          findsOneWidget,
        );
        final px = await _capture(tester);
        final line3 = Color.alphaBlend(OmColors.line3, OmColors.surface1);
        expect(
          _hsum(px, err.center.dy, 16, 27, line3),
          lessThan(0.2),
          reason: 'no rail beside the error',
        );
        expect(
          _hsum(px, next.top + 3.5, 16, 27, line3),
          closeTo(1, 0.3),
          reason: 'the rail goes on at the next row',
        );
      },
    );

    testWidgets(
      'the next fix on a failed row clears its error when it starts',
      (tester) async {
        final s = await _pump398(tester);
        s.server.nextWriteError = FakeMemexCli.error('internal', 'boom');

        await f260Tap(tester, f260Move(f260Loop, f260B1));
        await _confirm(tester, target: f260Economy);
        expect(f260Error, findsOneWidget);

        s.feedback.gate('removeBlock');
        await f260Tap(tester, f260Remove(f260Loop, f260B1));
        await f260Tap(tester, f260Confirm);
        expect(s.removes, hasLength(1));
        expect(f260Error, findsNothing, reason: 'cleared as the fix starts');
        expect(
          _inRow(f260Row(f260Loop, f260B1), find.text('Removing')),
          findsOneWidget,
        );
        s.feedback.gates['removeBlock']!.single.complete();
        await pumpFrames(tester);
      },
    );
  });

  group('the fixes as WI 260 built them (AC14)', () {
    testWidgets(
      'a keyboard run Move to with a Why calls moveBlock once bumps the revision once and rebases the open daily note',
      (tester) async {
        final f = await pumpF260(tester);
        final rev = RevisionCounter(f.h);
        final before = f.db.getNote(f260DailyId)!.version;

        await _focusOn(tester, f260Move(f260Loop, f260B1));
        await _enter(tester);
        expect(find.byKey(f260Confirm), findsOneWidget);
        await f260Tap(tester, f260Option(f260Sleep));
        await f260TypeWhy(tester, 'this is about rest');
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);

        expect(f.moves, hasLength(1));
        final args = f.moves.single.args;
        expect(args['fromTopicNoteId'], f260Loop);
        expect(args['toTopicNoteId'], f260Sleep);
        expect(args['blockId'], f260B1);
        expect(args['date'], f260Date);
        expect(args['note'], 'this is about rest');
        expect(f.cli.callsFor('excerpt move'), hasLength(1));
        expect(rev.bumps, 1);
        expect(find.byKey(f260Row(f260Sleep, f260B1)), findsOneWidget);
        final after = f.db.getNote(f260DailyId)!.version;
        expect(after, greaterThan(before), reason: 'the chip bumped the day');
        expect(
          f.h.read(editorControllerProvider).lastSavedVersion,
          after,
          reason: 'the editor rebased on the new version (D23)',
        );
      },
    );

    testWidgets(
      'a keyboard run Remove with Cancel or Esc writes nothing and a confirmed one removes once',
      (tester) async {
        final f = await pumpF260(tester);
        final remove = f260Remove(f260Loop, f260B1);

        await _focusOn(tester, remove);
        await _enter(tester);
        await f260Tap(tester, f260Cancel);
        await _focusOn(tester, remove);
        await _enter(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await pumpFrames(tester);
        expect(f.writes, isEmpty);

        await _focusOn(tester, remove);
        await _enter(tester);
        await f260Tap(tester, f260Confirm);
        await pumpFrames(tester);
        expect(f.removes, hasLength(1));
        expect(f.removes.single.args['topicNoteId'], f260Loop);
        expect(f.cli.callsFor('excerpt remove-block'), hasLength(1));
        expect(find.byKey(f260Row(f260Loop, f260B1)), findsNothing);
        expect(find.byKey(f260NotFiledRow(f260B1)), findsOneWidget);
      },
    );
  });

  group('scale and width (AC15)', () {
    testWidgets(
      'at 1.5x in the 340 px panel the fix buttons stay 24 px and centred on the preview first line',
      (tester) async {
        await _pump398(
          tester,
          scale: 1.5,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [
                (f260B1, _shortText),
                (f260B2, _solidPreview),
              ]),
            ],
            [(f260N1, 'call')],
          ),
        );
        expect(tester.takeException(), isNull);

        for (final (rowKey, text, buttons) in [
          (
            f260Row(f260Loop, f260B1),
            _shortText,
            [f260Move(f260Loop, f260B1), f260Remove(f260Loop, f260B1)],
          ),
          (
            f260Row(f260Loop, f260B2),
            _solidPreview,
            [f260Move(f260Loop, f260B2), f260Remove(f260Loop, f260B2)],
          ),
          (f260NotFiledRow(f260N1), 'call', [f260FileIn(f260N1)]),
        ]) {
          final row = _rect(tester, rowKey);
          final line = _firstLineCentre(tester, _preview(rowKey, text));
          for (final key in buttons) {
            final r = _rect(tester, key);
            expect(r.size, const Size(24, 24), reason: '$key stays 24 px');
            expect(
              r.center.dy,
              closeTo(line, 1),
              reason: '$key centred on the first line at 1.5x',
            );
            expect(r.right, lessThanOrEqualTo(row.right - 10 + 0.5));
            expect(tester.widget<Icon>(_iconIn(key)).size, 13);
          }
          expect(
            tester.getRect(_preview(rowKey, text)).right,
            lessThanOrEqualTo(_rect(tester, buttons.first).left + 0.5),
          );
        }
        expect(
          _para(
            tester,
            _preview(f260Row(f260Loop, f260B2), _solidPreview),
          ).maxLines,
          2,
        );
        final mouse = await _mouseAt(
          tester,
          tester.getCenter(find.byKey(f260Row(f260Loop, f260B2))),
        );
        expect(tester.takeException(), isNull, reason: 'revealed at 1.5x');
        await mouse.moveTo(_away);
        await pumpFrames(tester);
      },
    );

    testWidgets(
      'at 280 px the fix buttons keep their column beside the wrapping preview',
      (tester) async {
        await _pump398(
          tester,
          width: 280,
          server: _day(
            [
              F260Topic(f260Loop, 'Player Loop', [
                (f260B1, 'check the jump arc against the ledge height'),
              ]),
            ],
            [(f260N1, f260N1Text)],
          ),
        );
        expect(tester.takeException(), isNull);

        final rowKey = f260Row(f260Loop, f260B1);
        const text = 'check the jump arc against the ledge height';
        final row = _rect(tester, rowKey);
        final move = _rect(tester, f260Move(f260Loop, f260B1));
        final remove = _rect(tester, f260Remove(f260Loop, f260B1));
        final preview = tester.getRect(_preview(rowKey, text));
        expect(remove.right, closeTo(row.right - 10, 0.5));
        expect(move.left, closeTo(row.right - 10 - 50, 0.5));
        expect(preview.width, closeTo(178, 0.5), reason: 'board: 178 wide');
        expect(
          preview.height,
          greaterThan(12.5 * 1.45 + 1),
          reason: 'the preview wraps',
        );
        expect(
          move.center.dy,
          closeTo(_firstLineCentre(tester, _preview(rowKey, text)), 1),
        );
        final fileIn = _rect(tester, f260FileIn(f260N1));
        expect(fileIn.right, closeTo(280 - 10, 0.5));
        expect(fileIn.right, lessThanOrEqualTo(280));
      },
    );
  });
}
