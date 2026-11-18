// WI #68 (Spec #58 O2): the right panel's Outline tab, design B "Mono tree".
//
// Numbers come from the design pack (design/54-heading-toc/packs/68.md) and
// the lead's rulings in the WI body: rows mono 12 with an 18 px line and 4 px
// vertical padding (26 px at text scale 1.0, 35 px at 1.5), padding 16 left
// and right, a tag column round(22 x scale) wide, a 14 px indent step, 1 px
// line2 guides at x = 16 + tagW + 14k + 4, depth 0 fg0 w700 and other rows
// fg1 w400; current = accent w500 text, accentSoft tag and a 2 px accent bar
// on the nearest guide (depth 0: x = 16 + tagW - 6), no fill; hover = a
// surface3 fill; focus = a 2 px accent ring inside the row; the tooltip is a
// surface4 box 307 wide, 16 px in from the row and 6 px below it.
//
// This file registers the bundled JetBrains Mono and Inter Tight files under
// the family names OmType asks for (as version_label_fit_test.dart does), so
// widths are the shipped fonts' and the 340 px panel fits at text scale 1.0.
// Fills, guides, bars and rings are checked on glyph-free pixels of a capture
// of the whole app. Note content is invented. Test names use no apostrophes.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/outline.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/outline_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart' show VirtualTodayTab;
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/outline/outline_tab.dart';
import 'package:open_memex_app/src/widgets/panel_placeholder_tab.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/links_seeds.dart';

// ------------------------------------------------------------------ fixture

/// An invented garden plan: the design pack's 16 sample entries, with prose
/// between some of them.
const _wi68Garden = '''# Garden planning 2026
A plan for the beds this year.
## Goals for the season
#### Stretch goal: a second water butt
## Beds and layout
### North bed
### South bed
#### Soil test results
pH 6.5 and plenty of worms.
### Notes
## Planting calendar
### Spring
### Summer
#### Watering schedule when the rain barrel runs dry in late July and August
### Notes
## Seeds to order from **Hillside Seeds** and [[Seed swap 2026|the swap]]
## Pest log #organic
## Budget
''';

/// The pack's sample entries as (level, depth, text), in order.
const _wi68Expected = <(int, int, String)>[
  (1, 0, 'Garden planning 2026'),
  (2, 1, 'Goals for the season'),
  (4, 2, 'Stretch goal: a second water butt'),
  (2, 1, 'Beds and layout'),
  (3, 2, 'North bed'),
  (3, 2, 'South bed'),
  (4, 3, 'Soil test results'),
  (3, 2, 'Notes'),
  (2, 1, 'Planting calendar'),
  (3, 2, 'Spring'),
  (3, 2, 'Summer'),
  (
    4,
    3,
    'Watering schedule when the rain barrel runs dry in late July and August',
  ),
  (3, 2, 'Notes'),
  (2, 1, 'Seeds to order from Hillside Seeds and the swap'),
  (2, 1, 'Pest log #organic'),
  (2, 1, 'Budget'),
];

const _wi68Long = 11;
const _wi68NoteId = 'n68-garden';
const _wi68OtherId = 'n68-shed';
const _wi68Shed = '# Shed repairs\n## Roof felt\nPatch the corner.\n';
const _wi68Prose = 'Just a line of prose about compost.\n';

const _wi68NoNote = 'open a note to see its outline.';
const _wi68NoHeadings = 'no headings yet — start a line with # to add one.';
const _wi68Eyebrow = 'OUTLINE · THIS NOTE';
const _wi68Keycap = '⌘⇧O';

/// The garden entries, computed at run time from the O1 function.
List<OutlineEntry> _wi68Entries() {
  final entries = outlineEntries(_wi68Garden);
  expect(
    [for (final e in entries) (e.level, e.depth, e.text)],
    _wi68Expected,
    reason: 'fixture: the O1 entries of the garden note',
  );
  return entries;
}

// ------------------------------------------------------------------ fonts

const _wi68Weights = {
  100: 'Thin',
  200: 'ExtraLight',
  300: 'Light',
  400: 'Regular',
  500: 'Medium',
  600: 'SemiBold',
  700: 'Bold',
  800: 'ExtraBold',
  900: 'Black',
};

