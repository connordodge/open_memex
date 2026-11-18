// WI #78 (56-A4, Spec #59 req 29; design pack 78 C1, C2, C5, F4, F5): the
// Command palette's preview pane.
//
// - A command shows its C5 description; a note or daily note its title and
//   plain `contentMd` from the top; a passage its note's text with the
//   chunk's lines on a `surface3` band (typed words in `accentMark`), the
//   `start_byte` line about a third of the way down, or from the top with no
//   band for a null `start_byte`; a canvas its title, `<n> cards` and up to 8
//   card titles (the WI fallback: no board draws a canvas).
// - A read starts once the selection has rested 120 ms (holding ↓ reads only
//   the last row); only the latest read shows; `loading…` while reading,
//   `couldn't load the preview.` on failure.
// - Under 950 px nothing is built and nothing is read.
// - Read-only: no editable text.
//
// Seams: palette_pump.dart's constants and fakes, but its own host: the pump
// can't take a NotesAccess or CanvasAccess double (D21), and these tests
// hold, fail and count reads. #76's real PaletteNotifier with #78's preview
// source (`PalettePreviewReader`), fake commands, titles and passages
// sources, and #78's PalettePreview in a 558 x 506 slot.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/palette_preview_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_preview.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';

import '../../support/app_harness.dart' show pumpFrames;
import '../../support/canvas_seeds.dart' show wi89Detail, wi89Node;
import '../../support/fake_clock.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/palette_pump.dart';
import '../../support/search_fakes.dart';

/// The wide card's preview slot (pack 77).
const _wi78Slot = Size(558, 506);

/// A notes domain that records, holds and fails reads (D21: extends the
/// local class).
class _Wi78Notes extends LocalNotesAccess {
  _Wi78Notes(FakeVaultDb db) : super(vaultPath: paletteVaultPath, db: db);

  final reads = <String>[];
  final holds = <String, Completer<void>>{};
  final failing = <String>{};

  @override
  Future<Note?> getNote(String id) async {
    reads.add(id);
    final hold = holds[id];
    if (hold != null) await hold.future;
    if (failing.contains(id)) throw StateError('read failed for $id');
    return super.getNote(id);
  }
}

/// A canvas domain that records reads and answers [details].
class _Wi78Canvas extends LocalCanvasAccess {
  _Wi78Canvas(FakeVaultDb db) : super(vaultPath: paletteVaultPath, db: db);

  final reads = <String>[];
  final details = <String, CanvasDetailRow>{};

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async {
    reads.add(canvasId);
    return details[canvasId];
  }
}

/// A Passages source that lists [rows] for any typed input.
class _Wi78StubPassages extends PalettePassagesNotifier {
  _Wi78StubPassages(this.rows);

  final List<PassageItem> rows;

  @override
  PassagesView build() => rows.isEmpty
      ? const PassagesIdle()
      : PassagesShown(rows: rows, semantic: Semantic.on);
}

class _Wi78Preview {
  _Wi78Preview(
    this.tester,
    this.container,
    this.notes,
    this.canvas,
    this.clock,
  );

  final WidgetTester tester;
  final ProviderContainer container;
  final _Wi78Notes notes;
  final _Wi78Canvas canvas;
  final FakeClock clock;

  PaletteNotifier get palette => container.read(paletteProvider.notifier);
  PreviewView get preview => container.read(paletteProvider).preview;

  /// Every read, notes and canvases.
  List<String> get reads => [...notes.reads, ...canvas.reads];

