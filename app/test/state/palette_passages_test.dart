// WI #78 (56-A4, Spec #59 reqs 17-18, 30-33, 40, 42; design pack 78 C4):
// the Command palette's Passages runner and its state rows and footers.
//
// - Passages run only for a trimmed input of 2+ characters, 250 ms after the
//   last keystroke, one search at a time plus one queued slot that a newer
//   input replaces. Only the latest input's answer shows. Closing cancels
//   the debounce and drops the queue; a late answer changes nothing.
// - After a keystroke the previous rows stay (PassagesDimmed) until the
//   debounce fires; then `searching note text…` shows until the answer.
// - Every C4 state's copy, verbatim, under its frozen key
//   (`palette-passages-<state>`), and each state line in a live region.
// - Typed words are marked in a passage case-insensitively; a `via` hit's
//   meta reads `via <YYYY-MM-DD>`.
// - A `vaultRevisionProvider` change never re-runs Passages (R42).
//
// Seams: palette_pump.dart (FakeSearchAccess, FakeClock); #76's real
// PaletteNotifier with #78's overrides (`palettePassagesOverrides`), a fake
// titles source, and #78's PassagesStateRow and PassagesFooter mounted in a
// 400 px list column. The dimmed look is the shell's (#77): pinned here on
// the state the shell draws it from.
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart' show appRootOverrides;
import 'package:open_memex_app/src/memex_cli.dart' show MemexCliTimeout;
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/palette_passages.dart';
import 'package:open_memex_app/src/state/palette_preview_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';
import 'package:open_memex_app/src/widgets/command_palette/passages_states.dart';

import '../support/font_fetch_hold.dart';
import '../support/palette_pump.dart';
import '../support/search_fakes.dart';

const _wi78Field = Key('wi78-input');

/// The palette, its sources and the Passages state widgets under test.
class _Wi78Rig {
  _Wi78Rig(this.tester, this.h, this.shown);

  final WidgetTester tester;
  final PaletteHarness h;

  /// Whether the list column (and so the palette) is mounted.
  final ValueNotifier<bool> shown;

  ProviderSubscription<PaletteState>? _session;

  FakeSearchAccess get search => h.search;
  PaletteNotifier get palette => h.read(paletteProvider.notifier);
  PaletteState get state => h.read(paletteProvider);
  PassagesView get passages => h.read(palettePassagesProvider);

  /// Every search's query, in order.
  List<String> get queries => [for (final c in search.calls) c.query];

  /// The Passages group, or null when it is left out.
  PaletteGroup? get passagesGroup {
    for (final g in state.groups) {
      if (g.kind == PaletteGroupKind.passages) return g;
    }
    return null;
  }

  /// The chunk ids the Passages group lists.
  List<String> get passageChunks => [
    for (final row in passagesGroup?.rows ?? const <PaletteItem>[])
      (row as PassageItem).hit.chunkId,
  ];

  String? get passageHint => passagesGroup?.hint;

  List<PaletteGroupKind> get kinds => [for (final g in state.groups) g.kind];

  /// Opens a fresh palette session, as #77's shell does (W2).
  Future<void> open() async {
    h.container.invalidate(paletteProvider);
    _session = h.container.listen(
      paletteProvider,
      (_, _) {},
      fireImmediately: true,
    );
    shown.value = true;
    await tester.pump();
    await tester.pump();
  }

  /// Closes the palette as the shell does: `close()`, then the route goes.
  Future<void> close() async {
    palette.close();
    shown.value = false;
    _session?.close();
    _session = null;
    await tester.pump();
    await tester.pump();
  }

  Future<void> type(String query) async {
    palette.setQuery(query);
    await tester.pump();
  }

  /// Moves the fake clock on by [ms] and lets answers land.
  Future<void> wait(int ms) async {
    h.clock.advance(Duration(milliseconds: ms));
    await tester.pump();
    await tester.pump();
  }

  /// Releases the searches held on [gate].
  Future<void> release(Completer<void> gate) async {
    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }
}

