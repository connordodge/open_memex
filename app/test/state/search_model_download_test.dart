// WI #78 (56-A4, Spec #59 req 31, TD4, TD9; design pack 78 C4 states 2-3):
// the Command palette's model download.
//
// - `Download model (130 MB)` runs `search(<current input>, allowDownload:
//   true)` once (two presses in one frame start one download) and shows
//   `downloading the model… keyword matches until it's done.`.
// - The download lives in `searchModelDownloadProvider(<VaultRef>)`
//   (non-autoDispose): it keeps running after the palette closes, and a
//   reopened palette for that vault shows Downloading and starts no second
//   download.
// - Success (`semantic: on`) while the palette is open re-runs the current
//   input; any other answer, a throw or a timeout brings the
//   model-not-downloaded footer and button back, without a cause line.
// - It leaves the Echoes tab's download alone.
//
// Seams: palette_pump.dart (FakeSearchAccess with a gate, FakeClock); #76's
// PaletteNotifier with `palettePassagesOverrides`; #78's PassagesStateRow and
// PassagesFooter mounted in a 400 px list column.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart' show MemexCliTimeout;
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/echoes_state.dart';
import 'package:open_memex_app/src/state/palette_passages.dart';
import 'package:open_memex_app/src/state/search_model_download.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';
import 'package:open_memex_app/src/widgets/command_palette/passages_states.dart';

import '../support/font_fetch_hold.dart';
import '../support/palette_pump.dart';
import '../support/search_fakes.dart';

const _wi78Downloading =
    "downloading the model… keyword matches until it's done.";
const _wi78NotDownloaded =
    'keyword matches only. meaning search needs the local model.';

class _Wi78DownloadRig {
  _Wi78DownloadRig(this.tester, this.h, this.shown);

  final WidgetTester tester;
  final PaletteHarness h;
  final ValueNotifier<bool> shown;

  ProviderSubscription<PaletteState>? _session;

  FakeSearchAccess get search => h.search;
  PaletteNotifier get palette => h.read(paletteProvider.notifier);
  PaletteState get state => h.read(paletteProvider);

  /// Every search as (query, allowDownload), in order.
  List<(String, bool)> get calls => [
    for (final c in search.calls) (c.query, c.allowDownload),
  ];

  /// The queries of the download calls.
  List<String> get downloads => [
    for (final c in search.calls)
      if (c.allowDownload) c.query,
  ];

  PaletteGroup? get passagesGroup {
    for (final g in state.groups) {
      if (g.kind == PaletteGroupKind.passages) return g;
    }
    return null;
  }

  List<String> get passageChunks => [
    for (final row in passagesGroup?.rows ?? const <PaletteItem>[])
      (row as PassageItem).hit.chunkId,
  ];

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

  Future<void> wait(int ms) async {
    h.clock.advance(Duration(milliseconds: ms));
    await tester.pump();
    await tester.pump();
  }

  Future<void> release(Completer<void> gate) async {
    gate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  /// Types [query] and lets its model-not-downloaded answer with two keyword
  /// hits land.
  Future<void> keywordOnly(String query) async {
    search.enqueue(
      _wi78Ready([
        _wi78Hit('c-1'),
        _wi78Hit('c-2'),
      ], semantic: Semantic.modelNotDownloaded),
    );
    await type(query);
    await wait(250);
    expect(passageChunks, ['c-1', 'c-2'], reason: 'the keyword hits show');
  }

  Future<void> pressDownload() async {
    await tester.tap(find.byKey(PaletteKeys.download));
    await tester.pump();
    await tester.pump();
  }
}

Future<_Wi78DownloadRig> _wi78Pump(WidgetTester tester) async {
  final shown = ValueNotifier(false);
  addTearDown(shown.dispose);
  final h = await pumpPaletteHost(
    tester,
    child: ValueListenableBuilder<bool>(
      valueListenable: shown,
      builder: (context, isShown, _) => !isShown
          ? const SizedBox.shrink()
          : const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [PassagesStateRow(), PassagesFooter()],
                ),
              ),
            ),
    ),
    overrides: palettePassagesOverrides,
  );
  final rig = _Wi78DownloadRig(tester, h, shown);
  await rig.open();
  return rig;
}

SearchHit _wi78Hit(String chunk) => SearchHit(
  noteId: ['n-78', chunk].join('-'),
  noteTitle: ['Pricing model'].join(),
  chunkId: [chunk].join(),
  snippet: ['The refund window is 30 days', chunk].join(' '),
  startByte: chunk.length,
  noteUpdatedAt: paletteHoursAgo(2),
);

SearchReady _wi78Ready(
  List<SearchHit> hits, {
  Semantic semantic = Semantic.on,
}) => SearchReady([...hits], semantic: semantic, truncated: false);

Finder _wi78Line(String state, String text) => find.descendant(
  of: find.byKey(PaletteKeys.passagesState(state)),
  matching: find.text(text),
);