  Future<void> wait(int ms) async {
    clock.advance(Duration(milliseconds: ms));
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle() => pumpFrames(tester);
}

Finder get _wi78Pane => find.byKey(PaletteKeys.preview);

Finder _wi78InPane(Finder f) => find.descendant(of: _wi78Pane, matching: f);

Finder _wi78Text(String text) =>
    _wi78InPane(find.textContaining(text, findRichText: true));

bool _wi78Fills(Widget w, Color color) => switch (w) {
  ColoredBox(color: final c) => c == color,
  DecoratedBox(decoration: BoxDecoration(color: final c?)) => c == color,
  Material(color: final c?) => c == color,
  _ => false,
};

/// The preview's widgets filled [color].
Finder _wi78Filled(Color color) =>
    _wi78InPane(find.byWidgetPredicate((w) => _wi78Fills(w, color)));

/// Whether [word] is drawn in the mark highlight under [within]: a text span
/// with an `accentMark` background, or an `accentMark` box holding it.
bool _wi78Marked(Finder within, String word) {
  final lower = word.toLowerCase();
  for (final e
      in find
          .descendant(of: within, matching: find.byType(RichText))
          .evaluate()) {
    var hit = false;
    (e.widget as RichText).text.visitChildren((span) {
      if (span is TextSpan &&
          span.style?.backgroundColor == OmColors.accentMark &&
          (span.text ?? '').toLowerCase() == lower) {
        hit = true;
      }
      return !hit;
    });
    if (hit) return true;
  }
  final boxes = find.descendant(
    of: within,
    matching: find.byWidgetPredicate((w) => _wi78Fills(w, OmColors.accentMark)),
  );
  for (final box in boxes.evaluate()) {
    final inside = find.descendant(
      of: find.byElementPredicate((e) => identical(e, box)),
      matching: find.textContaining(
        RegExp(RegExp.escape(word), caseSensitive: false),
        findRichText: true,
      ),
    );
    if (inside.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// The preview body's scrollable.
Finder get _wi78Scroll => _wi78InPane(find.byType(Scrollable)).first;

/// The long passage note: 40 context lines, the 2-line chunk, 40 more.
String _wi78Lines(int from, int to) =>
    [for (var i = from; i < to; i++) 'context line $i\n'].join();

const _wi78Chunk =
    'So we pushed back the launch two weeks.\n'
    'The pricing page ships the same day.\n';

final _wi78LongBody = '${_wi78Lines(0, 40)}$_wi78Chunk${_wi78Lines(40, 80)}';

/// UTF-8 offset of the chunk in [_wi78LongBody] (the note's stored text).
int get _wi78ChunkByte => utf8
    .encode(_wi78LongBody.substring(0, _wi78LongBody.indexOf(_wi78Chunk)))
    .length;

const _wi78LongId = 'n-78-q3-planning';
const _wi78ShortId = 'n-78-pricing';
const _wi78ShortBody =
    'So we pushed back the launch two weeks.\n\n'
    'The pricing page ships with the new onboarding.';

NoteItem _wi78Note(
  String id,
  String title, {
  PaletteNoteKind kind = PaletteNoteKind.note,
}) => NoteItem(
  noteId: [id].join(),
  kind: kind,
  title: [title].join(),
  meta: '${kind.name} · 2 h ago',
);

PassageItem _wi78Passage(String chunk, {int? startByte}) => PassageItem(
  SearchHit(
    noteId: [_wi78LongId].join(),
    noteTitle: ['Q3 planning'].join(),
    chunkId: [chunk].join(),
    snippet: _wi78Chunk.trim(),
    startByte: startByte,
    noteUpdatedAt: paletteHoursAgo(24),
  ),
  meta: 'note · 1 d ago',
);

Future<_Wi78Preview> _wi78PumpPreview(
  WidgetTester tester, {
  Size size = paletteWideSize,
  List<CommandItem> commands = const [],
  List<NoteItem> recent = const [],
  List<PassageItem> passages = const [],
  void Function(FakeVaultDb db)? seed,
}) async {
  expect(
    fontFetchesHeld,
    isTrue,
    reason: 'call holdFontFetches() at the top of main()',
  );
  final db = FakeVaultDb.v5();
  db.seedNote(
    id: _wi78LongId,
    title: 'Q3 planning',
    content: _wi78LongBody,
    updatedAt: paletteHoursAgo(24),
  );
  db.seedNote(
    id: _wi78ShortId,
    title: 'Pricing model',
    content: _wi78ShortBody,
    updatedAt: paletteHoursAgo(2),
  );
  for (var i = 0; i < 6; i++) {
    db.seedNote(
      id: 'n-78-row-$i',
      title: 'Row note $i',
      content: 'Body of row note $i.',
      updatedAt: paletteHoursAgo(3 + i),
    );
  }
  seed?.call(db);
  final notes = _Wi78Notes(db);
  final canvas = _Wi78Canvas(db);
  final clock = FakeClock(paletteNow);
  final cli = FakeMemexCli();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;

  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith(
        (_) => const LocalVaultRef(paletteVaultPath),
      ),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: paletteVaultPath,
          db: db,
          cli: cli,
          notes: notes,
          canvas: canvas,
          search: FakeSearchAccess(vaultPath: paletteVaultPath, cli: cli),
        ),
      ),
      paletteCommandsSourceProvider.overrideWith(
        (ref) =>
            (q) => q.isEmpty ? commands : const [],
      ),
      paletteTitlesSourceProvider.overrideWith(
        (ref) =>
            (q) => q.isEmpty ? recent : const [],
      ),
      palettePassagesProvider.overrideWith(() => _Wi78StubPassages(passages)),
      palettePreviewProvider.overrideWith(PalettePreviewReader.new),
    ],
  );
  addTearDown(db.close);
  addTearDown(container.dispose);
  addTearDown(tester.view.reset);