Future<_Wi78Rig> _wi78Pump(
  WidgetTester tester, {
  List<NoteItem> Function(String query)? titles,
  bool field = false,
}) async {
  final shown = ValueNotifier(false);
  addTearDown(shown.dispose);
  final h = await pumpPaletteHost(
    tester,
    child: ValueListenableBuilder<bool>(
      valueListenable: shown,
      builder: (context, isShown, _) => !isShown
          ? const SizedBox.shrink()
          : Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (field) const TextField(key: _wi78Field),
                    const PassagesStateRow(),
                    const PassagesFooter(),
                  ],
                ),
              ),
            ),
    ),
    overrides: [
      ...palettePassagesOverrides,
      paletteTitlesSourceProvider.overrideWith(
        (ref) =>
            (q) => titles?.call(q) ?? const [],
      ),
    ],
  );
  final rig = _Wi78Rig(tester, h, shown);
  await rig.open();
  return rig;
}

// Hits and answers built from run-time values (never canonicalised consts).
SearchHit _wi78Hit(
  String chunk, {
  String title = 'Pricing model',
  String snippet = 'The refund window is 30 days for annual plans.',
  String? role,
  String? day,
  String? via,
  int? startByte = 0,
  int hoursAgo = 2,
}) => SearchHit(
  noteId: ['n-78', chunk].join('-'),
  noteTitle: [title].join(),
  noteRole: role,
  day: day,
  chunkId: [chunk].join(),
  snippet: [snippet].join(),
  startByte: startByte,
  via: via,
  noteUpdatedAt: paletteHoursAgo(hoursAgo),
);

SearchReady _wi78Ready(
  List<SearchHit> hits, {
  Semantic semantic = Semantic.on,
}) => SearchReady([...hits], semantic: semantic, truncated: false);

/// The state line under `palette-passages-<state>` reading exactly [text].
Finder _wi78Line(String state, String text) => find.descendant(
  of: find.byKey(PaletteKeys.passagesState(state)),
  matching: find.text(text),
);

/// Every widget keyed `palette-passages-<state>`.
Finder get _wi78AnyState => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('palette-passages-'),
);

/// Whether the primary focus sits at or under the widget [f] finds.
bool _wi78FocusIn(Finder f) {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  final target = f.evaluate().single;
  if (identical(ctx, target)) return true;
  var inside = false;
  ctx.visitAncestorElements((e) {
    if (identical(e, target)) inside = true;
    return !inside;
  });
  return inside;
}

/// [text] shows under `palette-passages-<state>`, inside a live region.
void _wi78ExpectLive(WidgetTester tester, String state, String text) {
  final line = _wi78Line(state, text);
  expect(line, findsOneWidget, reason: '$state reads "$text"');
  var live = false;
  for (SemanticsNode? n = tester.getSemantics(line); n != null; n = n.parent) {
    if (n.getSemanticsData().flagsCollection.isLiveRegion) live = true;
  }
  expect(live, isTrue, reason: 'the $state line is a polite live region');
}

