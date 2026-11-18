// WI #76 (56-A2, Spec #59 reqs 12, 18, 25, 40; D17; design pack 76): the
// Command palette's PaletteRow, group header, frozen Keys and test pump.
//
// - A selected row fills `surface4`; the `↵` chip shows only in the
//   list-only layout (`showEnterChip`, pack mismatch 1). Matched title
//   characters are `accent`; passage marks fill `accentMark` (accent at
//   alpha 38). Passage text is clamped to 2 lines (lead ruling).
// - Hover selects the row through the palette's notifier; a press chooses
//   it with the ⌘ flag held at the press. Semantics: a leaf button with the
//   selected state, labelled `<title>, <meta>`.
// - Every frozen Key resolves to exactly one widget in a pumped fixture.
//
// Seams: palette_pump.dart (fake vault, FakeSearchAccess, FakeClock,
// recording tabs); the palette's sources and choosers are overridden here.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/daily_state.dart';
import 'package:open_memex_app/src/state/note_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_group_header.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_preview.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';
import 'package:open_memex_app/src/widgets/command_palette/passages_states.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/palette_pump.dart';

/// The list column's inner width in the 400 px column (pack 76).
const _listWidth = 387.0;

/// The list-only card's inner width at 640 (pack 76).
const _narrowWidth = 626.0;

const _shortPassage = 'so we pushed back the launch';
const _longPassage =
    '…so we pushed back the launch two weeks, which lets the pricing '
    'page ship on the same day as the new onboarding.';

// Rows built from run-time values (never canonicalised consts).
CommandItem _cmd(
  PaletteCommand c, {
  String? label,
  String? meta,
  List<int> matched = const [],
}) => CommandItem(c, label: label ?? c.name, meta: meta, matched: [...matched]);

NoteItem _note(
  String id,
  String title, {
  PaletteNoteKind kind = PaletteNoteKind.note,
  String? meta,
  List<int> matched = const [],
}) => NoteItem(
  noteId: [id].join(),
  kind: kind,
  title: [title].join(),
  meta: meta ?? '${kind.name} · 2 h ago',
  matched: [...matched],
);

PassageItem _passage(
  String chunk, {
  String title = 'Q3 planning',
  String snippet = _shortPassage,
  List<TextRange> marks = const [],
}) => PassageItem(
  SearchHit(
    noteId: ['n', chunk].join('-'),
    noteTitle: [title].join(),
    chunkId: [chunk].join(),
    snippet: [snippet].join(),
    startByte: 120,
    noteUpdatedAt: paletteHoursAgo(24),
  ),
  meta: 'note · 1 d ago',
  marks: [...marks],
);

/// The PaletteRow showing exactly [item].
Finder _rowOf(PaletteItem item) => find.byWidgetPredicate(
  (w) => w is PaletteRow && identical(w.item, item),
  description: 'PaletteRow(${item.title})',
);

/// Pumps [rows] stacked in a [width]-wide list column.
Future<PaletteHarness> _pumpRows(
  WidgetTester tester,
  List<Widget> rows, {
  double width = _listWidth,
  Size size = paletteWideSize,
  double textScale = 1.0,
}) => pumpPaletteHost(
  tester,
  size: size,
  textScale: textScale,
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    ),
  ),
);

/// Whether a widget at or under [of] paints a [color] fill (a ColoredBox,
/// a DecoratedBox's BoxDecoration, a Container or a Material).
bool _paintsFill(Finder of, Color color) => find
    .descendant(
      of: of,
      matchRoot: true,
      matching: find.byWidgetPredicate(
        (w) => switch (w) {
          ColoredBox(color: final c) => c == color,
          DecoratedBox(decoration: BoxDecoration(color: final c?)) =>
            c == color,
          Container(color: final c?) => c == color,
          Material(color: final c?) => c == color,
          _ => false,
        },
      ),
    )
    .evaluate()
    .isNotEmpty;

/// Each UTF-16 unit of [span]'s text with its effective colour.
List<(String, Color?)> _charColors(InlineSpan span) {
  final out = <(String, Color?)>[];
  void walk(InlineSpan s, TextStyle? parent) {
    final style = parent == null ? s.style : parent.merge(s.style);
    if (s is TextSpan) {
      final text = s.text;
      if (text != null) {
        for (var i = 0; i < text.length; i++) {
          out.add((text[i], style?.color));
        }
      }
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }
  }

  walk(span, null);
  return out;
}

/// The RichText under [row] whose plain text is [text].
RichText _richTextOf(WidgetTester tester, Finder row, String text) {
  final found = find.descendant(
    of: row,
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == text,
    ),
  );
  expect(found, findsOneWidget, reason: 'the title text $text');
  return tester.widget<RichText>(found);
}

/// The UTF-16 indices of [text] (the RichText under [row] with that plain
/// text) drawn on an `accentMark` background.
Set<int> _markedChars(WidgetTester tester, Finder row, String text) {
  final rich = _richTextOf(tester, row, text);
  final out = <int>{};
  var at = 0;
  void walk(InlineSpan s, TextStyle? parent) {
    final style = parent == null ? s.style : parent.merge(s.style);
    if (s is TextSpan) {
      final t = s.text;
      if (t != null) {
        if (style?.backgroundColor == OmColors.accentMark) {
          for (var i = 0; i < t.length; i++) {
            out.add(at + i);
          }
        }
        at += t.length;
      }
      for (final child in s.children ?? const <InlineSpan>[]) {
        walk(child, style);
      }
    }
  }

  walk(rich.text, null);
  return out;
}