  container.listen(paletteProvider, (_, _) {}, fireImmediately: true);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: _wi78Slot,
              child: const PalettePreview(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Wi78Preview(tester, container, notes, canvas, clock);
}

void main() {
  holdFontFetches();

  testWidgets('selecting a command shows its C5 description in the preview', (
    tester,
  ) async {
    final p = await _wi78PumpPreview(
      tester,
      commands: [
        CommandItem(
          PaletteCommand.switchVault,
          label: ['Switch vault…'].join(),
        ),
        CommandItem(PaletteCommand.showDays, label: ['Show Days'].join()),
      ],
    );
    await p.wait(120);
    await p.settle();

    expect(_wi78Pane, findsOneWidget);
    expect(_wi78Text('Switch vault…'), findsWidgets);
    expect(
      _wi78Text(
        'Opens the vault picker, to switch to another vault or a vault server.',
      ),
      findsWidgets,
    );

    p.palette.move(1);
    await p.wait(120);
    await p.settle();
    expect(
      _wi78Text('Switches the sidebar to Days, newest first.'),
      findsWidgets,
    );
    expect(_wi78Text('Opens the vault picker'), findsNothing);
    expect(p.reads, isEmpty, reason: 'a command needs no read');
  });

  testWidgets(
    'selecting a note shows its title and plain contentMd from the top, and the read happens once the selection has rested 120 ms',
    (tester) async {
      final p = await _wi78PumpPreview(
        tester,
        recent: [_wi78Note(_wi78ShortId, 'Pricing model')],
      );
      await p.wait(119);
      expect(p.reads, isEmpty, reason: 'not before 120 ms of rest');
      await p.wait(1);
      expect(p.reads, [_wi78ShortId]);
      await p.settle();

      expect(_wi78Pane, findsOneWidget);
      final title = _wi78Text('Pricing model');
      final first = _wi78Text('So we pushed back the launch two weeks.');
      expect(title, findsWidgets);
      expect(first, findsWidgets);
      expect(
        _wi78Text('The pricing page ships with the new onboarding.'),
        findsWidgets,
      );

      // From the top: the title, then the first paragraph, near the top.
      final pane = tester.getRect(_wi78Pane);
      final titleRect = tester.getRect(title.first);
      final firstRect = tester.getRect(first.first);
      expect(titleRect.top - pane.top, lessThan(80));
      expect(firstRect.top, greaterThanOrEqualTo(titleRect.bottom));
      expect(firstRect.top - titleRect.bottom, lessThan(40));

      // Read-only, and not the editor.
      expect(_wi78InPane(find.byType(EditableText)), findsNothing);
      expect(p.reads, [_wi78ShortId]);
    },
  );

  testWidgets(
    'holding down across 5 rows inside 120 ms each makes one preview read for the last row',
    (tester) async {
      final p = await _wi78PumpPreview(
        tester,
        recent: [
          for (var i = 0; i < 6; i++) _wi78Note('n-78-row-$i', 'Row note $i'),
        ],
      );
      await p.wait(50);
      for (var i = 0; i < 5; i++) {
        p.palette.move(1);
        await p.wait(100);
      }
      expect(p.reads, isEmpty, reason: 'the selection never rested');
      await p.wait(20);
      expect(p.reads, ['n-78-row-5']);
      await p.settle();
      expect(_wi78Text('Row note 5'), findsWidgets);
      expect(_wi78Text('Body of row note 5.'), findsWidgets);
      await p.wait(1000);
      expect(p.reads, ['n-78-row-5']);
    },
  );

  testWidgets(
    'selecting a passage shows its note text with the chunk lines highlighted and the start_byte line about a third of the way down, and a null start_byte shows from the top with no highlight',
    (tester) async {
      final p = await _wi78PumpPreview(
        tester,
        passages: [
          _wi78Passage('c-78-at', startByte: _wi78ChunkByte),
          _wi78Passage('c-78-null'),
        ],
      );
      p.palette.setQuery('back');
      await tester.pump();
      await p.wait(120);
      await p.settle();
      expect(p.reads, [_wi78LongId]);
      expect(_wi78Pane, findsOneWidget);

      final band = _wi78Filled(OmColors.surface3);
      expect(band, findsOneWidget, reason: 'one band over the chunk');
      expect(
        find.descendant(
          of: band,
          matching: find.textContaining(
            'So we pushed back the launch two weeks.',
            findRichText: true,
          ),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: band,
          matching: find.textContaining('context line 39', findRichText: true),
        ),
        findsNothing,
        reason: 'only the chunk lines are on the band',
      );
      expect(_wi78Marked(band, 'back'), isTrue, reason: 'typed word marked');

      final viewport = tester.getRect(_wi78Scroll);
      final bandTop = tester.getRect(band).top - viewport.top;
      expect(bandTop, closeTo(viewport.height / 3, 24));

      p.palette.move(1);
      await tester.pump();
      await p.wait(120);
      await p.settle();
      expect(_wi78Filled(OmColors.surface3), findsNothing);
      final scroll = tester.state<ScrollableState>(_wi78Scroll);
      expect(scroll.position.pixels, 0, reason: 'from the top');
      final title = _wi78Text('Q3 planning');
      expect(title, findsWidgets);
      expect(
        tester.getRect(title.first).top - tester.getRect(_wi78Pane).top,
        lessThan(80),
      );
    },
  );

  testWidgets(
    'a preview read in flight shows loading and a failed read shows the preview error line',
    (tester) async {
      final p = await _wi78PumpPreview(
        tester,
        recent: [
          _wi78Note('n-78-row-0', 'Row note 0'),
          _wi78Note('n-78-row-1', 'Row note 1'),
        ],
      );
      final hold = Completer<void>();
      p.notes.holds['n-78-row-0'] = hold;
      await p.wait(120);
      expect(p.reads, ['n-78-row-0']);
      expect(_wi78InPane(find.text('loading…')), findsOneWidget);
      expect(p.preview, isA<PreviewLoading>());

      hold.complete();
      await p.settle();
      expect(_wi78InPane(find.text('loading…')), findsNothing);
      expect(_wi78Text('Body of row note 0.'), findsWidgets);

      p.notes.failing.add('n-78-row-1');
      p.palette.move(1);
      await p.wait(120);
      await p.settle();
      expect(p.reads, ['n-78-row-0', 'n-78-row-1']);
      expect(
        _wi78InPane(find.text("couldn't load the preview.")),
        findsOneWidget,
      );
      expect(_wi78Text('Body of row note 0.'), findsNothing);
      expect(p.preview, isA<PreviewFailed>());
    },
  );

  testWidgets('only the latest selection preview read is shown', (
    tester,
  ) async {
    final p = await _wi78PumpPreview(
      tester,
      recent: [
        _wi78Note('n-78-row-0', 'Row note 0'),
        _wi78Note('n-78-row-1', 'Row note 1'),
      ],
    );
    final hold = Completer<void>();
    p.notes.holds['n-78-row-0'] = hold;
    await p.wait(120);
    p.palette.move(1);
    await p.wait(120);
    await p.settle();
    expect(p.reads, ['n-78-row-0', 'n-78-row-1']);
    expect(_wi78Text('Body of row note 1.'), findsWidgets);

    hold.complete();
    await p.settle();
    expect(_wi78Text('Body of row note 1.'), findsWidgets);
    expect(_wi78Text('Body of row note 0.'), findsNothing);
  });

  testWidgets(
    'selecting a canvas shows its title, its card count and up to 8 card titles',
    (tester) async {
      final p = await _wi78PumpPreview(
        tester,
        recent: [
          _wi78Note(
            'cv-78-board',
            'Launch board',
            kind: PaletteNoteKind.canvas,
          ),
        ],
      );
      p.canvas.details['cv-78-board'] = wi89Detail(
        'cv-78-board',
        title: ['Launch board'].join(),
        nodes: [
          for (var i = 0; i < 10; i++)
            wi89Node('n-78-card-$i', 'Card title $i', i * 10.0, 0, zOrder: i),
        ],
      );
      await p.wait(120);
      await p.settle();
      expect(p.canvas.reads, ['cv-78-board']);
      expect(p.notes.reads, isEmpty);
      expect(_wi78Text('Launch board'), findsWidgets);
      expect(_wi78Text('10 cards'), findsWidgets);
      for (var i = 0; i < 8; i++) {
        expect(_wi78Text('Card title $i'), findsWidgets, reason: 'card $i');
      }
      expect(_wi78Text('Card title 8'), findsNothing);
      expect(_wi78Text('Card title 9'), findsNothing);
    },
  );

  testWidgets('at 900x640 no preview is built and no preview read happens', (
    tester,
  ) async {
    final p = await _wi78PumpPreview(
      tester,
      size: paletteNarrowSize,
      recent: [
        _wi78Note('n-78-row-0', 'Row note 0'),
        _wi78Note('n-78-row-1', 'Row note 1'),
      ],
    );
    await p.wait(500);
    p.palette.move(1);
    await p.wait(500);
    await p.settle();
    expect(p.reads, isEmpty);
    expect(_wi78Pane, findsNothing);
    expect(p.preview, isA<PreviewNone>());

    // Control: once the window is wide, the next selection is read.
    tester.view.physicalSize = paletteWideSize;
    await tester.pump();
    p.palette.move(-1);
    await p.wait(120);
    await p.settle();
    expect(p.reads, ['n-78-row-0']);
    expect(_wi78Pane, findsOneWidget);
  });

  group('verify contracts', () {
    testWidgets('the preview shows at exactly 950 px wide and not at 949', (
      tester,
    ) async {
      final p = await _wi78PumpPreview(
        tester,
        size: const Size(950, 700),
        recent: [_wi78Note(_wi78ShortId, 'Pricing model')],
      );
      await p.wait(120);
      await p.settle();
      expect(p.reads, [_wi78ShortId]);
      expect(_wi78Text('Pricing model'), findsWidgets);

      tester.view.physicalSize = const Size(949, 700);
      await tester.pump();
      p.palette.setQuery('x');
      p.palette.setQuery('');
      await p.wait(120);
      await p.settle();
      expect(_wi78Pane, findsNothing);
      expect(p.preview, isA<PreviewNone>());
      expect(p.reads, [_wi78ShortId], reason: 'no read at 949');
    });

    testWidgets('each kind of selection shows its own eyebrow', (tester) async {
      final p = await _wi78PumpPreview(
        tester,
        commands: [CommandItem(PaletteCommand.showDays, label: 'Show Days')],
        recent: [
          _wi78Note(_wi78ShortId, 'Pricing model'),
          _wi78Note('n-78-row-0', 'Row note 0', kind: PaletteNoteKind.daily),
          _wi78Note('cv-78-board', 'Board', kind: PaletteNoteKind.canvas),
        ],
      );
      p.canvas.details['cv-78-board'] = wi89Detail(
        'cv-78-board',
        title: ['Board'].join(),
        nodes: [wi89Node('n-78-card-0', 'Only card', 0, 0, zOrder: 0)],
      );
      await p.wait(0);
      await p.settle();
      expect(_wi78Text('COMMAND'), findsOneWidget);

      p.palette.move(1);
      await p.wait(120);
      await p.settle();
      expect(_wi78Text('NOTE · EDITED 2 H AGO'), findsOneWidget);

      p.palette.move(1);
      await p.wait(120);
      await p.settle();
      expect(_wi78Text('DAILY NOTE · 3 H AGO'), findsOneWidget);

      p.palette.move(1);
      await p.wait(120);
      await p.settle();
      expect(_wi78Text('CANVAS'), findsOneWidget);
      expect(_wi78Text('1 card'), findsOneWidget);
      expect(_wi78Text('1 cards'), findsNothing);
    });

    testWidgets('a passage eyebrow follows its note role and age', (
      tester,
    ) async {
      PassageItem passage(String chunk, {String? role}) => PassageItem(
        SearchHit(
          noteId: [_wi78LongId].join(),
          noteTitle: ['Q3 planning'].join(),
          noteRole: role,
          chunkId: [chunk].join(),
          snippet: _wi78Chunk.trim(),
          startByte: null,
          noteUpdatedAt: paletteHoursAgo(24),
        ),
        meta: 'note · 1 d ago',
      );
      final p = await _wi78PumpPreview(
        tester,
        passages: [
          passage('c-a'),
          passage('c-b', role: 'daily'),
        ],
      );
      p.palette.setQuery('back');
      await tester.pump();
      await p.wait(120);
      await p.settle();
      expect(_wi78Text('NOTE · EDITED 1 D AGO'), findsOneWidget);

      p.palette.move(1);
      await p.wait(120);
      await p.settle();
      expect(_wi78Text('DAILY NOTE · 1 D AGO'), findsOneWidget);
    });

    testWidgets(
      'a window that narrows between the selection and the read reads nothing',
      (tester) async {
        final p = await _wi78PumpPreview(
          tester,
          recent: [_wi78Note(_wi78ShortId, 'Pricing model')],
        );
        await p.wait(60);
        expect(p.preview, isA<PreviewLoading>());

        tester.view.physicalSize = paletteNarrowSize;
        await tester.pump();
        await p.wait(60);
        await p.settle();

        expect(p.reads, isEmpty);
        expect(p.preview, isA<PreviewNone>());
        expect(_wi78Pane, findsNothing);
      },
    );

    testWidgets('a note or canvas that cannot be found shows the error line', (
      tester,
    ) async {
      final p = await _wi78PumpPreview(
        tester,
        recent: [
          _wi78Note('n-78-missing', 'Gone note'),
          _wi78Note(
            'cv-78-missing',
            'Gone board',
            kind: PaletteNoteKind.canvas,
          ),
        ],
      );
      await p.wait(120);
      await p.settle();
      expect(p.reads, ['n-78-missing']);
      expect(p.preview, isA<PreviewFailed>());
      expect(
        _wi78InPane(find.text("couldn't load the preview.")),
        findsOneWidget,
      );

      p.palette.move(1);
      await p.wait(120);
      await p.settle();
      expect(p.canvas.reads, ['cv-78-missing']);
      expect(p.preview, isA<PreviewFailed>());
      expect(
        _wi78InPane(find.text("couldn't load the preview.")),
        findsOneWidget,
      );
    });

    testWidgets(
      'a start_byte past the end or below zero shows the passage from the top with no band',
      (tester) async {
        final p = await _wi78PumpPreview(
          tester,
          passages: [
            _wi78Passage('c-end', startByte: utf8.encode(_wi78LongBody).length),
            _wi78Passage('c-neg', startByte: -1),
          ],
        );
        p.palette.setQuery('back');
        await tester.pump();
        await p.wait(120);
        await p.settle();
        expect(p.reads, [_wi78LongId]);
        expect(_wi78Text('Q3 planning'), findsWidgets);
        expect(_wi78Filled(OmColors.surface3), findsNothing);
        expect(tester.state<ScrollableState>(_wi78Scroll).position.pixels, 0);

        p.palette.move(1);
        await tester.pump();
        await p.wait(120);
        await p.settle();
        expect(_wi78Filled(OmColors.surface3), findsNothing);
        expect(tester.state<ScrollableState>(_wi78Scroll).position.pixels, 0);
      },
    );

    testWidgets(
      'a byte offset after multi-byte text still bands the chunk lines',
      (tester) async {
        const id = 'n-78-accents';
        final body =
            '${[for (var i = 0; i < 40; i++) 'café déjà vu $i\n'].join()}'
            'chunk starts mid line here\nand ends on this one\n'
            '${[for (var i = 0; i < 40; i++) 'after line $i\n'].join()}';
        final start = body.indexOf('starts mid');
        final byte = utf8.encode(body.substring(0, start)).length;
        expect(byte, greaterThan(start), reason: 'bytes and characters differ');
        final p = await _wi78PumpPreview(
          tester,
          seed: (db) => db.seedNote(
            id: id,
            title: 'Accents',
            content: body,
            updatedAt: paletteHoursAgo(5),
          ),
          passages: [
            PassageItem(
              SearchHit(
                noteId: [id].join(),
                noteTitle: ['Accents'].join(),
                chunkId: ['c-acc'].join(),
                snippet: ['starts mid line here\nand ends on this one'].join(),
                startByte: byte,
                noteUpdatedAt: paletteHoursAgo(5),
              ),
              meta: 'note · 5 h ago',
            ),
          ],
        );
        p.palette.setQuery('mid');
        await tester.pump();
        await p.wait(120);
        await p.settle();

        final band = _wi78Filled(OmColors.surface3);
        expect(band, findsOneWidget);
        Finder inBand(String text) => find.descendant(
          of: band,
          matching: find.textContaining(text, findRichText: true),
        );
        // The whole first line and the second, nothing from the neighbours.
        expect(inBand('chunk starts mid line here'), findsWidgets);
        expect(inBand('and ends on this one'), findsWidgets);
        expect(inBand('café déjà vu 39'), findsNothing);
        expect(inBand('after line 0'), findsNothing);
      },
    );

    testWidgets(
      'closing the palette during the 120 ms rest cancels the pending preview read',
      (tester) async {
        final p = await _wi78PumpPreview(
          tester,
          recent: [_wi78Note(_wi78ShortId, 'Pricing model')],
        );
        await p.wait(60);
        expect(p.preview, isA<PreviewLoading>());
        expect(p.reads, isEmpty);

        final pending = p.clock.pendingTimers;
        expect(pending, greaterThan(0), reason: 'the rest timer is pending');

        p.palette.close();
        expect(
          p.clock.pendingTimers,
          pending - 1,
          reason: 'closing cancels the rest timer at once',
        );
        await p.wait(1000);
        await p.settle();

        expect(p.reads, isEmpty, reason: 'the rest timer was cancelled');
      },
    );

    testWidgets(
      'a note preview draws markdown source as plain text and a long note from the top',
      (tester) async {
        const id = 'n-78-markdown';
        final body =
            '## Heading kept as typed\n\n'
            'Some **bold** words and a [link](https://example.com).\n\n'
            '${[for (var i = 0; i < 80; i++) '- bullet $i\n\n'].join()}';
        final p = await _wi78PumpPreview(
          tester,
          seed: (db) => db.seedNote(
            id: id,
            title: 'Markdown note',
            content: body,
            updatedAt: paletteHoursAgo(5),
          ),
          recent: [_wi78Note(id, 'Markdown note')],
        );
        await p.wait(120);
        await p.settle();

        expect(p.reads, [id]);
        expect(_wi78Text('## Heading kept as typed'), findsWidgets);
        expect(
          _wi78Text('Some **bold** words and a [link](https://example.com).'),
          findsWidgets,
        );
        expect(_wi78Text('- bullet 0'), findsWidgets);
        expect(_wi78InPane(find.byType(EditableText)), findsNothing);
        final scroll = tester.state<ScrollableState>(_wi78Scroll);
        expect(scroll.position.pixels, 0, reason: 'from the top');
        expect(
          scroll.position.maxScrollExtent,
          greaterThan(0),
          reason: 'the note is longer than the pane',
        );
      },
    );
  });
}