void main() {
  holdFontFetches();

  group('debounce and queue', () {
    testWidgets(
      'typing one character makes no search call, and pr after 250 ms makes one search for pr',
      (tester) async {
        final r = await _wi78Pump(tester);

        await r.type('p');
        await r.wait(1000);
        expect(r.queries, isEmpty, reason: 'under 2 characters');

        await r.type('pr');
        await r.wait(249);
        expect(r.queries, isEmpty, reason: 'not before 250 ms');
        await r.wait(1);
        expect(r.queries, ['pr']);
        expect(r.search.calls.single.allowDownload, isFalse);

        await r.wait(5000);
        expect(r.queries, ['pr'], reason: 'one search per input');
      },
    );

    testWidgets(
      'typing pri, pric and price within 250 ms makes one search for price after the pause',
      (tester) async {
        final r = await _wi78Pump(tester);

        await r.type('pri');
        await r.wait(100);
        await r.type('pric');
        await r.wait(100);
        await r.type('price');
        await r.wait(249);
        expect(r.queries, isEmpty);
        await r.wait(1);
        expect(r.queries, ['price']);
        await r.wait(5000);
        expect(r.queries, ['price']);
      },
    );

    testWidgets(
      'with pri in flight, pric then price queue only price; the pri answer is dropped and price runs and shows',
      (tester) async {
        final r = await _wi78Pump(tester);
        final chunks = <String>[];
        final sub = r.h.container.listen<PassagesView>(
          palettePassagesProvider,
          (_, view) =>
              chunks.addAll([for (final p in view.rows) p.hit.chunkId]),
        );
        addTearDown(sub.close);
        final gate = Completer<void>();
        r.search.gate = gate;
        r.search.enqueue(_wi78Ready([_wi78Hit('c-pri')]));
        r.search.enqueue(_wi78Ready([_wi78Hit('c-price')]));

        await r.type('pri');
        await r.wait(250);
        expect(r.queries, ['pri']);
        expect(r.search.inFlight, 1);

        await r.type('pric');
        await r.wait(250);
        await r.type('price');
        await r.wait(250);
        expect(r.queries, ['pri'], reason: 'one search at a time');

        r.search.gate = null;
        await r.release(gate);
        await r.wait(0);

        expect(r.queries, ['pri', 'price'], reason: 'pric was replaced');
        expect(r.passageChunks, ['c-price']);
        expect(chunks, isNot(contains('c-pri')), reason: 'pri was dropped');
      },
    );

    testWidgets(
      'closing the palette with a search in flight and one queued makes no further call, and the late answer changes nothing',
      (tester) async {
        final r = await _wi78Pump(tester);
        final gate = Completer<void>();
        r.search.gate = gate;
        r.search.enqueue(_wi78Ready([_wi78Hit('c-pri')]));

        await r.type('pri');
        await r.wait(250);
        await r.type('price');
        await r.wait(250);
        expect(r.queries, ['pri']);
        expect(r.search.inFlight, 1);

        final views = <PassagesView>[];
        final sub = r.h.container.listen<PassagesView>(
          palettePassagesProvider,
          (_, view) => views.add(view),
        );
        addTearDown(sub.close);
        r.palette.close();
        await tester.pump();
        final atClose = r.passages;
        views.clear();

        await r.release(gate);
        await r.wait(10000);

        expect(r.queries, ['pri'], reason: 'the queued price never runs');
        expect(views, isEmpty, reason: 'the late answer changes nothing');
        expect(r.passages, same(atClose));
      },
    );

    testWidgets(
      'closing the palette during the debounce cancels the pending search',
      (tester) async {
        final r = await _wi78Pump(tester);

        await r.type('pr');
        await r.wait(100);
        await r.close();
        await r.wait(5000);
        expect(r.queries, isEmpty);

        // Control: a fresh palette searches as usual.
        await r.open();
        await r.type('pr');
        await r.wait(250);
        expect(r.queries, ['pr']);
      },
    );

    testWidgets(
      'after a keystroke the previous passage rows show dimmed until the debounce fires, then searching note text shows until the answer',
      (tester) async {
        final r = await _wi78Pump(tester);
        r.search.enqueue(_wi78Ready([_wi78Hit('c-a')]));
        await r.type('price');
        await r.wait(250);
        expect(r.passages, isA<PassagesShown>());
        expect(r.passageChunks, ['c-a']);

        final gate = Completer<void>();
        r.search.gate = gate;
        r.search.enqueue(_wi78Ready([_wi78Hit('c-b')]));
        await r.type('prices');
        expect(r.passages, isA<PassagesDimmed>());
        expect(r.passageChunks, ['c-a'], reason: 'the previous rows stay');
        expect(r.passageHint, 'keyword + meaning');
        expect(
          find.byKey(PaletteKeys.passagesState('searching')),
          findsNothing,
        );

        await r.wait(249);
        expect(r.passages, isA<PassagesDimmed>());
        expect(r.passageChunks, ['c-a']);

        await r.wait(1);
        expect(r.queries, ['price', 'prices']);
        expect(r.passages, isA<PassagesSearching>());
        expect(
          r.passageChunks,
          isEmpty,
          reason: 'the waiting row replaces them',
        );
        expect(_wi78Line('searching', 'searching note text…'), findsOneWidget);

        await r.release(gate);
        expect(r.passages, isA<PassagesShown>());
        expect(r.passageChunks, ['c-b']);
        expect(
          find.byKey(PaletteKeys.passagesState('searching')),
          findsNothing,
        );
      },
    );
  });

  group('states', () {
    testWidgets(
      'a semantic on answer shows keyword + meaning and every other semantic value shows keyword only',
      (tester) async {
        final r = await _wi78Pump(tester);
        final cases = [
          (Semantic.on, 'keyword + meaning'),
          (Semantic.modelNotDownloaded, 'keyword only'),
          (Semantic.embeddingsOff, 'keyword only'),
          (Semantic.unavailable, 'keyword only'),
          (Semantic.unknown, 'keyword only'),
        ];
        for (var i = 0; i < cases.length; i++) {
          final (semantic, hint) = cases[i];
          r.search.enqueue(_wi78Ready([_wi78Hit('c-$i')], semantic: semantic));
          await r.type('price${'s' * i}');
          await r.wait(250);
          expect(r.passageChunks, ['c-$i'], reason: semantic.name);
          expect(r.passageHint, hint, reason: semantic.name);
        }
      },
    );

    testWidgets(
      'a local model_not_downloaded answer shows the keyword hits, the local model footer and a Tab-reachable download button',
      (tester) async {
        final r = await _wi78Pump(tester, field: true);
        r.search.enqueue(
          _wi78Ready([
            _wi78Hit('c-1'),
            _wi78Hit('c-2'),
          ], semantic: Semantic.modelNotDownloaded),
        );
        await r.type('refund');
        await r.wait(250);

        expect(r.passageChunks, ['c-1', 'c-2']);
        expect(
          _wi78Line(
            'model-not-downloaded',
            'keyword matches only. meaning search needs the local model.',
          ),
          findsOneWidget,
        );
        final button = find.byKey(PaletteKeys.download);
        expect(button, findsOneWidget);
        expect(
          find.descendant(
            of: button,
            matching: find.text('Download model (130 MB)'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(_wi78Field));
        await tester.pump();
        expect(_wi78FocusIn(find.byKey(_wi78Field)), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(_wi78FocusIn(button), isTrue, reason: 'Tab reaches the button');
      },
    );

    testWidgets(
      'embeddings_off shows the vault server footer with no button, and unavailable shows keyword matches only',
      (tester) async {
        final r = await _wi78Pump(tester);
        r.search.enqueue(
          _wi78Ready([_wi78Hit('c-1')], semantic: Semantic.embeddingsOff),
        );
        await r.type('refund');
        await r.wait(250);
        expect(r.passageChunks, ['c-1']);
        expect(
          _wi78Line(
            'embeddings-off',
            'keyword matches only. semantic recall is off on this vault server.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(PaletteKeys.download), findsNothing);

        r.search.enqueue(
          _wi78Ready([_wi78Hit('c-2')], semantic: Semantic.unavailable),
        );
        await r.type('refunds');
        await r.wait(250);
        expect(r.passageChunks, ['c-2']);
        expect(
          _wi78Line('unavailable', 'keyword matches only.'),
          findsOneWidget,
        );
        expect(
          find.byKey(PaletteKeys.passagesState('embeddings-off')),
          findsNothing,
        );
        expect(find.byKey(PaletteKeys.download), findsNothing);
      },
    );

    testWidgets('a semantic on answer shows no Passages footer', (
      tester,
    ) async {
      final r = await _wi78Pump(tester);
      r.search.enqueue(_wi78Ready([_wi78Hit('c-1')]));
      await r.type('refund');
      await r.wait(250);
      expect(r.passageChunks, ['c-1']);
      expect(_wi78AnyState, findsNothing);
      expect(find.byKey(PaletteKeys.download), findsNothing);
    });

    testWidgets(
      'MemexOutdated, ServerOutdated and NoCli each show their one unselectable state row',
      (tester) async {
        final r = await _wi78Pump(tester);
        final cases = [
          (
            SearchUnavailable(MemexOutdated()),
            'memex-outdated',
            'update memex to search note text.',
          ),
          (
            SearchUnavailable(ServerOutdated()),
            'server-outdated',
            'update the vault server to search note text.',
          ),
          (
            SearchUnavailable(SearchNoCli()),
            'no-cli',
            'note text search needs the memex CLI.',
          ),
        ];
        for (var i = 0; i < cases.length; i++) {
          final (answer, state, text) = cases[i];
          r.search.enqueue(answer);
          await r.type('price${'s' * i}');
          await r.wait(250);
          expect(_wi78Line(state, text), findsOneWidget, reason: state);
          expect(find.text('PASSAGES'), findsOneWidget, reason: state);
          expect(r.state.groups, isEmpty, reason: 'state rows are not rows');
          expect(r.state.selected, isNull, reason: 'not selectable');
          expect(r.state.noMatches, isFalse, reason: state);
        }
      },
    );

    testWidgets(
      'a thrown error or a timeout shows the search error row, and the next keystroke searches again',
      (tester) async {
        final r = await _wi78Pump(tester);
        const straight = "couldn't search note text.";

        r.search.enqueue(StateError('boom'));
        await r.type('price');
        await r.wait(250);
        expect(_wi78Line('error', straight), findsOneWidget);
        expect(find.textContaining('boom'), findsNothing);

        r.search.enqueue(_wi78Ready([_wi78Hit('c-1')]));
        await r.type('prices');
        await r.wait(250);
        expect(r.queries, ['price', 'prices'], reason: 'typing retries');
        expect(r.passageChunks, ['c-1']);
        expect(find.byKey(PaletteKeys.passagesState('error')), findsNothing);

        r.search.enqueue(
          MemexCliTimeout([
            'search',
            '--query',
            'pricey',
          ], Duration(seconds: 60)),
        );
        await r.type('pricey');
        await r.wait(250);
        expect(_wi78Line('error', straight), findsOneWidget);
        expect(r.passageChunks, isEmpty);
      },
    );

    testWidgets(
      'Passages with no hits while Notes has rows is left out, and no matches for zzzz appears only after the search answers',
      (tester) async {
        final r = await _wi78Pump(
          tester,
          titles: (q) => q.startsWith('ref')
              ? [
                  NoteItem(
                    noteId: [PaletteSeeds.pricingModel].join(),
                    kind: PaletteNoteKind.note,
                    title: ['Refund policy'].join(),
                    meta: 'note · 2 h ago',
                  ),
                ]
              : const [],
        );
        r.search.enqueue(
          _wi78Ready(const [], semantic: Semantic.modelNotDownloaded),
        );
        await r.type('refund');
        await r.wait(250);
        expect(r.queries, ['refund']);
        expect(r.kinds, [PaletteGroupKind.notes]);
        expect(_wi78AnyState, findsNothing, reason: 'no header, no footer');
        expect(find.byKey(PaletteKeys.download), findsNothing);
        expect(find.byKey(PaletteKeys.noMatches), findsNothing);

        final gate = Completer<void>();
        r.search.gate = gate;
        await r.type('zzzz');
        expect(r.state.noMatches, isFalse, reason: 'Passages has not answered');
        expect(find.byKey(PaletteKeys.noMatches), findsNothing);
        await r.wait(250);
        expect(r.queries, ['refund', 'zzzz']);
        expect(r.state.noMatches, isFalse);
        expect(find.byKey(PaletteKeys.noMatches), findsNothing);
        expect(_wi78Line('searching', 'searching note text…'), findsOneWidget);

        await r.release(gate);
        expect(r.state.noMatches, isTrue);
        expect(
          find.descendant(
            of: find.byKey(PaletteKeys.noMatches),
            matching: find.text('no matches for “zzzz”'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(PaletteKeys.passagesState('searching')),
          findsNothing,
        );

        // Under 2 characters Passages doesn't run: it shows straight away.
        await r.type('z');
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(PaletteKeys.noMatches),
            matching: find.text('no matches for “z”'),
          ),
          findsOneWidget,
        );
        expect(r.queries, ['refund', 'zzzz']);
      },
    );
  });

  group('passage rows', () {
    testWidgets(
      'typed words in a passage are marked case-insensitively and a via hit meta shows via 2026-11-17',
      (tester) async {
        final r = await _wi78Pump(tester);
        const text =
            'The Refund window is 30 days; refund requests after it are declined.';
        r.search.enqueue(
          _wi78Ready([
            _wi78Hit('c-a', snippet: text),
            _wi78Hit(
              'c-b',
              title: '2026-11-12',
              snippet: 'Money back inside a month for yearly plans.',
              role: 'daily',
              day: '2026-11-12',
              hoursAgo: 6 * 24,
            ),
            _wi78Hit(
              'c-c',
              title: 'Support',
              snippet: 'Annual plans can be returned.',
              role: 'topic',
              via: '2026-11-17',
            ),
          ]),
        );
        await r.type('refund WINDOW');
        await r.wait(250);
        expect(r.passagesGroup, isNotNull, reason: 'the hits are listed');

        final rows = [
          for (final row in r.passagesGroup!.rows) row as PassageItem,
        ];
        expect([for (final p in rows) p.hit.chunkId], ['c-a', 'c-b', 'c-c']);

        final marks = [...rows[0].marks]
          ..sort((a, b) => a.start.compareTo(b.start));
        int at(String s) => text.indexOf(s);
        expect(marks, [
          TextRange(start: at('Refund'), end: at('Refund') + 6),
          TextRange(start: at('window'), end: at('window') + 6),
          TextRange(start: at('refund req'), end: at('refund req') + 6),
        ]);
        expect(rows[1].marks, isEmpty, reason: 'a meaning-only hit');

        expect(rows[0].meta, 'note · 2 h ago');
        expect(rows[1].meta, 'daily · 6 d ago');
        expect(rows[2].meta, 'via 2026-11-17');
      },
    );
  });

  group('revision and accessibility', () {
    testWidgets(
      'a vaultRevisionProvider change after a search makes no further search call',
      (tester) async {
        final r = await _wi78Pump(tester);
        r.search.enqueue(_wi78Ready([_wi78Hit('c-a')]));
        await r.type('price');
        await r.wait(250);
        expect(r.queries, ['price']);
        expect(r.passageChunks, ['c-a']);

        r.h.container.read(vaultRevisionProvider.notifier).state++;
        await r.wait(20000);
        r.h.container.read(vaultRevisionProvider.notifier).state++;
        await r.wait(20000);

        expect(r.queries, ['price'], reason: 'R42: no Passages re-run');
        expect(r.passageChunks, ['c-a']);
      },
    );

    testWidgets('the Passages state lines are a polite live region', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final r = await _wi78Pump(tester);
      const straightError = "couldn't search note text.";
      final cases = <(Object, String, String)>[
        (
          _wi78Ready([_wi78Hit('c-1')], semantic: Semantic.modelNotDownloaded),
          'model-not-downloaded',
          'keyword matches only. meaning search needs the local model.',
        ),
        (
          _wi78Ready([_wi78Hit('c-2')], semantic: Semantic.embeddingsOff),
          'embeddings-off',
          'keyword matches only. semantic recall is off on this vault server.',
        ),
        (
          _wi78Ready([_wi78Hit('c-3')], semantic: Semantic.unavailable),
          'unavailable',
          'keyword matches only.',
        ),
        (
          SearchUnavailable(MemexOutdated()),
          'memex-outdated',
          'update memex to search note text.',
        ),
        (
          SearchUnavailable(ServerOutdated()),
          'server-outdated',
          'update the vault server to search note text.',
        ),
        (
          SearchUnavailable(SearchNoCli()),
          'no-cli',
          'note text search needs the memex CLI.',
        ),
        (StateError('boom'), 'error', straightError),
      ];
      for (var i = 0; i < cases.length; i++) {
        final (answer, state, text) = cases[i];
        r.search.enqueue(answer);
        await r.type('price${'s' * i}');
        await r.wait(250);
        _wi78ExpectLive(tester, state, text);
      }

      final gate = Completer<void>();
      r.search.gate = gate;
      await r.type('searching');
      await r.wait(250);
      _wi78ExpectLive(tester, 'searching', 'searching note text…');
      await r.release(gate);
      semantics.dispose();
    });
  });
  group('verify contracts', () {
    testWidgets('the no matches row is a live region with no Passages header', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final r = await _wi78Pump(tester);
      await r.type('zzzz');
      await r.wait(250);

      final line = find.descendant(
        of: find.byKey(PaletteKeys.noMatches),
        matching: find.text('no matches for “zzzz”'),
      );
      expect(line, findsOneWidget);
      var live = false;
      for (
        SemanticsNode? n = tester.getSemantics(line);
        n != null;
        n = n.parent
      ) {
        if (n.getSemanticsData().flagsCollection.isLiveRegion) live = true;
      }
      expect(live, isTrue);
      expect(find.text('PASSAGES'), findsNothing);
      semantics.dispose();
    });

    testWidgets(
      'on a hosted vault model_not_downloaded shows keyword matches only with no button',
      (tester) async {
        final r = await _wi78Pump(tester);
        r.h.container.read(currentVaultProvider.notifier).state =
            const HostedVaultRef('srv-78', 'Team vault');
        await tester.pump();
        r.search.enqueue(
          _wi78Ready([_wi78Hit('c-1')], semantic: Semantic.modelNotDownloaded),
        );
        await r.type('price');
        await r.wait(250);

        expect(r.passageChunks, ['c-1']);
        expect(
          _wi78Line('unavailable', 'keyword matches only.'),
          findsOneWidget,
        );
        expect(find.byKey(PaletteKeys.download), findsNothing);
        expect(
          find.byKey(PaletteKeys.passagesState('model-not-downloaded')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'repeating the same input after its answer makes no second search',
      (tester) async {
        final r = await _wi78Pump(tester);
        r.search.enqueue(_wi78Ready([_wi78Hit('c-a')]));
        await r.type('price');
        await r.wait(250);
        expect(r.queries, ['price']);

        await r.type('price');
        await r.wait(5000);
        expect(r.queries, ['price'], reason: 'the same input is a no-op');
        expect(r.passages, isA<PassagesShown>(), reason: 'rows are not dimmed');
        expect(r.passageChunks, ['c-a']);
      },
    );

    testWidgets(
      'typing under two characters drops the queued input and shows nothing',
      (tester) async {
        final r = await _wi78Pump(tester);
        final gate = Completer<void>();
        r.search.gate = gate;
        await r.type('pri');
        await r.wait(250);
        await r.type('pric');
        await r.wait(250);
        expect(r.queries, ['pri']);

        await r.type('p');
        expect(r.passages, isA<PassagesIdle>());
        r.search.gate = null;
        await r.release(gate);
        await r.wait(5000);

        expect(r.queries, ['pri'], reason: 'the queued pric never runs');
        expect(r.passages, isA<PassagesIdle>());
        expect(r.passagesGroup, isNull);
      },
    );

    testWidgets(
      'switching vault with a search in flight shows nothing from the old vault',
      (tester) async {
        final r = await _wi78Pump(tester);
        final gate = Completer<void>();
        r.search.gate = gate;
        r.search.enqueue(_wi78Ready([_wi78Hit('c-old')]));
        await r.type('price');
        await r.wait(250);
        expect(r.queries, ['price']);

        r.h.container.read(currentVaultProvider.notifier).state = LocalVaultRef(
          ['/vaults', 'Other Vault'].join('/'),
        );
        await tester.pump();
        r.search.gate = null;
        await r.release(gate);
        await r.wait(5000);

        expect(r.passageChunks, isEmpty);
        expect(r.passages, isNot(isA<PassagesShown>()));
        expect(r.queries, ['price'], reason: 'no further call');
      },
    );

    test(
      'passageMarks merges overlapping ranges and keeps touching ones apart',
      () {
        expect(passageMarks('abcd', 'ab bc'), [
          const TextRange(start: 0, end: 3),
        ]);
        expect(passageMarks('abcd', 'abcd bc'), [
          const TextRange(start: 0, end: 4),
        ]);
        expect(passageMarks('abcd', 'cd ab'), [
          const TextRange(start: 0, end: 2),
          const TextRange(start: 2, end: 4),
        ]);
        expect(passageMarks('a.b axb', 'a.b'), [
          const TextRange(start: 0, end: 3),
        ], reason: 'a typed dot is literal');
        expect(passageMarks('Price PRICE price', '  price '), [
          const TextRange(start: 0, end: 5),
          const TextRange(start: 6, end: 11),
          const TextRange(start: 12, end: 17),
        ]);
        expect(passageMarks('abc', '   '), isEmpty);
        expect(passageMarks('abc', 'zz'), isEmpty);
      },
    );

    test('paletteAge reads just now under an hour and h, d and w after', () {
      final now = DateTime(2026, 11, 18, 9);
      String age(Duration ago) =>
          paletteAge(now.subtract(ago).millisecondsSinceEpoch, now);
      expect(age(const Duration(minutes: 59)), 'just now');
      expect(age(const Duration(hours: 1)), '1 h ago');
      expect(age(const Duration(hours: 23, minutes: 59)), '23 h ago');
      expect(age(const Duration(hours: 24)), '1 d ago');
      expect(age(const Duration(days: 6, hours: 23)), '6 d ago');
      expect(age(const Duration(days: 7)), '1 w ago');
      expect(age(const Duration(days: 15)), '2 w ago');
      expect(
        paletteAge(
          now.add(const Duration(hours: 3)).millisecondsSinceEpoch,
          now,
        ),
        'just now',
        reason: 'a backward clock never reads negative',
      );
    });

    test('passageMeta reads daily for a daily note and via before the age', () {
      final now = DateTime(2026, 11, 18, 9);
      SearchHit hit({String? role, String? via}) => SearchHit(
        noteId: ['n'].join(),
        noteTitle: ['t'].join(),
        noteRole: role,
        chunkId: ['c'].join(),
        snippet: ['s'].join(),
        via: via,
        noteUpdatedAt: now
            .subtract(const Duration(hours: 5))
            .millisecondsSinceEpoch,
      );
      expect(passageMeta(hit(role: 'daily'), now), 'daily · 5 h ago');
      expect(passageMeta(hit(role: 'topic'), now), 'note · 5 h ago');
      expect(passageMeta(hit(), now), 'note · 5 h ago');
      expect(
        passageMeta(hit(role: 'daily', via: '2026-11-17'), now),
        'via 2026-11-17',
      );
    });
  });

  group('app root wiring', () {
    testWidgets(
      'appRootOverrides fills the Passages, preview and passage chooser seams',
      (tester) async {
        final h = await pumpPaletteHost(tester, overrides: appRootOverrides);

        expect(
          h.read(palettePassagesProvider.notifier),
          isA<PalettePassagesRunner>(),
        );
        expect(
          h.read(palettePreviewProvider.notifier),
          isA<PalettePreviewReader>(),
        );

        // Behaviour, not just types: the debounced search runs ...
        h.container.listen(paletteProvider, (_, _) {}, fireImmediately: true);
        h.read(paletteProvider.notifier).setQuery('pr');
        h.clock.advance(const Duration(milliseconds: 250));
        await tester.pump();
        await tester.pump();
        expect([for (final c in h.search.calls) c.query], ['pr']);

        // ... and choosing a passage navigates to its note.
        h.read(palettePassageChooserProvider)(
          PassageItem(_wi78Hit('c-root', startByte: 3), meta: 'note · 2 h ago'),
          newTab: false,
        );
        expect(h.tabs.navigated, [NoteTab('n-78-c-root')]);
      },
    );
  });
}