/// The text drawn on an `accentMark` fill under [row], one string per mark,
/// in order: TextSpans with an `accentMark` background, or widgets (e.g. a
/// WidgetSpan's box) filled `accentMark` around their text.
List<String> _markedText(WidgetTester tester, Finder row) {
  final marks = <String>[];
  // Spans with a background colour.
  for (final rich in tester.widgetList<RichText>(
    find.descendant(of: row, matching: find.byType(RichText)),
  )) {
    final buffer = StringBuffer();
    void flush() {
      if (buffer.isNotEmpty) marks.add(buffer.toString());
      buffer.clear();
    }

    void walk(InlineSpan s, TextStyle? parent) {
      final style = parent == null ? s.style : parent.merge(s.style);
      if (s is TextSpan) {
        final marked =
            style?.backgroundColor == OmColors.accentMark ||
            style?.background?.color == OmColors.accentMark;
        if (s.text != null) {
          if (marked) {
            buffer.write(s.text);
          } else {
            flush();
          }
        }
        for (final child in s.children ?? const <InlineSpan>[]) {
          walk(child, style);
        }
      } else {
        flush();
      }
    }

    walk(rich.text, null);
    flush();
  }
  // Boxes filled accentMark (a WidgetSpan mark).
  final boxes = find.descendant(
    of: row,
    matching: find.byWidgetPredicate(
      (w) => switch (w) {
        ColoredBox(color: final c) => c == OmColors.accentMark,
        DecoratedBox(decoration: BoxDecoration(color: final c?)) =>
          c == OmColors.accentMark,
        _ => false,
      },
    ),
  );
  for (final box in boxes.evaluate()) {
    final texts = find.descendant(
      of: find.byElementPredicate((e) => identical(e, box)),
      matching: find.byType(RichText),
    );
    marks.add(
      tester
          .widgetList<RichText>(texts)
          .map((r) => r.text.toPlainText())
          .join(),
    );
  }
  return marks;
}

/// The palette's sources answer [commands] and [titles] for every query;
/// every choice is recorded in [choices] as (row id, newTab).
List<Override> _sources({
  List<CommandItem> commands = const [],
  List<NoteItem> titles = const [],
  required List<(PaletteItemId, bool)> choices,
}) => [
  paletteCommandsSourceProvider.overrideWith(
    (ref) =>
        (_) => commands,
  ),
  paletteTitlesSourceProvider.overrideWith(
    (ref) =>
        (_) => titles,
  ),
  paletteCommandChooserProvider.overrideWith(
    (ref) =>
        (item, {required newTab}) => choices.add((item.id, newTab)),
  ),
  paletteNoteChooserProvider.overrideWith(
    (ref) =>
        (item, {required newTab}) => choices.add((item.id, newTab)),
  ),
];

/// The palette's groups as a plain list of rows, as #77's shell lists them.
class _Wi76List extends ConsumerWidget {
  const _Wi76List();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(paletteProvider);
    return Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: _listWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final g in state.groups)
              for (final r in g.rows)
                PaletteRow(item: r, selected: r.id == state.selected),
          ],
        ),
      ),
    );
  }
}

/// Pumps the palette's rows from its notifier over [_sources].
Future<PaletteHarness> _pumpPalette(
  WidgetTester tester, {
  List<CommandItem> commands = const [],
  List<NoteItem> titles = const [],
  required List<(PaletteItemId, bool)> choices,
}) => pumpPaletteHost(
  tester,
  overrides: _sources(commands: commands, titles: titles, choices: choices),
  child: const _Wi76List(),
);

/// The palette's rows plus one [PaletteRow] for [stale], an item no source
/// lists: a row a regroup dropped before this frame rebuilt the list.
Future<PaletteHarness> _pumpStaleRow(
  WidgetTester tester, {
  required List<CommandItem> commands,
  required PaletteItem stale,
  required List<(PaletteItemId, bool)> choices,
}) => pumpPaletteHost(
  tester,
  overrides: _sources(commands: commands, choices: choices),
  child: Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: _listWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Wi76List(),
          PaletteRow(item: stale, selected: false),
        ],
      ),
    ),
  ),
);

PaletteItemId? _selected(PaletteHarness h) => h.read(paletteProvider).selected;

PaletteItemId _cmdId(PaletteCommand c) =>
    PaletteItemId(PaletteItemKind.command, [c.name].join());