void main() {
  holdFontFetches();

  testWidgets(
    'pressing Download calls search with the current input and allowDownload once and shows the downloading line',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final r = await _wi78Pump(tester);
      await r.keywordOnly('price');
      final gate = Completer<void>();
      r.search.gate = gate;

      // Two presses in one frame start one download.
      await tester.tap(find.byKey(PaletteKeys.download));
      await tester.tap(find.byKey(PaletteKeys.download));
      await tester.pump();
      await tester.pump();

      expect(r.downloads, ['price']);
      expect(r.calls, [('price', false), ('price', true)]);
      final line = _wi78Line('downloading', _wi78Downloading);
      expect(line, findsOneWidget);
      expect(find.byKey(PaletteKeys.download), findsNothing);
      expect(r.passageChunks, ['c-1', 'c-2'], reason: 'keyword hits stay');
      expect(r.passagesGroup!.hint, 'keyword only');

      var live = false;
      for (SemanticsNode? n = tester.getSemantics(line); n != null; n = n.parent) {
        if (n.getSemanticsData().flagsCollection.isLiveRegion) live = true;
      }
      expect(live, isTrue, reason: 'the downloading line is a live region');

      await r.release(gate);
      semantics.dispose();
    },
  );

  testWidgets(
    'closing and reopening the palette during the download shows the downloading line and makes no second download call',
    (tester) async {
      final r = await _wi78Pump(tester);
      await r.keywordOnly('price');
      final gate = Completer<void>();
      r.search.gate = gate;
      await r.pressDownload();
      expect(r.downloads, ['price']);

      await r.close();
      await r.wait(5000);
      expect(r.search.inFlight, 1, reason: 'closing never cancels it');

      r.search.gate = null;
      await r.open();
      await r.keywordOnly('price');

      expect(_wi78Line('downloading', _wi78Downloading), findsOneWidget);
      expect(find.byKey(PaletteKeys.download), findsNothing);
      expect(r.downloads, ['price'], reason: 'no second download');

      await r.release(gate);
    },
  );

  testWidgets(
    'a download answering semantic on while the palette is open runs the current input again and shows keyword + meaning',
    (tester) async {
      final r = await _wi78Pump(tester);
      await r.keywordOnly('price');
      final gate = Completer<void>();
      r.search.gate = gate;
      r.search.enqueue(_wi78Ready([_wi78Hit('c-1'), _wi78Hit('c-2')]));
      await r.pressDownload();
      expect(r.downloads, ['price']);

      r.search.gate = null;
      r.search.enqueue(_wi78Ready([_wi78Hit('c-1'), _wi78Hit('c-3')]));
      await r.release(gate);
      await r.wait(250);

      expect(r.calls, [('price', false), ('price', true), ('price', false)]);
      expect(r.passageChunks, ['c-1', 'c-3'], reason: 'the re-run shows');
      expect(r.passagesGroup!.hint, 'keyword + meaning');
      expect(find.byKey(PaletteKeys.passagesState('downloading')), findsNothing);
      expect(
        find.byKey(PaletteKeys.passagesState('model-not-downloaded')),
        findsNothing,
      );
      expect(find.byKey(PaletteKeys.download), findsNothing);
    },
  );

  testWidgets(
    'a download answering unavailable, throwing or timing out brings back the model_not_downloaded footer and button',
    (tester) async {
      final r = await _wi78Pump(tester);
      await r.keywordOnly('price');
      final failures = <(String, Object)>[
        ('unavailable', _wi78Ready(const [], semantic: Semantic.unavailable)),
        ('a throw', StateError('model fetch failed')),
        (
          'a timeout',
          MemexCliTimeout([
            'search',
            '--allow-download',
          ], Duration(minutes: 10)),
        ),
      ];
      for (final (name, answer) in failures) {
        r.search.enqueue(answer);
        await r.pressDownload();
        expect(
          _wi78Line('model-not-downloaded', _wi78NotDownloaded),
          findsOneWidget,
          reason: name,
        );
        expect(find.byKey(PaletteKeys.download), findsOneWidget, reason: name);
        expect(
          find.byKey(PaletteKeys.passagesState('downloading')),
          findsNothing,
          reason: name,
        );
        expect(find.textContaining('fetch failed'), findsNothing);
        expect(find.textContaining('MemexCliTimeout'), findsNothing);
        expect(r.passageChunks, ['c-1', 'c-2'], reason: name);
        expect(r.passagesGroup!.hint, 'keyword only', reason: name);
      }
      expect(r.downloads, ['price', 'price', 'price']);
    },
  );

  testWidgets('the download state is kept per vault and outlives the palette', (
    tester,
  ) async {
    final r = await _wi78Pump(tester);
    final here = LocalVaultRef([paletteVaultPath].join());
    final other = LocalVaultRef(['/vaults', 'Other Vault'].join('/'));
    await r.keywordOnly('price');
    final gate = Completer<void>();
    r.search.gate = gate;
    await r.pressDownload();

    expect(
      r.h.read(searchModelDownloadProvider(here)),
      SearchModelDownloadStatus.downloading,
    );
    expect(
      r.h.read(searchModelDownloadProvider(other)),
      SearchModelDownloadStatus.idle,
    );

    await r.close();
    await r.wait(5000);
    expect(
      r.h.read(searchModelDownloadProvider(here)),
      SearchModelDownloadStatus.downloading,
    );

    await r.release(gate);
    expect(
      r.h.read(searchModelDownloadProvider(here)),
      SearchModelDownloadStatus.succeeded,
      reason: 'the default answer is semantic on',
    );
    expect(r.downloads, ['price']);
  });

  testWidgets('the palette download leaves the Echoes download state alone', (
    tester,
  ) async {
    final r = await _wi78Pump(tester);
    await r.keywordOnly('price');
    await r.pressDownload();
    expect(r.downloads, ['price']);
    await r.wait(1000);

    expect(r.h.cli!.callsFor('echoes'), isEmpty);
    expect(r.h.container.exists(echoesAsyncProvider), isFalse);
  });
}