/// Registers each bundled upright weight of [family] under the name
/// google_fonts gives its TextStyles (`<family>_regular`, `<family>_500`).
Future<void> _wi68LoadFamily(String family) async {
  for (final MapEntry(key: weight, value: word) in _wi68Weights.entries) {
    final file = File('assets/google_fonts/$family-$word.ttf');
    if (!file.existsSync()) continue;
    final name = weight == 400 ? '${family}_regular' : '${family}_$weight';
    final loader = FontLoader(name)
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
}

// ------------------------------------------------------------------ pixels

const _wi68ShotKey = Key('wi68-shot');

class _Wi68Shot {
  _Wi68Shot(this.bytes, this.width);
  final ByteData bytes;
  final int width;

  Color at(double x, double y) {
    final i = (y.floor() * width + x.floor()) * 4;
    return Color.fromARGB(
      bytes.getUint8(i + 3),
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
    );
  }
}

Future<_Wi68Shot> _wi68Capture(WidgetTester tester) async {
  final element = tester.element(find.byKey(_wi68ShotKey));
  final shot = await tester.runAsync(() async {
    final image = await captureImage(element);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = image.width;
    image.dispose();
    return _Wi68Shot(data!, w);
  });
  return shot!;
}

List<int> _wi68Rgb(Color c) => [
  (c.r * 255).round(),
  (c.g * 255).round(),
  (c.b * 255).round(),
];

/// A pixel within 3 per channel of [c] (opaque colours, or [c] already
/// composited).
Matcher _wi68Px(Color c) {
  final want = _wi68Rgb(c);
  return predicate<Color>((got) {
    final g = _wi68Rgb(got);
    for (var i = 0; i < 3; i++) {
      if ((g[i] - want[i]).abs() > 3) return false;
    }
    return true;
  }, 'a pixel near rgb$want');
}

Color _wi68Over(Color fg, Color bg) => Color.alphaBlend(fg, bg);

// ------------------------------------------------------------------ contrast

double _wi68Lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _wi68Contrast(Color a, Color b) {
  final la = _wi68Lum(a);
  final lb = _wi68Lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

// ------------------------------------------------------------------ finders

Finder _wi68Row(int i) => find.byKey(Key('outline-entry-$i'));
Finder get _wi68List => find.byKey(const Key('outline-list'));

/// [text] under [parent] and drawn inside its box (a hover tooltip may be
/// built under the row while it paints in the overlay below it).
Finder _wi68In(Finder parent, String text) {
  final inner = find.descendant(of: parent, matching: find.text(text));
  return find.byElementPredicate((e) {
    if (!inner.evaluate().contains(e)) return false;
    final p = parent.evaluate().single.renderObject! as RenderBox;
    final b = e.renderObject! as RenderBox;
    final box = p.localToGlobal(Offset.zero) & p.size;
    return box.contains(b.localToGlobal(b.size.center(Offset.zero)));
  });
}

RenderParagraph _wi68Para(WidgetTester tester, Finder f) =>
    tester.renderObject<RenderParagraph>(f);

TextStyle _wi68Style(WidgetTester tester, Finder f) {
  final span = _wi68Para(tester, f).text;
  final style = span.style;
  if (style?.color != null) return style!;
  TextStyle? found;
  span.visitChildren((child) {
    if (child.style?.color != null) {
      found = child.style;
      return false;
    }
    return true;
  });
  return found ?? style!;
}

/// The row's text paragraph for entry [i].
Finder _wi68Text(int i) => _wi68In(_wi68Row(i), _wi68Expected[i].$3);

/// The row's level tag paragraph for entry [i].
Finder _wi68Tag(int i) => _wi68In(_wi68Row(i), 'h${_wi68Expected[i].$1}');

/// Every paragraph whose plain text is [text], with its global rect.
List<Rect> _wi68ParagraphRects(WidgetTester tester, String text) => [
  for (final e
      in find
          .byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == text,
          )
          .evaluate())
    () {
      final box = e.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }(),
];

/// The semantics nodes labelled exactly [label], with their global rects.
List<(SemanticsNode, Rect)> _wi68NodesLabelled(
  WidgetTester tester,
  String label,
) {
  var root = tester.getSemantics(find.byType(MaterialApp));
  while (root.parent != null) {
    root = root.parent!;
  }
  final out = <(SemanticsNode, Rect)>[];
  void walk(SemanticsNode n, Matrix4 parent) {
    final m = n.transform == null ? parent : parent.multiplied(n.transform!);
    final r = MatrixUtils.transformRect(m, n.rect);
    final d = n.getSemanticsData();
    if (!n.isInvisible && !n.isMergedIntoParent && d.label == label) {
      out.add((n, r));
    }
    n.visitChildren((c) {
      walk(c, m);
      return true;
    });
  }

  final dpr = tester.view.devicePixelRatio;
  walk(root, Matrix4.diagonal3Values(1 / dpr, 1 / dpr, 1));
  return out;
}

// ------------------------------------------------------------------ pumps

/// [OutlineList] alone, top-left in a [size] box on a surface1 page, at text
/// scale [scale], the whole app inside a RepaintBoundary for captures.
Future<void> _wi68PumpList(
  WidgetTester tester, {
  required List<OutlineEntry> entries,
  int? current,
  int? focused,
  void Function(OutlineEntry)? onActivate,
  double scale = 1.0,
  Size size = const Size(339, 600),
}) async {
  tester.view.physicalSize = const Size(800, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _wi68ShotKey,
      child: MaterialApp(
        theme: buildOmTheme(),
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: OmColors.surface1,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: OutlineList(
                entries: entries,
                currentIndex: current,
                focusedIndex: focused,
                onActivate: onActivate,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// A notes domain whose `getNote` waits on [gate].
class _Wi68GatedNotes extends LocalNotesAccess {
  _Wi68GatedNotes({
    required super.vaultPath,
    super.db,
    required this.gate,
    this.readError,
  });
  final Wi90Gate gate;

  /// When set, `getNote` fails with it once the gate opens.
  final Object? readError;

  @override
  Future<Note?> getNote(String id) async {
    await gate.wait;
    if (readError != null) throw readError!;
    return super.getNote(id);
  }
}

/// The real editor controller, plus a way to change its text or status the
/// way typing and saves do, with no save debounce.
class _Wi68Editor extends EditorController {
  _Wi68Editor(super.ref);

  void type(String text) =>
      state = state.copyWith(contentMd: text, status: SaveStatus.dirty);

  /// A state change that keeps the text (a save going out).
  void touch() => state = state.copyWith(status: SaveStatus.saving);
}

class _Wi68Panel {
  _Wi68Panel(this.container, this.db, this.gate, this.roles, this.texts);
  final ProviderContainer container;
  final FakeVaultDb db;
  final Wi90Gate gate;
  final List<String?> roles;
  final List<String> texts;

  /// How many times the Outline computed entries.
  int get computed => texts.length;
  _Wi68Editor get editor =>
      container.read(editorControllerProvider.notifier) as _Wi68Editor;

  /// The editor loads [id] from the vault, as the note editor does on
  /// hydrate.
  void load(String id) => editor.loadNote(db.getNote(id));
  void select(String? id) =>
      container.read(selectedNoteIdProvider.notifier).state = id;
  void show(RightPanelTab tab) =>
      container.read(rightPanelTabProvider.notifier).state = tab;
}

/// The right panel (340 wide) in an 800 x 1000 window on a vault holding the
/// garden note and the shed note, with [noteId] selected. With [load] the
/// editor holds that note before the first frame. [tab] null keeps the
/// launch default.
Future<_Wi68Panel> _wi68PumpPanel(
  WidgetTester tester, {
  String? noteId = _wi68NoteId,
  String content = _wi68Garden,
  String? role,
  VaultRef vault = const LocalVaultRef('/tmp/om-68-vault'),
  bool gateOpen = true,
  RightPanelTab? tab = RightPanelTab.outline,
  double scale = 1.0,
  bool load = true,
  Object? readError,
}) async {
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  db.seedNote(
    id: _wi68NoteId,
    title: 'Garden planning',
    content: content,
    role: role,
  );
  db.seedNote(id: _wi68OtherId, title: 'Shed repairs', content: _wi68Shed);
  final gate = Wi90Gate(open: gateOpen);
  final roles = <String?>[];
  final texts = <String>[];
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      selectedNoteIdProvider.overrideWith((_) => noteId),
      if (tab != null) rightPanelTabProvider.overrideWith((_) => tab),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: '/unused-68',
          db: db,
          notes: _Wi68GatedNotes(
            vaultPath: '/unused-68',
            db: db,
            gate: gate,
            readError: readError,
          ),
        ),
      ),
      editorControllerProvider.overrideWith(_Wi68Editor.new),
      outlineEntriesFnProvider.overrideWithValue((md, {role}) {
        roles.add(role);
        texts.add(md);
        return outlineEntries(md, role: role);
      }),
    ],
  );
  addTearDown(container.dispose);
  final panel = _Wi68Panel(container, db, gate, roles, texts);
  if (load && noteId != null) panel.load(noteId);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _wi68ShotKey,
        child: MaterialApp(
          theme: buildOmTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: OmColors.surface1,
            body: Align(
              alignment: Alignment.topRight,
              child: RightPanel(onClose: () {}),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return panel;
}

/// Every Text data under the Outline tab, in tree order.
List<String> _wi68TabTexts(WidgetTester tester) => [
  for (final e
      in find
          .descendant(of: find.byType(OutlineTab), matching: find.byType(Text))
          .evaluate())
    (e.widget as Text).data ?? (e.widget as Text).textSpan!.toPlainText(),
];

Finder get _wi68KeycapFinder =>
    find.byWidgetPredicate((w) => w is OmKbd && w.text == _wi68Keycap);

Future<TestGesture> _wi68Mouse(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: const Offset(790, 890));
  addTearDown(g.removePointer);
  return g;
}

/// Moves the mouse away and lets tooltip timers finish.
Future<void> _wi68MouseAway(WidgetTester tester, TestGesture g) async {
  await g.moveTo(const Offset(790, 890));
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  holdFontFetches();

  setUpAll(() async {
    await _wi68LoadFamily('JetBrainsMono');
    await _wi68LoadFamily('InterTight');
  });

  // ------------------------------------------------------------- tab row
  group('tab row', () {
    testWidgets(
      'the tab row shows connections echoes outline activity in that order with the listTree icon on outline and connections selected at launch',
      (tester) async {
        await _wi68PumpPanel(tester, tab: null);

        final labels = ['connections', 'echoes', 'outline', 'activity'];
        final xs = [for (final l in labels) tester.getTopLeft(find.text(l)).dx];
        for (var i = 1; i < xs.length; i++) {
          expect(xs[i], greaterThan(xs[i - 1]), reason: '${labels[i]} order');
        }
        final chip = find.byKey(const Key('outline-tab-chip'));
        expect(chip, findsOneWidget);
        expect(
          find.descendant(
            of: chip,
            matching: find.byIcon(LucideIcons.listTree),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chip, matching: find.text('outline')),
          findsOneWidget,
        );
        expect(
          _wi68Style(tester, find.text('connections')).color,
          OmColors.fg0,
          reason: 'connections is the selected chip',
        );
        for (final l in ['echoes', 'outline', 'activity']) {
          expect(_wi68Style(tester, find.text(l)).color, OmColors.fg2);
        }
      },
    );

    testWidgets('tapping the outline chip shows the outline tab', (
      tester,
    ) async {
      final p = await _wi68PumpPanel(tester, tab: null);

      await tester.tap(find.byKey(const Key('outline-tab-chip')));
      await pumpFrames(tester);

      expect(p.container.read(rightPanelTabProvider), RightPanelTab.outline);
      expect(_wi68Style(tester, find.text('outline')).color, OmColors.fg0);
      expect(find.byKey(const Key('outline-list')), findsOneWidget);
    });

    testWidgets(
      'at text scale 1.0 the four chips fit the 340 px panel unscaled with 6 px padding and a 4 px icon gap',
      (tester) async {
        await _wi68PumpPanel(tester, tab: null);

        expect(tester.takeException(), isNull);
        final labels = ['connections', 'echoes', 'outline', 'activity'];
        final icons = [
          LucideIcons.workflow,
          LucideIcons.history,
          LucideIcons.listTree,
          LucideIcons.activity,
        ];
        for (var i = 0; i < 4; i++) {
          final label = find.text(labels[i]);
          final scale =
              tester.getRect(label).width / tester.getSize(label).width;
          expect(scale, closeTo(1.0, 0.001), reason: '${labels[i]} unscaled');
          final icon = tester.getRect(find.byIcon(icons[i]));
          expect(
            tester.getRect(label).left - icon.right,
            closeTo(4, 0.01),
            reason: '${labels[i]} icon to label gap',
          );
          if (i > 0) {
            // label right + 6 padding + 2 between chips + 6 padding.
            expect(
              icon.left - tester.getRect(find.text(labels[i - 1])).right,
              closeTo(14, 0.01),
              reason: '${labels[i - 1]} to ${labels[i]}',
            );
          }
        }
        final chip = find.byKey(const Key('outline-tab-chip'));
        expect(
          tester.getRect(find.byIcon(LucideIcons.listTree)).left -
              tester.getRect(chip).left,
          closeTo(6, 0.01),
          reason: 'chip left padding',
        );
        final panel = tester.getRect(find.byType(RightPanel));
        expect(
          tester.getRect(find.text('activity')).right,
          lessThan(tester.getRect(find.byIcon(LucideIcons.x)).left),
        );
        expect(panel.width, 340);
      },
    );

    testWidgets(
      'at text scale 1.5 the four chips scale down together and nothing overflows',
      (tester) async {
        await _wi68PumpPanel(tester, tab: RightPanelTab.outline, scale: 1.5);

        expect(tester.takeException(), isNull, reason: 'nothing overflows');
        final scales = [
          for (final l in ['connections', 'echoes', 'outline', 'activity'])
            tester.getRect(find.text(l)).width /
                tester.getSize(find.text(l)).width,
        ];
        expect(scales.first, lessThan(1.0));
        for (final s in scales) {
          expect(s, closeTo(scales.first, 0.001), reason: 'one scale');
        }
        expect(find.byKey(const Key('outline-tab-chip')), findsOneWidget);
        expect(
          tester.getRect(find.text('activity')).right,
          lessThanOrEqualTo(tester.getRect(find.byIcon(LucideIcons.x)).left),
        );
      },
    );
  });

  // ------------------------------------------------------------- rows
  group('rows', () {
    testWidgets(
      'the outline list shows one row per entry in order with its level tag and plain text',
      (tester) async {
        final entries = _wi68Entries();
        await _wi68PumpList(tester, entries: entries);

        expect(_wi68List, findsOneWidget);
        double? lastTop;
        for (var i = 0; i < entries.length; i++) {
          expect(_wi68Row(i), findsOneWidget, reason: 'row $i');
          expect(_wi68Tag(i), findsOneWidget, reason: 'tag of row $i');
          expect(_wi68Text(i), findsOneWidget, reason: 'text of row $i');
          final top = tester.getRect(_wi68Row(i)).top;
          if (lastTop != null) expect(top, greaterThan(lastTop));
          lastTop = top;
        }
        expect(_wi68Row(entries.length), findsNothing);
        expect(find.textContaining('**'), findsNothing);
        expect(find.textContaining('[['), findsNothing);
      },
    );

    testWidgets(
      'rows are 26 px high and full width at text scale 1.0 after 6 px of list padding',
      (tester) async {
        final entries = _wi68Entries();
        await _wi68PumpList(tester, entries: entries);

        final list = tester.getRect(_wi68List);
        for (var i = 0; i < entries.length; i++) {
          final row = tester.getRect(_wi68Row(i));
          expect(row.height, closeTo(26, 0.01), reason: 'row $i height');
          expect(row.width, closeTo(339, 0.01), reason: 'row $i width');
          expect(row.top, closeTo(list.top + 6 + 26 * i, 0.01));
        }
      },
    );

    testWidgets(
      'each row text starts after a 22 px tag column and 14 px per depth',
      (tester) async {
        final entries = _wi68Entries();
        await _wi68PumpList(tester, entries: entries);

        for (var i = 0; i < entries.length; i++) {
          final row = tester.getRect(_wi68Row(i));
          expect(
            tester.getTopLeft(_wi68Tag(i)).dx,
            closeTo(row.left + 16, 0.01),
            reason: 'tag of row $i',
          );
          expect(
            tester.getTopLeft(_wi68Text(i)).dx,
            closeTo(row.left + 16 + 22 + 14 * entries[i].depth, 0.01),
            reason: 'text of row $i at depth ${entries[i].depth}',
          );
        }
      },
    );

    testWidgets('every row uses a 12 px font whatever its level', (
      tester,
    ) async {
      final entries = _wi68Entries();
      await _wi68PumpList(tester, entries: entries);

      for (var i = 0; i < entries.length; i++) {
        final text = _wi68Style(tester, _wi68Text(i));
        expect(text.fontSize, 12, reason: 'row $i (h${entries[i].level})');
        expect(text.height, 1.5);
        final tag = _wi68Style(tester, _wi68Tag(i));
        expect(tag.fontSize, 10, reason: 'tag of row $i');
        expect(tag.color, OmColors.fg2, reason: 'tag of row $i');
      }
    });

    testWidgets(
      'depth zero rows are fg0 bold and deeper rows fg1 regular keyed on depth not level',
      (tester) async {
        final entries = outlineEntries(
          '## Alpha bed\nSome prose.\n### Beta row\n## Gamma path\n',
        );
        expect([for (final e in entries) e.depth], [0, 1, 0]);
        await _wi68PumpList(tester, entries: entries);

        for (final (i, text, color, weight) in [
          (0, 'Alpha bed', OmColors.fg0, FontWeight.w700),
          (1, 'Beta row', OmColors.fg1, FontWeight.w400),
          (2, 'Gamma path', OmColors.fg0, FontWeight.w700),
        ]) {
          final style = _wi68Style(tester, _wi68In(_wi68Row(i), text));
          expect(style.color, color, reason: text);
          expect(style.fontWeight, weight, reason: text);
        }
      },
    );

    testWidgets(
      'a long entry is one line ending in an ellipsis and the row stays 26 px',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries());

        final para = _wi68Para(tester, _wi68Text(_wi68Long));
        expect(para.maxLines, 1);
        expect(para.overflow, TextOverflow.ellipsis);
        expect(para.didExceedMaxLines, isTrue);
        expect(tester.getRect(_wi68Row(_wi68Long)).height, closeTo(26, 0.01));
        expect(
          tester.getRect(_wi68Text(_wi68Long)).right,
          lessThanOrEqualTo(tester.getRect(_wi68Row(_wi68Long)).right - 16),
        );
      },
    );

    testWidgets(
      'indent guides are 1 px line2 bars the full row height at each depth step',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries());
        final shot = await _wi68Capture(tester);
        final guide = _wi68Over(OmColors.line2, OmColors.surface1);

        // Row 6 `Soil test results` is depth 3: guides at k = 0, 1, 2.
        final row = tester.getRect(_wi68Row(6));
        for (final k in [0, 1, 2]) {
          final x = row.left + 16 + 22 + 14 * k + 4;
          for (final y in [row.top, row.center.dy, row.bottom - 1]) {
            expect(shot.at(x, y), _wi68Px(guide), reason: 'guide $k at y $y');
          }
          expect(shot.at(x + 1, row.center.dy), _wi68Px(OmColors.surface1));
          expect(shot.at(x - 1, row.center.dy), _wi68Px(OmColors.surface1));
        }
        // Row 0 is depth 0: no guide.
        final top = tester.getRect(_wi68Row(0));
        for (final k in [0, 1, 2]) {
          expect(
            shot.at(top.left + 16 + 22 + 14 * k + 4, top.top + 1),
            _wi68Px(OmColors.surface1),
            reason: 'no guide on the depth 0 row',
          );
        }
      },
    );
  });

  // ------------------------------------------------------------- tooltip
  group('tooltip', () {
    testWidgets(
      'hovering a long entry shows a surface4 tooltip with the full text wrapping in a 307 px box 16 px in and 6 px below the row',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries());
        final full = _wi68Expected[_wi68Long].$3;
        final row = tester.getRect(_wi68Row(_wi68Long));
        expect(
          _wi68ParagraphRects(tester, full).where((r) => r.top >= row.bottom),
          isEmpty,
          reason: 'no tooltip before hover',
        );

        final mouse = await _wi68Mouse(tester);
        await mouse.moveTo(row.center);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        final tips = _wi68ParagraphRects(
          tester,
          full,
        ).where((r) => r.top >= row.bottom).toList();
        expect(tips, hasLength(1), reason: 'one tooltip below the row');
        final tip = tips.single;
        expect(tip.height, greaterThanOrEqualTo(32), reason: 'wraps');
        expect(tip.top, closeTo(row.bottom + 6 + 6, 1), reason: 'pad 6');
        expect(tip.left, closeTo(row.left + 16 + 8, 1), reason: 'pad 8');

        final tipText = find.byElementPredicate((e) {
          final w = e.widget;
          if (w is! RichText || w.text.toPlainText() != full) return false;
          final box = e.renderObject! as RenderBox;
          return box.localToGlobal(Offset.zero).dy >= row.bottom;
        });
        final style = _wi68Style(tester, tipText.first);
        expect(style.fontSize, 11);
        expect(style.color, OmColors.fg0);
        expect(
          _wi68Contrast(OmColors.fg0, OmColors.surface4),
          greaterThan(4.5),
        );

        final shot = await _wi68Capture(tester);
        final boxLeft = row.left + 16;
        final boxTop = row.bottom + 6;
        final y = tip.top + 1;
        expect(shot.at(boxLeft + 1, y), _wi68Px(OmColors.surface4));
        expect(shot.at(boxLeft - 1, y), isNot(_wi68Px(OmColors.surface4)));
        expect(shot.at(boxLeft + 307 - 2, y), _wi68Px(OmColors.surface4));
        expect(
          shot.at(boxLeft + 307 + 1, y),
          isNot(_wi68Px(OmColors.surface4)),
        );
        expect(shot.at(boxLeft + 100, boxTop + 1), _wi68Px(OmColors.surface4));
        expect(
          shot.at(boxLeft + 100, boxTop - 2),
          isNot(_wi68Px(OmColors.surface4)),
        );
        expect(
          shot.at(boxLeft, boxTop),
          isNot(_wi68Px(OmColors.surface4)),
          reason: 'rounded corner',
        );
        expect(boxLeft + 307, lessThanOrEqualTo(339), reason: 'in the panel');

        await _wi68MouseAway(tester, mouse);
      },
    );
  });

  // ------------------------------------------------------------- states
  group('row states', () {
    testWidgets(
      'a hovered row shows the surface3 fill and loses it when the mouse leaves',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries());
        final row = tester.getRect(_wi68Row(3));
        final other = tester.getRect(_wi68Row(4));
        final blank = Offset(row.right - 30, row.center.dy);

        var shot = await _wi68Capture(tester);
        expect(shot.at(blank.dx, blank.dy), _wi68Px(OmColors.surface1));

        final mouse = await _wi68Mouse(tester);
        await mouse.moveTo(row.center);
        await tester.pump();
        shot = await _wi68Capture(tester);
        expect(shot.at(blank.dx, blank.dy), _wi68Px(OmColors.surface3));
        expect(shot.at(row.left + 2, row.top + 1), _wi68Px(OmColors.surface3));
        expect(
          shot.at(other.right - 30, other.center.dy),
          _wi68Px(OmColors.surface1),
          reason: 'only the hovered row',
        );

        await mouse.moveTo(const Offset(790, 890));
        await tester.pump();
        shot = await _wi68Capture(tester);
        expect(shot.at(blank.dx, blank.dy), _wi68Px(OmColors.surface1));
        await tester.pump(const Duration(seconds: 3));
      },
    );

    testWidgets(
      'given currentIndex only that row shows accent text an accentSoft tag and a 2 px accent bar with no fill',
      (tester) async {
        final entries = _wi68Entries();
        await _wi68PumpList(tester, entries: entries, current: 10);

        final text = _wi68Style(tester, _wi68Text(10));
        expect(text.color, OmColors.accent);
        expect(text.fontWeight, FontWeight.w500);
        expect(_wi68Style(tester, _wi68Tag(10)).color, OmColors.accentSoft);
        for (var i = 0; i < entries.length; i++) {
          if (i == 10) continue;
          expect(
            _wi68Style(tester, _wi68Text(i)).color,
            isNot(OmColors.accent),
            reason: 'row $i is not current',
          );
          expect(_wi68Style(tester, _wi68Tag(i)).color, OmColors.fg2);
        }

        final shot = await _wi68Capture(tester);
        final row = tester.getRect(_wi68Row(10));
        // Depth 2: the bar is the k = 1 guide, 2 px wide, full height.
        final bar = row.left + 16 + 22 + 14 * 1 + 4;
        for (final y in [row.top, row.top + 2, row.bottom - 1]) {
          expect(shot.at(bar, y), _wi68Px(OmColors.accent), reason: 'bar');
          expect(shot.at(bar + 1, y), _wi68Px(OmColors.accent), reason: 'bar');
        }
        expect(shot.at(bar + 2, row.top + 2), _wi68Px(OmColors.surface1));
        expect(
          shot.at(row.left + 16 + 22 + 4, row.top + 2),
          _wi68Px(_wi68Over(OmColors.line2, OmColors.surface1)),
          reason: 'the k = 0 guide stays line2',
        );
        expect(
          shot.at(row.right - 30, row.center.dy),
          _wi68Px(OmColors.surface1),
          reason: 'no fill',
        );
        // Row 9 is depth 2 too and not current: its k = 1 guide is line2.
        final r9 = tester.getRect(_wi68Row(9));
        expect(
          shot.at(bar, r9.top + 2),
          _wi68Px(_wi68Over(OmColors.line2, OmColors.surface1)),
        );
      },
    );

    testWidgets(
      'a current depth zero row draws its accent bar 6 px left of the text column',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries(), current: 0);

        final shot = await _wi68Capture(tester);
        final row = tester.getRect(_wi68Row(0));
        final bar = row.left + 16 + 22 - 6;
        for (final y in [row.top, row.top + 2, row.bottom - 1]) {
          expect(shot.at(bar, y), _wi68Px(OmColors.accent));
          expect(shot.at(bar + 1, y), _wi68Px(OmColors.accent));
        }
        expect(shot.at(bar - 1, row.top + 2), _wi68Px(OmColors.surface1));
        expect(_wi68Style(tester, _wi68Text(0)).color, OmColors.accent);
      },
    );

    testWidgets('with no currentIndex no row is drawn as current', (
      tester,
    ) async {
      final entries = _wi68Entries();
      await _wi68PumpList(tester, entries: entries);

      for (var i = 0; i < entries.length; i++) {
        expect(_wi68Style(tester, _wi68Text(i)).color, isNot(OmColors.accent));
        expect(_wi68Style(tester, _wi68Tag(i)).color, OmColors.fg2);
      }
    });

    testWidgets(
      'given focusedIndex that row shows a 2 px square accent ring inside its bounds and its content does not move',
      (tester) async {
        final entries = _wi68Entries();
        await _wi68PumpList(tester, entries: entries, focused: 5);

        final shot = await _wi68Capture(tester);
        final row = tester.getRect(_wi68Row(5));
        final bx = row.right - 30;
        final cy = row.center.dy;
        final ring = _wi68Px(OmColors.accent);
        expect(shot.at(row.left, cy), ring);
        expect(shot.at(row.left + 1, cy), ring);
        expect(shot.at(row.left + 2, cy), _wi68Px(OmColors.surface1));
        expect(shot.at(row.right - 1, cy), ring);
        expect(shot.at(row.right - 2, cy), ring);
        expect(shot.at(row.right - 3, cy), _wi68Px(OmColors.surface1));
        expect(shot.at(bx, row.top), ring);
        expect(shot.at(bx, row.top + 1), ring);
        expect(shot.at(bx, row.top + 2), _wi68Px(OmColors.surface1));
        expect(shot.at(bx, row.bottom - 1), ring);
        expect(shot.at(bx, row.bottom - 2), ring);
        expect(shot.at(row.left, row.top), ring, reason: 'square corner');
        expect(shot.at(bx, row.top - 1), isNot(ring), reason: 'inside');

        expect(
          tester.getTopLeft(_wi68Text(5)).dx,
          closeTo(row.left + 16 + 22 + 14 * 2, 0.01),
        );
        expect(row.height, closeTo(26, 0.01));
        final r4 = tester.getRect(_wi68Row(4));
        expect(shot.at(r4.left, r4.center.dy), _wi68Px(OmColors.surface1));
        expect(_wi68Style(tester, _wi68Text(5)).color, isNot(OmColors.accent));
      },
    );

    testWidgets(
      'hover focus and current on one row all show and stay distinguishable',
      (tester) async {
        await _wi68PumpList(
          tester,
          entries: _wi68Entries(),
          current: 10,
          focused: 10,
        );
        final row = tester.getRect(_wi68Row(10));
        final mouse = await _wi68Mouse(tester);
        await mouse.moveTo(Offset(row.right - 30, row.center.dy));
        await tester.pump();

        final shot = await _wi68Capture(tester);
        expect(
          shot.at(row.right - 30, row.center.dy),
          _wi68Px(OmColors.surface3),
          reason: 'hover fill',
        );
        expect(shot.at(row.left, row.center.dy), _wi68Px(OmColors.accent));
        expect(shot.at(row.left + 1, row.center.dy), _wi68Px(OmColors.accent));
        expect(
          shot.at(row.left + 2, row.center.dy),
          _wi68Px(OmColors.surface3),
        );
        final bar = row.left + 16 + 22 + 14 + 4;
        expect(shot.at(bar, row.top + 3), _wi68Px(OmColors.accent));
        expect(shot.at(bar + 1, row.top + 3), _wi68Px(OmColors.accent));
        expect(
          shot.at(row.left + 16 + 22 + 4, row.top + 3),
          _wi68Px(_wi68Over(OmColors.line2, OmColors.surface3)),
          reason: 'the k = 0 guide over the fill',
        );
        expect(_wi68Style(tester, _wi68Text(10)).color, OmColors.accent);
        expect(_wi68Style(tester, _wi68Tag(10)).color, OmColors.accentSoft);
        expect(OmColors.surface3, isNot(OmColors.accent));

        await _wi68MouseAway(tester, mouse);
      },
    );

    testWidgets('hover and current without focus draw no ring', (tester) async {
      await _wi68PumpList(tester, entries: _wi68Entries(), current: 10);
      final row = tester.getRect(_wi68Row(10));
      final mouse = await _wi68Mouse(tester);
      await mouse.moveTo(Offset(row.right - 30, row.center.dy));
      await tester.pump();

      final shot = await _wi68Capture(tester);
      expect(shot.at(row.left, row.center.dy), _wi68Px(OmColors.surface3));
      expect(shot.at(row.right - 30, row.top), _wi68Px(OmColors.surface3));
      expect(
        shot.at(row.left + 16 + 22 + 14 + 4, row.top + 3),
        _wi68Px(OmColors.accent),
      );
      await _wi68MouseAway(tester, mouse);
    });
  });

  // ------------------------------------------------------------- activate
  group('activation', () {
    testWidgets(
      'a row shows the click cursor under a mouse and not after it leaves',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries());
        final mouse = await _wi68Mouse(tester);
        await mouse.moveTo(tester.getCenter(_wi68Text(3)));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.click,
        );
        await mouse.moveTo(const Offset(790, 890));
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          isNot(SystemMouseCursors.click),
        );
        await _wi68MouseAway(tester, mouse);
      },
    );

    testWidgets('tapping anywhere on a row calls onActivate with that entry', (
      tester,
    ) async {
      final entries = _wi68Entries();
      final got = <OutlineEntry>[];
      await _wi68PumpList(tester, entries: entries, onActivate: got.add);

      final row = tester.getRect(_wi68Row(3));
      for (final at in [
        Offset(row.left + 3, row.center.dy),
        tester.getCenter(_wi68Tag(3)),
        tester.getCenter(_wi68Text(3)),
        Offset(row.right - 3, row.top + 1),
      ]) {
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(got, [entries[3], entries[3], entries[3], entries[3]]);

      await tester.tap(_wi68Row(_wi68Long));
      await tester.pump(const Duration(milliseconds: 400));
      expect(got.last, entries[_wi68Long]);
      expect(got, hasLength(5));
    });

    testWidgets('a duplicate heading text activates its own entry', (
      tester,
    ) async {
      final entries = _wi68Entries();
      final got = <OutlineEntry>[];
      await _wi68PumpList(tester, entries: entries, onActivate: got.add);

      await tester.tap(_wi68Row(12));
      await tester.pump(const Duration(milliseconds: 400));
      expect(got.single, entries[12]);
      expect(got.single, isNot(entries[7]));
    });

    testWidgets(
      'tapping a row with no onActivate does nothing and throws nothing',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries());
        await tester.tap(_wi68Row(2));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        expect(_wi68Row(2), findsOneWidget);
      },
    );
  });

  // ------------------------------------------------------------- semantics
  group('semantics', () {
    testWidgets(
      'each row is a semantics button labelled with its plain text and only the current row is selected',
      (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await _wi68PumpList(tester, entries: _wi68Entries(), current: 10);

          for (final i in [0, 3, 6, 10, 11, 13]) {
            final text = _wi68Expected[i].$3;
            final nodes = _wi68NodesLabelled(tester, text);
            expect(nodes, hasLength(1), reason: 'one node for row $i');
            final (node, rect) = nodes.single;
            final d = node.getSemanticsData();
            expect(d.flagsCollection.isButton, isTrue, reason: 'row $i');
            expect(d.hasAction(SemanticsAction.tap), isTrue, reason: 'row $i');
            expect(
              d.flagsCollection.isSelected == ui.Tristate.isTrue,
              i == 10,
              reason: 'row $i selected',
            );
            expect(node.childrenCount, 0, reason: 'row $i is a leaf');
            final row = tester.getRect(_wi68Row(i));
            expect(rect.top, closeTo(row.top, 1), reason: 'row $i whole row');
            expect(rect.height, closeTo(row.height, 1));
            expect(rect.width, closeTo(row.width, 1));
          }
          expect(_wi68NodesLabelled(tester, 'h2'), isEmpty, reason: 'no tags');
        } finally {
          handle.dispose();
        }
      },
    );

    testWidgets('with no currentIndex no row is announced as selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        await _wi68PumpList(tester, entries: _wi68Entries());

        for (final i in [0, 10]) {
          final nodes = _wi68NodesLabelled(tester, _wi68Expected[i].$3);
          expect(nodes, hasLength(1));
          final d = nodes.single.$1.getSemanticsData();
          expect(d.flagsCollection.isButton, isTrue);
          expect(d.flagsCollection.isSelected, isNot(ui.Tristate.isTrue));
        }
      } finally {
        handle.dispose();
      }
    });
  });

  // ------------------------------------------------------------- scale 1.5
  group('text scale 1.5', () {
    testWidgets(
      'at text scale 1.5 rows are 35 px with a 33 px tag column and entries still ellipsize without overflow',
      (tester) async {
        final entries = _wi68Entries();
        await _wi68PumpList(
          tester,
          entries: entries,
          scale: 1.5,
          size: const Size(339, 800),
        );

        expect(tester.takeException(), isNull);
        for (var i = 0; i < entries.length; i++) {
          final row = tester.getRect(_wi68Row(i));
          expect(row.height, closeTo(35, 0.01), reason: 'row $i');
          expect(
            tester.getTopLeft(_wi68Text(i)).dx,
            closeTo(row.left + 16 + 33 + 14 * entries[i].depth, 0.01),
            reason: 'row $i text column',
          );
        }
        final para = _wi68Para(tester, _wi68Text(_wi68Long));
        expect(para.didExceedMaxLines, isTrue);
        expect(para.maxLines, 1);
        final seeds = _wi68Para(tester, _wi68Text(13));
        expect(seeds.maxLines, 1);
      },
    );
  });

  // ------------------------------------------------------------- scroll
  group('scroll', () {
    testWidgets('a long outline scrolls inside its box', (tester) async {
      await _wi68PumpList(
        tester,
        entries: _wi68Entries(),
        size: const Size(339, 200),
      );
      bool visible(int i) {
        final f = _wi68Row(i);
        if (f.evaluate().isEmpty) return false;
        final r = tester.getRect(f);
        return r.top >= 0 && r.bottom <= 200;
      }

      expect(visible(0), isTrue);
      expect(visible(15), isFalse);

      await tester.drag(_wi68List, const Offset(0, -500));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(visible(15), isTrue);
      expect(visible(0), isFalse);
    });
  });

  // ------------------------------------------------------------- contrast
  group('contrast', () {
    testWidgets(
      'every row text and tag colour is at least 4.5 to 1 on surface1 and on the surface3 hover fill',
      (tester) async {
        await _wi68PumpList(tester, entries: _wi68Entries(), current: 10);

        final paragraphs = find
            .descendant(of: _wi68List, matching: find.byType(RichText))
            .evaluate()
            .toList();
        expect(paragraphs.length, greaterThanOrEqualTo(32));
        for (final e in paragraphs) {
          final color = _wi68Style(tester, find.byWidget(e.widget)).color!;
          expect(color.a, 1.0, reason: 'opaque text');
          for (final bg in [OmColors.surface1, OmColors.surface3]) {
            expect(
              _wi68Contrast(color, bg),
              greaterThanOrEqualTo(4.5),
              reason: '$color on $bg',
            );
          }
        }
      },
    );
  });

  // ------------------------------------------------------------- tab states
  group('tab', () {
    testWidgets(
      'with a note open the outline tab lists its entries under the header with count and keycap',
      (tester) async {
        await _wi68PumpPanel(tester);

        expect(find.text(_wi68Eyebrow), findsOneWidget);
        expect(find.text('· 16'), findsOneWidget);
        expect(_wi68Style(tester, find.text('· 16')).color, OmColors.fg2);
        expect(_wi68KeycapFinder, findsOneWidget);
        final eyebrow = tester.getRect(find.text(_wi68Eyebrow));
        final keycap = tester.getRect(_wi68KeycapFinder);
        expect(keycap.center.dy, closeTo(eyebrow.center.dy, 2));
        expect(keycap.left, greaterThan(eyebrow.right));
        expect(keycap.right, lessThanOrEqualTo(800 - 16 + 0.5));
        for (var i = 0; i < 16; i++) {
          expect(_wi68Text(i), findsOneWidget, reason: 'row $i');
        }
        expect(
          tester.getRect(_wi68List).top,
          greaterThan(eyebrow.bottom),
          reason: 'the list sits under the header',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'with no note open the outline tab shows the no note copy under the header with the keycap and no count or subtitle',
      (tester) async {
        await _wi68PumpPanel(tester, noteId: null);

        expect(_wi68TabTexts(tester).toSet(), {
          _wi68Eyebrow,
          _wi68Keycap,
          _wi68NoNote,
        });
        expect(_wi68Style(tester, find.text(_wi68NoNote)).color, OmColors.fg2);
        expect(_wi68List, findsNothing);
      },
    );

    testWidgets(
      'with no note selected the outline ignores text the editor still holds',
      (tester) async {
        final p = await _wi68PumpPanel(tester, noteId: null, load: false);
        // The editor still holds a note it showed before (a graph tab or an
        // unzoomed canvas leaves it loaded).
        p.load(_wi68NoteId);
        await pumpFrames(tester);

        expect(find.text(_wi68NoNote), findsOneWidget);
        expect(_wi68Row(0), findsNothing);
      },
    );

    testWidgets(
      'a note with no headings shows the no headings copy keyed outline-empty with the keycap and no count',
      (tester) async {
        await _wi68PumpPanel(tester, content: _wi68Prose);

        expect(_wi68TabTexts(tester).toSet(), {
          _wi68Eyebrow,
          _wi68Keycap,
          _wi68NoHeadings,
        });
        final empty = find.byKey(const Key('outline-empty'));
        expect(empty, findsOneWidget);
        expect(
          find.descendant(
            of: empty,
            matching: find.text(_wi68NoHeadings),
            matchRoot: true,
          ),
          findsOneWidget,
        );
        expect(
          _wi68Style(tester, find.text(_wi68NoHeadings)).color,
          OmColors.fg2,
        );
        expect(_wi68Row(0), findsNothing);
      },
    );

    testWidgets('an empty Today note shows the no headings copy', (
      tester,
    ) async {
      const today = VirtualTodayTab('2026-11-18');
      final p = await _wi68PumpPanel(tester, noteId: today.id, load: false);
      p.editor.loadNote(
        Note(
          id: today.id,
          title: '2026-11-18',
          contentMd: '',
          frontmatter: '{"role":"daily"}',
          version: 0,
          createdAt: 0,
          updatedAt: 0,
          tags: const [],
        ),
      );
      await pumpFrames(tester);

      expect(find.text(_wi68NoHeadings), findsOneWidget);
      expect(find.text(_wi68NoNote), findsNothing);
    });

    testWidgets(
      'typing a new level two heading adds an entry without reopening the tab',
      (tester) async {
        final p = await _wi68PumpPanel(tester);
        expect(_wi68Row(16), findsNothing);

        p.editor.type('$_wi68Garden## Compost bins\n');
        await tester.pump();

        expect(_wi68Row(16), findsOneWidget);
        expect(_wi68In(_wi68Row(16), 'Compost bins'), findsOneWidget);
        expect(find.text('· 17'), findsOneWidget);
      },
    );

    testWidgets('a server save that changes a heading updates its entry', (
      tester,
    ) async {
      final p = await _wi68PumpPanel(tester);
      expect(_wi68In(_wi68Row(15), 'Budget'), findsOneWidget);

      final changed = _wi68Garden.replaceFirst('## Budget', '## Spending');
      p.db.db.execute(
        'UPDATE notes SET content_md = ?, version = 2 WHERE id = ?',
        [changed, _wi68NoteId],
      );
      final applied = await p.editor.serverChanged(_wi68NoteId);
      await pumpFrames(tester);

      expect(applied, isTrue, reason: 'fixture: the server change landed');
      expect(_wi68In(_wi68Row(15), 'Spending'), findsOneWidget);
      expect(find.text('Budget'), findsNothing);
    });

    testWidgets(
      'after a switch to another note the outline never shows the previous note entries',
      (tester) async {
        final p = await _wi68PumpPanel(tester);
        expect(find.text('Garden planning 2026'), findsOneWidget);

        p.select(_wi68OtherId);
        await pumpFrames(tester);
        expect(
          find.text('Garden planning 2026'),
          findsNothing,
          reason: 'the editor still holds the garden note',
        );

        p.load(_wi68OtherId);
        await pumpFrames(tester);
        expect(_wi68In(_wi68Row(0), 'Shed repairs'), findsOneWidget);
        expect(_wi68In(_wi68Row(1), 'Roof felt'), findsOneWidget);
        expect(_wi68Row(2), findsNothing);
      },
    );

    testWidgets(
      'while a hosted note is still loading the outline tab shows the shared loading state',
      (tester) async {
        final p = await _wi68PumpPanel(
          tester,
          vault: const HostedVaultRef('srv', 'a'),
          gateOpen: false,
          load: false,
        );

        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
        expect(find.text(_wi68NoNote), findsNothing);
        expect(find.text(_wi68NoHeadings), findsNothing);

        p.gate.open();
        await pumpFrames(tester);
        p.load(_wi68NoteId);
        await pumpFrames(tester);

        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(_wi68Text(0), findsOneWidget);
      },
    );

    testWidgets(
      'a hosted note whose read failed shows the header and no loading state or entries',
      (tester) async {
        await _wi68PumpPanel(
          tester,
          vault: const HostedVaultRef('srv', 'a'),
          load: false,
          readError: Exception('read failed'),
        );
        await pumpFrames(tester);

        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(find.text(_wi68Eyebrow), findsOneWidget);
        expect(_wi68KeycapFinder, findsOneWidget);
        expect(find.byKey(const Key('outline-list')), findsNothing);
        expect(find.text(_wi68NoNote), findsNothing);
        expect(find.text(_wi68NoHeadings), findsNothing);
      },
    );

    testWidgets(
      'the header text colours of the outline tab are at least 4.5 to 1 on surface1',
      (tester) async {
        await _wi68PumpPanel(tester);
        final texts = [
          find.text(_wi68Eyebrow),
          find.text('· 16'),
          find.descendant(
            of: _wi68KeycapFinder,
            matching: find.byType(RichText),
          ),
        ];
        for (final f in texts) {
          expect(f, findsWidgets);
          final c = _wi68Style(tester, f.first).color!;
          expect(
            _wi68Contrast(c, OmColors.surface1),
            greaterThanOrEqualTo(4.5),
          );
        }
      },
    );
  });

  // ------------------------------------------------------------- R41
  group('entries are computed only while the tab shows', () {
    testWidgets(
      'with the right panel closed or another tab showing editing the note computes no entries',
      (tester) async {
        final p = await _wi68PumpPanel(tester);
        expect(p.computed, 1, reason: 'one compute when the tab shows');
        expect(_wi68Text(0), findsOneWidget);

        p.show(RightPanelTab.connections);
        await pumpFrames(tester);
        final shown = p.computed;
        p.editor.type('$_wi68Garden## Compost bins\n');
        await pumpFrames(tester);
        p.editor.type('$_wi68Garden## Compost bins and leaf mould\n');
        await pumpFrames(tester);
        expect(p.computed, shown, reason: 'another tab: no compute');

        p.show(RightPanelTab.outline);
        await pumpFrames(tester);
        expect(p.computed, shown + 1, reason: 'shown again: one compute');
        expect(find.text('Compost bins and leaf mould'), findsOneWidget);

        // The panel closes: the tab and its provider go away.
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: p.container,
            child: const MaterialApp(home: SizedBox.shrink()),
          ),
        );
        await pumpFrames(tester);
        final closed = p.computed;
        p.editor.type('$_wi68Garden## Seed trays\n');
        await pumpFrames(tester);
        expect(p.computed, closed, reason: 'panel closed: no compute');
      },
    );

    testWidgets(
      'entries recompute once per text change and not on a change that keeps the text',
      (tester) async {
        final p = await _wi68PumpPanel(tester);
        expect(p.computed, 1);

        p.editor.touch();
        await pumpFrames(tester);
        expect(p.computed, 1, reason: 'same text');

        p.editor.type('$_wi68Garden## Compost bins\n');
        await pumpFrames(tester);
        expect(p.computed, 2, reason: 'one compute for one change');
      },
    );

    testWidgets(
      'entries are computed from the live editor text with the editor note role',
      (tester) async {
        final p = await _wi68PumpPanel(tester, role: 'daily');

        expect(p.roles, isNotEmpty);
        expect(p.roles.last, 'daily');
        expect(p.texts.last, _wi68Garden);

        p.editor.type('$_wi68Garden## Compost bins\n');
        await pumpFrames(tester);
        expect(p.texts.last, '$_wi68Garden## Compost bins\n');
        expect(p.roles.last, 'daily');
      },
    );
  });

  // ------------------------------------------------------------- shared
  group('shared panel widgets', () {
    testWidgets('PanelHeader draws its count in fg2', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildOmTheme(),
          home: const Scaffold(
            body: SizedBox(
              width: 340,
              child: PanelHeader(eyebrow: 'canvases', count: 3),
            ),
          ),
        ),
      );
      await tester.pump();

      final style = _wi68Style(tester, find.text('· 3'));
      expect(style.color, OmColors.fg2);
      expect(style.fontSize, 10.5);
    });

    testWidgets(
      'PanelPlaceholderTab shows a header trailing widget at the header right edge',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildOmTheme(),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 339,
                  height: 400,
                  child: PanelPlaceholderTab(
                    eyebrow: 'outline · this note',
                    subtitle: '',
                    empty: 'nothing here yet',
                    headerTrailing: SizedBox(
                      key: Key('wi68-trailing'),
                      width: 32,
                      height: 19,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final trailing = find.byKey(const Key('wi68-trailing'));
        expect(trailing, findsOneWidget);
        final eyebrow = tester.getRect(find.text(_wi68Eyebrow));
        expect(
          tester.getRect(trailing).center.dy,
          closeTo(eyebrow.center.dy, 2),
        );
        expect(tester.getRect(trailing).right, closeTo(339 - 16, 0.5));
        expect(
          tester.getRect(find.text('nothing here yet')).top,
          greaterThan(tester.getRect(trailing).bottom),
        );
      },
    );

    testWidgets(
      'the connections tab with no note draws its empty copy in fg2',
      (tester) async {
        await _wi68PumpPanel(
          tester,
          noteId: null,
          tab: RightPanelTab.connections,
        );

        const copy = 'select a note to see its connections.';
        expect(find.text(copy), findsOneWidget);
        expect(_wi68Style(tester, find.text(copy)).color, OmColors.fg2);
      },
    );
  });
}