void main() {
  holdFontFetches();

  group('selected fill and chip', () {
    testWidgets(
      'a selected palette row paints the surface4 fill and shows the enter chip and an unselected row has neither',
      (tester) async {
        final selected = _cmd(PaletteCommand.backups, label: 'Backups');
        final other = _note('n1', 'Backlog');
        await _pumpRows(tester, width: _narrowWidth, size: paletteNarrowSize, [
          PaletteRow(item: selected, selected: true, showEnterChip: true),
          PaletteRow(item: other, selected: false, showEnterChip: true),
        ]);
        expect(_rowOf(selected), findsOneWidget);
        expect(_paintsFill(_rowOf(selected), OmColors.surface4), isTrue);
        expect(
          find.descendant(of: _rowOf(selected), matching: find.text('↵')),
          findsOneWidget,
        );
        expect(_paintsFill(_rowOf(other), OmColors.surface4), isFalse);
        expect(
          find.descendant(of: _rowOf(other), matching: find.text('↵')),
          findsNothing,
        );
      },
    );

    testWidgets('a selected row in the wide layout has the fill and no chip', (
      tester,
    ) async {
      final selected = _cmd(PaletteCommand.agents, label: 'Agents');
      await _pumpRows(tester, [PaletteRow(item: selected, selected: true)]);
      expect(_rowOf(selected), findsOneWidget);
      expect(_paintsFill(_rowOf(selected), OmColors.surface4), isTrue);
      expect(find.text('↵'), findsNothing);
      // The chip flag alone draws nothing on an unselected row.
      final unselected = _cmd(PaletteCommand.backups, label: 'Backups');
      await _pumpRows(tester, [
        PaletteRow(item: unselected, selected: false, showEnterChip: true),
      ]);
      expect(_rowOf(unselected), findsOneWidget);
      expect(find.text('↵'), findsNothing);
    });

    testWidgets(
      'a selected passage row in the list-only layout shows the fill and chip',
      (tester) async {
        final passage = _passage('ch-1');
        await _pumpRows(tester, width: _narrowWidth, size: paletteNarrowSize, [
          PaletteRow(item: passage, selected: true, showEnterChip: true),
        ]);
        expect(_paintsFill(_rowOf(passage), OmColors.surface4), isTrue);
        expect(
          find.descendant(of: _rowOf(passage), matching: find.text('↵')),
          findsOneWidget,
        );
      },
    );
  });

  group('matched characters and marks', () {
    testWidgets('palette row draws the matched title characters in accent', (
      tester,
    ) async {
      final backups = _cmd(
        PaletteCommand.backups,
        label: 'Backups',
        matched: [0, 1, 2, 3],
      );
      final feedback = _note('n2', 'Feedback log', matched: [4, 5, 6, 7]);
      final scattered = _cmd(
        PaletteCommand.rightPanel,
        label: 'Show right panel',
        matched: [0, 5, 11],
      );
      final plain = _note('n3', 'Pricing model');
      await _pumpRows(tester, [
        PaletteRow(item: backups, selected: true),
        PaletteRow(item: feedback, selected: false),
        PaletteRow(item: scattered, selected: false),
        PaletteRow(item: plain, selected: false),
      ]);
      for (final item in [backups, feedback, scattered, plain]) {
        final chars = _charColors(
          _richTextOf(tester, _rowOf(item), item.title).text,
        );
        expect(chars.map((c) => c.$1).join(), item.title);
        for (var i = 0; i < chars.length; i++) {
          expect(
            chars[i].$2,
            item.matched.contains(i) ? OmColors.accent : OmColors.fg0,
            reason: '${item.title} [$i] ${chars[i].$1}',
          );
        }
      }
    });

    testWidgets('a passage row draws its marks in the mark highlight', (
      tester,
    ) async {
      final one = _passage(
        'ch-1',
        marks: [const TextRange(start: 13, end: 17)],
      );
      const two =
          'Annual plans get their money back within 30 days; '
          'nothing back.';
      final first = two.indexOf('back');
      final second = two.lastIndexOf('back');
      final twice = _passage(
        'ch-2',
        title: 'Pricing model',
        snippet: two,
        marks: [
          TextRange(start: first, end: first + 4),
          TextRange(start: second, end: second + 4),
        ],
      );
      final meaningOnly = _passage('ch-3', title: '2026-11-17');
      await _pumpRows(tester, [
        PaletteRow(item: one, selected: false),
        PaletteRow(item: twice, selected: true),
        PaletteRow(item: meaningOnly, selected: false),
      ]);
      expect(_markedText(tester, _rowOf(one)), ['back']);
      expect(_markedText(tester, _rowOf(twice)), ['back', 'back']);
      expect(_markedText(tester, _rowOf(meaningOnly)), isEmpty);
      // The passage's unmarked text is drawn too.
      expect(
        find.descendant(
          of: _rowOf(meaningOnly),
          matching: find.text(_shortPassage, findRichText: true),
        ),
        findsOneWidget,
      );
    });

    test('accentMark is accent at alpha 38 and not successBg', () {
      expect(OmColors.accentMark, OmColors.accent.withAlpha(38));
      expect(OmColors.accentMark == OmColors.successBg, isFalse);
    });

    testWidgets('a passage row title draws no accent characters', (
      tester,
    ) async {
      final passage = _passage('ch-1', title: 'Backlog');
      await _pumpRows(tester, [PaletteRow(item: passage, selected: false)]);
      final chars = _charColors(
        _richTextOf(tester, _rowOf(passage), 'Backlog').text,
      );
      expect(chars.map((c) => c.$2).toSet(), {OmColors.fg0});
    });
  });

  group('layout', () {
    testWidgets('palette rows show the kind icon from the design pack', (
      tester,
    ) async {
      const icons = {
        PaletteCommand.newNote: LucideIcons.filePlus,
        PaletteCommand.newCanvas: LucideIcons.grid2x2Plus,
        PaletteCommand.openToday: LucideIcons.calendarCheck,
        PaletteCommand.openVaultGraph: LucideIcons.network,
        PaletteCommand.switchVault: LucideIcons.arrowLeftRight,
        PaletteCommand.vaultSettings: LucideIcons.settings2,
        PaletteCommand.backups: LucideIcons.archive,
        PaletteCommand.agents: LucideIcons.bot,
        PaletteCommand.rightPanel: LucideIcons.panelRight,
        PaletteCommand.showDays: LucideIcons.calendarDays,
        PaletteCommand.showTopics: LucideIcons.listTree,
        PaletteCommand.showTags: LucideIcons.tag,
      };
      final commands = [for (final c in PaletteCommand.values) _cmd(c)];
      final note = _note('n1', 'Backlog');
      final daily = _note(
        'd1',
        '2026-11-18',
        kind: PaletteNoteKind.daily,
        meta: 'daily · today',
      );
      final canvas = _note(
        'c1',
        'Backend migration',
        kind: PaletteNoteKind.canvas,
      );
      final passage = _passage('ch-1');
      await _pumpRows(tester, size: const Size(1280, 1200), [
        for (final c in commands) PaletteRow(item: c, selected: false),
        PaletteRow(item: note, selected: false),
        PaletteRow(item: daily, selected: false),
        PaletteRow(item: canvas, selected: false),
        PaletteRow(item: passage, selected: false),
      ]);
      final expected = <(PaletteItem, IconData)>[
        for (final c in commands) (c, icons[c.command]!),
        (note, LucideIcons.fileText),
        (daily, LucideIcons.calendar),
        (canvas, LucideIcons.layoutDashboard),
        (passage, LucideIcons.textQuote),
      ];
      for (final (item, icon) in expected) {
        final found = find.descendant(
          of: _rowOf(item),
          matching: find.byIcon(icon),
        );
        expect(found, findsOneWidget, reason: item.title);
        expect(tester.getSize(found), const Size(14, 14), reason: item.title);
        final widget = tester.widget<Icon>(found);
        expect(
          widget.color ?? IconTheme.of(tester.element(found)).color,
          OmColors.fg2,
          reason: item.title,
        );
      }
    });

    testWidgets('palette row heights follow the design pack', (tester) async {
      final command = _cmd(PaletteCommand.backups, label: 'Backups');
      final note = _note('n1', 'Backlog', meta: 'note · 4 d ago');
      final oneLine = _passage('ch-1');
      final twoLines = _passage('ch-2', snippet: _longPassage);
      await _pumpRows(tester, [
        PaletteRow(item: command, selected: true),
        PaletteRow(item: note, selected: false),
        PaletteRow(item: oneLine, selected: false),
        PaletteRow(item: twoLines, selected: false),
      ]);
      expect(tester.getSize(_rowOf(command)).height, 32);
      expect(tester.getSize(_rowOf(note)).height, 32);
      // Passage rows: 51 with one line of passage text, 69 with two. The long
      // passage needs more than two lines here, so 69 pins the 2-line clamp.
      expect(tester.getSize(_rowOf(oneLine)).height, 51);
      expect(tester.getSize(_rowOf(twoLines)).height, 69);
      expect(tester.getSize(_rowOf(command)).width, _listWidth);
    });

    testWidgets('palette rows show their title and meta text', (tester) async {
      final note = _note('n1', 'Backlog', meta: 'note · 4 d ago');
      final command = _cmd(
        PaletteCommand.openToday,
        label: 'Open today',
        meta: '2026-11-18',
      );
      final bare = _cmd(PaletteCommand.agents, label: 'Agents');
      final passage = _passage('ch-1');
      await _pumpRows(tester, [
        PaletteRow(item: note, selected: false),
        PaletteRow(item: command, selected: false),
        PaletteRow(item: bare, selected: false),
        PaletteRow(item: passage, selected: false),
      ]);
      for (final (item, texts) in <(PaletteItem, List<String>)>[
        (note, ['Backlog', 'note · 4 d ago']),
        (command, ['Open today', '2026-11-18']),
        (bare, ['Agents']),
        (passage, ['Q3 planning', 'note · 1 d ago', _shortPassage]),
      ]) {
        for (final text in texts) {
          expect(
            find.descendant(
              of: _rowOf(item),
              matching: find.text(text, findRichText: true),
            ),
            findsOneWidget,
            reason: '${item.title}: $text',
          );
        }
      }
    });

    testWidgets(
      'palette rows do not overflow at 1.5 text scale in the narrow window',
      (tester) async {
        final long = List.filled(8, 'Quarterly planning notes').join(' ');
        final note = _note('n1', long, meta: 'canvas · 2 w ago');
        final command = _cmd(
          PaletteCommand.openToday,
          label: long,
          meta: '2026-11-18',
        );
        final passage = _passage('ch-1', title: long, snippet: _longPassage);
        await _pumpRows(
          tester,
          width: _narrowWidth,
          size: paletteNarrowSize,
          textScale: 1.5,
          [
            PaletteRow(item: note, selected: true, showEnterChip: true),
            PaletteRow(item: command, selected: false, showEnterChip: true),
            PaletteRow(item: passage, selected: true, showEnterChip: true),
          ],
        );
        expect(tester.takeException(), isNull);
        for (final item in [note, command, passage]) {
          expect(_rowOf(item), findsOneWidget);
          expect(tester.getSize(_rowOf(item)).width, _narrowWidth);
        }
        expect(find.text('↵'), findsNWidgets(2));
      },
    );
  });

  group('pointer', () {
    testWidgets(
      'hovering a palette row selects it and moving out keeps the selection',
      (tester) async {
        final choices = <(PaletteItemId, bool)>[];
        final rows = [
          _cmd(PaletteCommand.backups),
          _cmd(PaletteCommand.agents),
          _cmd(PaletteCommand.newNote),
        ];
        final h = await _pumpPalette(tester, commands: rows, choices: choices);
        expect(_selected(h), _cmdId(PaletteCommand.backups));

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1200, 700));
        addTearDown(mouse.removePointer);
        await tester.pump();
        // Mouse in.
        await mouse.moveTo(tester.getCenter(_rowOf(rows[1])));
        await tester.pump();
        expect(_selected(h), _cmdId(PaletteCommand.agents));
        expect(_paintsFill(_rowOf(rows[1]), OmColors.surface4), isTrue);
        expect(_paintsFill(_rowOf(rows[0]), OmColors.surface4), isFalse);
        // Mouse out: the selection stays.
        await mouse.moveTo(const Offset(1200, 700));
        await tester.pump();
        expect(_selected(h), _cmdId(PaletteCommand.agents));
        // Into another row.
        await mouse.moveTo(tester.getCenter(_rowOf(rows[2])));
        await tester.pump();
        expect(_selected(h), _cmdId(PaletteCommand.newNote));
        expect(choices, isEmpty);
      },
    );

    testWidgets(
      'a resting mouse does not take the selection back after a keyboard move',
      (tester) async {
        final choices = <(PaletteItemId, bool)>[];
        final rows = [
          _cmd(PaletteCommand.backups),
          _cmd(PaletteCommand.agents),
          _cmd(PaletteCommand.newNote),
        ];
        final h = await _pumpPalette(tester, commands: rows, choices: choices);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(1200, 700));
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(_rowOf(rows[1])));
        await tester.pump();
        expect(_selected(h), _cmdId(PaletteCommand.agents));

        h.read(paletteProvider.notifier).move(1);
        await tester.pump();
        await tester.pump();
        expect(_selected(h), _cmdId(PaletteCommand.newNote));
      },
    );

    testWidgets('a click on a palette row calls choose with newTab false', (
      tester,
    ) async {
      final choices = <(PaletteItemId, bool)>[];
      final rows = [_cmd(PaletteCommand.backups), _cmd(PaletteCommand.agents)];
      final note = _note('n1', 'Backlog');
      final h = await _pumpPalette(
        tester,
        commands: rows,
        titles: [note],
        choices: choices,
      );
      expect(_selected(h), _cmdId(PaletteCommand.backups));
      // A click on a row that isn't selected chooses that row.
      await tester.tap(_rowOf(note));
      await tester.pump();
      expect(choices, [(PaletteItemId(PaletteItemKind.note, 'n1'), false)]);
    });

    testWidgets('a cmd click on a palette row calls choose with newTab true', (
      tester,
    ) async {
      final choices = <(PaletteItemId, bool)>[];
      final rows = [_cmd(PaletteCommand.backups), _cmd(PaletteCommand.agents)];
      await _pumpPalette(tester, commands: rows, choices: choices);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(_rowOf(rows[1]));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(choices, [(_cmdId(PaletteCommand.agents), true)]);
    });

    testWidgets('two clicks on a palette row in one frame choose once', (
      tester,
    ) async {
      final choices = <(PaletteItemId, bool)>[];
      final rows = [
        _cmd(PaletteCommand.newNote),
        _cmd(PaletteCommand.newCanvas),
      ];
      await _pumpPalette(tester, commands: rows, choices: choices);
      await tester.tap(_rowOf(rows[0]));
      await tester.tap(_rowOf(rows[0]));
      await tester.pump();
      expect(choices, [(_cmdId(PaletteCommand.newNote), false)]);
    });

    testWidgets(
      'a click on a row the palette no longer lists chooses nothing',
      (tester) async {
        final choices = <(PaletteItemId, bool)>[];
        final rows = [
          _cmd(PaletteCommand.newNote),
          _cmd(PaletteCommand.newCanvas),
        ];
        final stale = _note('gone', 'Dropped note');
        final h = await _pumpStaleRow(
          tester,
          commands: rows,
          stale: stale,
          choices: choices,
        );
        expect(_selected(h), _cmdId(PaletteCommand.newNote));
        await tester.tap(_rowOf(stale));
        await tester.pump();
        // Not the stale row, and not the row that is selected now either.
        expect(choices, isEmpty);
        expect(_selected(h), _cmdId(PaletteCommand.newNote));
        // A cmd click chooses nothing either.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.tap(_rowOf(stale));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
        expect(choices, isEmpty);
        // A listed row still chooses, so the palette was not latched shut.
        await tester.tap(_rowOf(rows[1]));
        await tester.pump();
        expect(choices, [(_cmdId(PaletteCommand.newCanvas), false)]);
      },
    );

    testWidgets(
      'a semantics tap on a row the palette no longer lists chooses nothing',
      (tester) async {
        final handle = tester.ensureSemantics();
        final choices = <(PaletteItemId, bool)>[];
        final rows = [
          _cmd(PaletteCommand.newNote, label: 'New note'),
          _cmd(PaletteCommand.newCanvas, label: 'New canvas'),
        ];
        final stale = _note('gone', 'Dropped note', meta: 'note · 3 d ago');
        final h = await _pumpStaleRow(
          tester,
          commands: rows,
          stale: stale,
          choices: choices,
        );
        void tapNode(String label) {
          final node = tester.getSemantics(find.bySemanticsLabel(label));
          node.owner!.performAction(node.id, SemanticsAction.tap);
        }

        tapNode('Dropped note, note · 3 d ago');
        await tester.pump();
        expect(choices, isEmpty);
        expect(_selected(h), _cmdId(PaletteCommand.newNote));
        // A listed row's semantics tap still chooses it.
        tapNode('New canvas');
        await tester.pump();
        expect(choices, [(_cmdId(PaletteCommand.newCanvas), false)]);
        handle.dispose();
      },
    );
  });

  group('semantics', () {
    testWidgets(
      'palette row semantics are a button with the selected state and the title and meta label',
      (tester) async {
        final handle = tester.ensureSemantics();
        final selected = _cmd(PaletteCommand.backups, label: 'Backups');
        final note = _note('n1', 'Pricing model', meta: 'note · 2 h ago');
        final passage = _passage('ch-1');
        await _pumpRows(tester, width: _narrowWidth, size: paletteNarrowSize, [
          PaletteRow(item: selected, selected: true, showEnterChip: true),
          PaletteRow(item: note, selected: false, showEnterChip: true),
          PaletteRow(item: passage, selected: false, showEnterChip: true),
        ]);
        for (final (item, label, isSelected) in <(PaletteItem, String, bool)>[
          (selected, 'Backups', true),
          (note, 'Pricing model, note · 2 h ago', false),
          (passage, 'Q3 planning, note · 1 d ago', false),
        ]) {
          final node = tester.getSemantics(
            find.descendant(
              of: _rowOf(item),
              matchRoot: true,
              matching: find.bySemanticsLabel(label),
            ),
          );
          expect(node.label, label);
          expect(
            node,
            isSemantics(
              label: label,
              isButton: true,
              hasSelectedState: true,
              isSelected: isSelected,
              hasTapAction: true,
            ),
            reason: label,
          );
          // A leaf: the title, meta, passage text and chip add no nodes.
          expect(node.childrenCount, 0, reason: label);
        }
        handle.dispose();
      },
    );
  });

  group('group header', () {
    testWidgets(
      'the group header renders COMMANDS 12 and PASSAGES 4 with the keyword plus meaning hint',
      (tester) async {
        await _pumpRows(tester, [
          PaletteGroupHeader(kind: PaletteGroupKind.commands, count: 12),
          PaletteGroupHeader(
            kind: PaletteGroupKind.passages,
            count: [4].first,
            hint: ['keyword', '+', 'meaning'].join(' '),
          ),
          PaletteGroupHeader(kind: PaletteGroupKind.notes, count: 3),
          PaletteGroupHeader(kind: PaletteGroupKind.recent, count: 8),
        ]);
        expect(find.text('COMMANDS · 12', findRichText: true), findsOneWidget);
        expect(find.text('PASSAGES · 4', findRichText: true), findsOneWidget);
        expect(
          find.text('keyword + meaning', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('NOTES · 3', findRichText: true), findsOneWidget);
        expect(find.text('RECENT · 8', findRichText: true), findsOneWidget);
        // The hint sits in the Passages header only.
        expect(
          find.descendant(
            of: find.byKey(const Key('palette-group-passages')),
            matching: find.text('keyword + meaning', findRichText: true),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a group header with no count shows its name alone', (
      tester,
    ) async {
      await _pumpRows(tester, [
        const PaletteGroupHeader(kind: PaletteGroupKind.passages),
      ]);
      expect(find.text('PASSAGES', findRichText: true), findsOneWidget);
      expect(find.textContaining('·', findRichText: true), findsNothing);
      expect(find.text('keyword only', findRichText: true), findsNothing);
    });
  });

  group('keys', () {
    test('the frozen palette keys have their exact values', () {
      expect(PaletteKeys.commandBar, const Key('command-bar'));
      expect(PaletteKeys.palette, const Key('command-palette'));
      expect(PaletteKeys.input, const Key('palette-input'));
      expect(PaletteKeys.download, const Key('palette-download'));
      expect(PaletteKeys.preview, const Key('palette-preview'));
      expect(PaletteKeys.noMatches, const Key('palette-no-matches'));
      for (final kind in PaletteGroupKind.values) {
        expect(PaletteKeys.group(kind), Key('palette-group-${kind.name}'));
      }
      expect(
        PaletteKeys.passagesState(['searching'].join()),
        const Key('palette-passages-searching'),
      );
      expect(
        PaletteKeys.row(_cmdId(PaletteCommand.switchVault)),
        const Key('palette-row-command-switchVault'),
      );
      for (final (kind, name) in [
        (PaletteItemKind.note, 'note'),
        (PaletteItemKind.daily, 'daily'),
        (PaletteItemKind.canvas, 'canvas'),
        (PaletteItemKind.passage, 'passage'),
      ]) {
        expect(
          PaletteKeys.row(PaletteItemId(kind, ['x', '1'].join('-'))),
          Key('palette-row-$name-x-1'),
        );
      }
    });

    testWidgets(
      'each frozen key resolves to exactly one widget in a pumped palette fixture',
      (tester) async {
        final command = _cmd(PaletteCommand.backups, label: 'Backups');
        final note = _note(PaletteSeeds.backlog, 'Backlog');
        final daily = _note(
          PaletteSeeds.today,
          '2026-11-18',
          kind: PaletteNoteKind.daily,
        );
        final canvas = _note(
          PaletteSeeds.backendMigration,
          'Backend migration',
          kind: PaletteNoteKind.canvas,
        );
        final passage = _passage('ch-76');
        await _pumpRows(tester, size: const Size(1280, 1000), [
          const SizedBox(height: 40, child: TextField(key: PaletteKeys.input)),
          const PaletteGroupHeader(kind: PaletteGroupKind.commands, count: 1),
          PaletteRow(item: command, selected: true),
          const PaletteGroupHeader(kind: PaletteGroupKind.notes, count: 3),
          PaletteRow(item: note, selected: false),
          PaletteRow(item: daily, selected: false),
          PaletteRow(item: canvas, selected: false),
          const PaletteGroupHeader(
            kind: PaletteGroupKind.passages,
            count: 1,
            hint: 'keyword only',
          ),
          PaletteRow(item: passage, selected: false),
          SizedBox(
            child: Text(
              'searching note text…',
              key: PaletteKeys.passagesState('searching'),
            ),
          ),
          const SizedBox(
            child: Text('Download model (130 MB)', key: PaletteKeys.download),
          ),
        ]);
        for (final key in const [
          Key('palette-input'),
          Key('palette-group-commands'),
          Key('palette-group-notes'),
          Key('palette-group-passages'),
          Key('palette-row-command-backups'),
          Key('palette-row-note-n-76-backlog'),
          Key('palette-row-daily-daily-2026-11-18'),
          Key('palette-row-canvas-cv-76-backend-migration'),
          Key('palette-row-passage-ch-76'),
          Key('palette-passages-searching'),
          Key('palette-download'),
        ]) {
          expect(find.byKey(key), findsOneWidget, reason: '$key');
        }
        // Each row key sits on its own row.
        expect(
          find.descendant(
            of: _rowOf(passage),
            matchRoot: true,
            matching: find.byKey(const Key('palette-row-passage-ch-76')),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('palette-group-recent')), findsNothing);
      },
    );
  });

  group('pump', () {
    testWidgets(
      'palette pump hosts the palette seams at 1280 by 800 and at 900 by 640',
      (tester) async {
        for (final size in [paletteWideSize, paletteNarrowSize]) {
          final h = await pumpPaletteHost(tester, size: size, textScale: 1.5);
          final context = h.context;
          expect(MediaQuery.sizeOf(context), size);
          expect(MediaQuery.textScalerOf(context).scale(10), 15);

          // FakeSearchAccess behind the vault access.
          expect(h.read(vaultAccessProvider)!.search, same(h.search));
          h.search.enqueue(
            const SearchReady([], semantic: Semantic.on, truncated: false),
          );
          expect(
            await h.read(vaultAccessProvider)!.search.search('back'),
            isA<SearchReady>(),
          );
          expect(h.search.calls.single.query, 'back');

          // Fake titles, daily notes and canvases.
          final titles = (await h.read(noteTitlesAsyncProvider.future)).value;
          expect(
            titles.map((t) => t.title),
            containsAll(['Pricing model', 'Backlog', 'Feedback log']),
          );
          final dailies = (await h.read(dailyNotesAsyncProvider.future)).value;
          expect(dailies.map((d) => d.date), ['2026-11-18', '2026-11-17']);
          final canvases = (await h.read(canvasesAsyncProvider.future)).value;
          expect(canvases.map((c) => c.title), ['Backend migration']);

          // Fake timers on the injected clock.
          expect(h.read(clockProvider), same(h.clock));
          expect(h.clock.now(), paletteNow);
          var fired = false;
          h
              .read(clockProvider)
              .after(const Duration(milliseconds: 250), () => fired = true);
          h.clock.advance(const Duration(milliseconds: 249));
          expect(fired, isFalse);
          h.clock.advance(const Duration(milliseconds: 1));
          expect(fired, isTrue);

          // Recording tabs.
          h
              .read(tabsProvider.notifier)
              .follow(const NoteTab(PaletteSeeds.backlog));
          expect(h.tabs.followed, [const NoteTab(PaletteSeeds.backlog)]);

          // A root-navigator dialog shows over the host.
          unawaited(
            showDialog<void>(
              context: context,
              builder: (_) => const Text('palette dialog'),
            ),
          );
          await tester.pump();
          expect(find.text('palette dialog'), findsOneWidget);
          h.navigatorKey.currentState!.pop();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
        }
      },
    );

    testWidgets(
      'the preview and passages stubs build inside the palette host',
      (tester) async {
        await pumpPaletteHost(
          tester,
          child: const Column(
            children: [PalettePreview(), PassagesStateRow(), PassagesFooter()],
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(PalettePreview), findsOneWidget);
        expect(find.byType(PassagesStateRow), findsOneWidget);
        expect(find.byType(PassagesFooter), findsOneWidget);
      },
    );
  });

  group('verify contracts', () {
    testWidgets(
      'a row that appears under a resting pointer does not take the selection',
      (tester) async {
        final choices = <(PaletteItemId, bool)>[];
        final rows = [
          _cmd(PaletteCommand.backups),
          _cmd(PaletteCommand.agents),
          _cmd(PaletteCommand.newNote),
        ];
        final shown = StateProvider<List<CommandItem>>(
          (_) => rows.sublist(0, 2),
        );
        final h = await pumpPaletteHost(
          tester,
          overrides: [
            ..._sources(choices: choices),
            paletteCommandsSourceProvider.overrideWith((ref) {
              final list = ref.watch(shown);
              return (_) => list;
            }),
          ],
          child: const _Wi76List(),
        );
        expect(_selected(h), _cmdId(PaletteCommand.backups));
        // The pointer rests where the third row will be.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(100, 80));
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(_rowOf(rows[2]), findsNothing);

        h.container.read(shown.notifier).state = rows;
        await tester.pump();
        await tester.pump();
        expect(_rowOf(rows[2]), findsOneWidget);
        expect(
          tester.getRect(_rowOf(rows[2])).contains(const Offset(100, 80)),
          isTrue,
        );
        expect(_selected(h), _cmdId(PaletteCommand.backups));
        expect(choices, isEmpty);

        // Moving the pointer a little over that row does select it.
        await mouse.moveTo(const Offset(101, 80));
        await tester.pump();
        expect(_selected(h), _cmdId(PaletteCommand.newNote));
      },
    );

    testWidgets(
      'the accessibility tap action on a palette row selects it and chooses it with newTab false',
      (tester) async {
        final handle = tester.ensureSemantics();
        final choices = <(PaletteItemId, bool)>[];
        final rows = [
          _cmd(PaletteCommand.backups),
          _cmd(PaletteCommand.agents),
        ];
        final h = await _pumpPalette(tester, commands: rows, choices: choices);
        expect(_selected(h), _cmdId(PaletteCommand.backups));
        tester.semantics.performAction(
          find.semantics.byLabel('agents'),
          SemanticsAction.tap,
        );
        await tester.pump();
        expect(choices, [(_cmdId(PaletteCommand.agents), false)]);
        expect(_selected(h), _cmdId(PaletteCommand.agents));
        handle.dispose();
      },
    );

    testWidgets('passage marks given out of order are all drawn', (
      tester,
    ) async {
      const text = 'the quick brown fox jumps over the lazy dog';
      final item = _passage(
        'ch-1',
        snippet: text,
        marks: [
          TextRange(start: text.indexOf('lazy'), end: text.indexOf('lazy') + 4),
          TextRange(start: 4, end: 9),
          TextRange(start: text.indexOf('fox'), end: text.indexOf('fox') + 3),
        ],
      );
      await _pumpRows(tester, [PaletteRow(item: item, selected: false)]);
      expect(_markedChars(tester, _rowOf(item), text), {
        for (var i = 4; i < 9; i++) i,
        for (var i = 16; i < 19; i++) i,
        for (var i = 35; i < 39; i++) i,
      });
      expect(_markedText(tester, _rowOf(item)), ['quick', 'fox', 'lazy']);
    });

    testWidgets('overlapping passage marks are drawn once over their union', (
      tester,
    ) async {
      const text = 'the quick brown fox jumps over the lazy dog';
      final partial = _passage(
        'ch-1',
        snippet: text,
        marks: [
          const TextRange(start: 4, end: 12),
          const TextRange(start: 8, end: 15),
        ],
      );
      final contained = _passage(
        'ch-2',
        snippet: text,
        marks: [
          const TextRange(start: 4, end: 19),
          const TextRange(start: 10, end: 14),
        ],
      );
      await _pumpRows(tester, [
        PaletteRow(item: partial, selected: false),
        PaletteRow(item: contained, selected: false),
      ]);
      expect(tester.takeException(), isNull);
      expect(_markedChars(tester, _rowOf(partial), text), {
        for (var i = 4; i < 15; i++) i,
      });
      expect(_markedChars(tester, _rowOf(contained), text), {
        for (var i = 4; i < 19; i++) i,
      });
    });

    testWidgets(
      'passage marks past the text end are clamped and empty marks draw nothing',
      (tester) async {
        const text = 'the quick brown fox';
        final clamped = _passage(
          'ch-1',
          snippet: text,
          marks: [const TextRange(start: 16, end: 400)],
        );
        final outside = _passage(
          'ch-2',
          snippet: text,
          marks: [
            const TextRange(start: 40, end: 50),
            const TextRange(start: 8, end: 8),
          ],
        );
        await _pumpRows(tester, [
          PaletteRow(item: clamped, selected: false),
          PaletteRow(item: outside, selected: false),
        ]);
        expect(tester.takeException(), isNull);
        expect(_markedChars(tester, _rowOf(clamped), text), {16, 17, 18});
        expect(_markedChars(tester, _rowOf(outside), text), isEmpty);
        // The text is drawn whole either way.
        expect(
          find.descendant(
            of: _rowOf(outside),
            matching: find.text(text, findRichText: true),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('marked passage characters are fg0 and the rest fg1', (
      tester,
    ) async {
      const text = 'the quick brown fox';
      final item = _passage(
        'ch-1',
        snippet: text,
        marks: [const TextRange(start: 4, end: 9)],
      );
      await _pumpRows(tester, [PaletteRow(item: item, selected: false)]);
      final chars = _charColors(_richTextOf(tester, _rowOf(item), text).text);
      expect(chars.map((c) => c.$1).join(), text);
      for (var i = 0; i < chars.length; i++) {
        expect(
          chars[i].$2,
          i >= 4 && i < 9 ? OmColors.fg0 : OmColors.fg1,
          reason: '[$i] ${chars[i].$1}',
        );
      }
    });
  });
}
