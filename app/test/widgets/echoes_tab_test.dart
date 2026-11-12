// #427 (391-A3): the right panel's echoes tab (Spec #391 reqs 22, 25-28,
// 30, 32-36; Interview Ledger L1, L3, L5; rulings D8-D10, D16, D25, D26).
//
// - Every state of `echoesAsyncProvider` has its exact copy in fg2 mono
//   (D26) under the header (`echoes · forgotten threads` and its subtitle),
//   including the 400 ms first-load delay on `clockProvider` and
//   `still indexing · <n> passages left` under a list and the empty copy.
// - Download flow: `Download model (130 MB)` (Key `echo-download`) calls
//   `download()`; downloading hides it; failure shows the cause and `retry`.
// - Rows: title in accent, age in fg2 mono at its right, passage through
//   `markdownPreviewText` in at most 3 ellipsized lines with the full text
//   in a tooltip; `link` per `echoLinkPlan` with a busy guard, row removal
//   on success, an in-row `InlineError` on failure, a `not_found` re-read.
// - Open: title or passage `follow(NoteTab(id))` and the scroll target; a
//   press in the `echo-link-<id>` box does neither.
// - Semantics labels, Enter to open, and no overflow at 1.5x text scale in
//   the 340 px panel. GLOSSARY.md's Echo entry.
//
// Seams: A0's `pumpEchoesTab` (FakeEchoesAccess, FakeEchoLinkActions,
// FakeClock), `TabsRecorder`, and a recording `EchoesNotifier` subclass so
// each notifier call is counted while the real provider keeps running.
// Time only moves through FakeClock: no real timers, no wall-clock waits.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart' show Note;
import 'package:open_memex_app/src/editor/markdown_preview_text.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/echo_link_actions.dart';
import 'package:open_memex_app/src/state/echo_scroll_target.dart';
import 'package:open_memex_app/src/state/echoes_state.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/echoes_fakes.dart';
import '../support/echoes_pump.dart';
import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';
import '../support/recording_tabs.dart';

// ---------------------------------------------------------------- copy

const _subtitle =
    'past notes the indexer thinks you\'d want now. all from your own '
    'writing — never an outside source.';
const _noNote = 'select a note to see its echoes.';
const _nothingWritten = 'write something and echoes will surface here.';
const _listening = 'listening for echoes…';
const _nothingYet = 'nothing surfaced yet.';
const _appearWhen = 'echoes appear when older writing is close to this note.';
String _stillIndexing(int n) => 'still indexing · $n passages left';
const _embeddingsOff =
    'semantic recall is off on this vault server — start it with '
    '--with-embeddings to see echoes.';
const _modelMissing = "echoes run on a local model that isn't downloaded yet.";
const _downloadLabel = 'Download model (130 MB)';
const _downloadSemantics = 'Download the embedding model, 130 megabytes';
const _downloading = 'downloading the model…';
const _couldntLoad = "couldn't load the embedding model.";
const _noCli = 'echoes need the memex CLI.';
const _outdated = 'update memex to see echoes.';

/// The old placeholder's second line, which the tab no longer shows.
const _oldPlaceholder = 'semantic recall lights this up';

/// The header's eyebrow as `Eyebrow` draws it (upper case).
final _eyebrow = find.text('echoes · forgotten threads'.toUpperCase());

/// Every state line, so a test can assert none but its own shows.
const _allStateCopy = [
  _noNote,
  _nothingWritten,
  _listening,
  _nothingYet,
  _appearWhen,
  'still indexing',
  _embeddingsOff,
  _modelMissing,
  _downloading,
  _couldntLoad,
  _noCli,
  _outdated,
  _oldPlaceholder,
];

// ---------------------------------------------------------------- fixtures

/// FakeClock's default start (2026-10-03 09:00 local).
final _now = DateTime(2026, 10, 3, 9);

int _msAgo(Duration d) => _now.millisecondsSinceEpoch - d.inMilliseconds;

const _levelId = '01JECHOLEVEL0000000000000A';
const _gardenId = '01JECHOGARDN0000000000000B';
const _dailyId = '01JECHODAILY0000000000000C';
const _otherOpenId = '01JECHOOTHER0000000000000D';

/// One echo, built at run time (never const). Defaults: the topic note
/// "Level Design", updated 21 days before the clock, a plain passage.
Echo _echo({
  String id = _levelId,
  String title = 'Level Design',
  String? role = 'topic',
  String? day,
  String passage = 'Levels teach by showing.',
  int? startByte = 42,
  int? updatedAt,
}) => Echo(
  noteId: id,
  noteTitle: title,
  noteRole: role,
  day: day,
  passage: passage,
  startByte: startByte,
  noteUpdatedAt: updatedAt ?? _msAgo(const Duration(days: 21)),
);

Echo _garden() => _echo(
  id: _gardenId,
  title: 'Garden',
  role: null,
  passage: 'Tomatoes want more sun.',
  startByte: 7,
  updatedAt: _msAgo(const Duration(hours: 3)),
);

EchoesReady _ready(List<Echo> echoes, {int pending = 0}) =>
    EchoesReady(echoes, emptyNote: false, pending: pending);

/// `echoesAsyncProvider`'s notifier with every public call counted; each
/// call still runs the real notifier.
class _Wi427EchoesNotifier extends EchoesNotifier {
  int downloads = 0;
  int retries = 0;
  int linksCompleted = 0;

  @override
  Future<void> download() {
    downloads++;
    return super.download();
  }

  @override
  Future<void> retry() {
    retries++;
    return super.retry();
  }

  @override
  Future<void> linkCompleted() {
    linksCompleted++;
    return super.linkCompleted();
  }
}

/// The pumped tab, its recorder and its counting notifier.
class _Tab {
  _Tab(this.h, this.tabs);

  final EchoesTabHarness h;
  final TabsRecorder tabs;

  _Wi427EchoesNotifier get notifier =>
      h.read(echoesAsyncProvider.notifier) as _Wi427EchoesNotifier;

  FakeEchoesAccess get echoes => h.echoes;
  FakeEchoLinkActions get links => h.links;
  FakeClock get clock => h.clock;

  void select(String? noteId) =>
      h.container.read(selectedNoteIdProvider.notifier).state = noteId;
}

Future<_Tab> _pump(
  WidgetTester tester, {
  EchoesResult? result,
  FakeEchoesAccess? echoes,
  FakeEchoLinkActions? links,
  String? noteId = echoesOpenNoteId,
  String? openRole,
  bool seedOpenNote = true,
  double textScale = 0.5,
  List<Override> extraOverrides = const [],
}) async {
  final tabs = TabsRecorder();
  final h = await pumpEchoesTab(
    tester,
    echoes:
        echoes ?? FakeEchoesAccess(result: result, vaultPath: echoesVaultPath),
    links: links,
    noteId: noteId,
    openRole: openRole,
    seedOpenNote: seedOpenNote,
    textScale: textScale,
    overrides: [
      tabs.override,
      echoesAsyncProvider.overrideWith(_Wi427EchoesNotifier.new),
      ...extraOverrides,
    ],
  );
  await pumpFrames(tester);
  return _Tab(h, tabs);
}

// ---------------------------------------------------------------- finders

Finder _row(String id) => find.byKey(Key('echo-row-$id'));
Finder _open(String id) => find.byKey(Key('echo-open-$id'));
Finder _linkBox(String id) => find.byKey(Key('echo-link-$id'));
final _download = find.byKey(const Key('echo-download'));

/// The `OmButton` that is or sits inside the `echo-link-<id>` box.
Finder _linkButton(String id) => find.descendant(
  of: _linkBox(id),
  matching: find.byType(OmButton),
  matchRoot: true,
);

Finder _inRow(String id, Finder f) =>
    find.descendant(of: _row(id), matching: f);

/// The text widget whose text contains [copy] (one widget may hold two
/// state lines).
Finder _copy(String copy) => find.textContaining(copy);

/// The style a text is drawn with: its `RichText`'s root span style, which
/// already merges `DefaultTextStyle`.
TextStyle _drawnStyle(WidgetTester tester, Finder text) {
  final rich = tester.widget<RichText>(
    find
        .descendant(of: text, matching: find.byType(RichText), matchRoot: true)
        .first,
  );
  return rich.text.style!;
}

/// JetBrains Mono's family prefix (google_fonts adds `_<weight>`).
String get _monoFamily => OmType.mono().fontFamily!.split('_').first;

void _expectFg2Mono(WidgetTester tester, Finder text, {String? what}) {
  expect(text, findsOneWidget, reason: what);
  final style = _drawnStyle(tester, text);
  expect(style.color, OmColors.fg2, reason: '${what ?? text} is fg2 (D26)');
  expect(
    style.fontFamily,
    startsWith(_monoFamily),
    reason: '${what ?? text} is mono',
  );
}

/// [first] reads before [second]: earlier in one text widget, or above.
void _expectBefore(WidgetTester tester, String first, String second) {
  final a = _copy(first);
  final b = _copy(second);
  expect(a, findsOneWidget, reason: first);
  expect(b, findsOneWidget, reason: second);
  if (a.evaluate().single == b.evaluate().single) {
    final text = tester.widget<Text>(a).data ?? '';
    expect(
      text.indexOf(first),
      lessThan(text.indexOf(second)),
      reason: '$first before $second',
    );
  } else {
    expect(
      tester.getRect(a).bottom,
      lessThanOrEqualTo(tester.getRect(b).top + 0.5),
      reason: '$first above $second',
    );
  }
}

/// The header shows, and no state copy other than [except].
void _expectHeaderAndOnly(List<String> except) {
  expect(_eyebrow, findsOneWidget, reason: 'the eyebrow (req 25)');
  expect(find.text(_subtitle), findsOneWidget, reason: 'the subtitle');
  for (final copy in _allStateCopy) {
    if (except.any((e) => e.contains(copy) || copy.contains(e))) continue;
    expect(_copy(copy), findsNothing, reason: '"$copy" is not this state');
  }
}

bool _rectInside(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

/// Tab until the primary focus is a node inside [target] but not inside
/// [notInside].
Future<void> _tabInto(
  WidgetTester tester,
  Finder target, {
  Finder? notInside,
}) async {
  for (var i = 0; i < 16; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) continue;
    final rect = focus.rect;
    if (!_rectInside(tester.getRect(target), rect)) continue;
    if (notInside != null && _rectInside(tester.getRect(notInside), rect)) {
      continue;
    }
    return;
  }
  fail('no focus stop inside $target');
}

void main() {
  holdFontFetches();

  // ================================================================ AC1
  group('AC1 states', () {
    testWidgets('no note selected shows the select a note copy in fg2 mono', (
      tester,
    ) async {
      final t = await _pump(tester, noteId: null);

      _expectFg2Mono(tester, _copy(_noNote));
      _expectHeaderAndOnly([_noNote]);
      expect(t.echoes.calls, isEmpty);
    });

    testWidgets(
      'the virtual Today note shows the write something copy without a read',
      (tester) async {
        final t = await _pump(tester, noteId: 'virtual-today:2026-10-03');

        _expectFg2Mono(tester, _copy(_nothingWritten));
        _expectHeaderAndOnly([_nothingWritten]);
        expect(t.echoes.calls, isEmpty);
      },
    );

    testWidgets('an empty note result shows the write something copy', (
      tester,
    ) async {
      final t = await _pump(
        tester,
        result: const EchoesReady([], emptyNote: true, pending: 0),
      );

      expect(t.echoes.calls, hasLength(1));
      _expectFg2Mono(tester, _copy(_nothingWritten));
      _expectHeaderAndOnly([_nothingWritten]);
    });

    testWidgets(
      'first load shows the header only then listening for echoes after 400 ms',
      (tester) async {
        final echoes = FakeEchoesAccess(vaultPath: echoesVaultPath)
          ..gate = Completer<void>();
        final t = await _pump(tester, echoes: echoes);

        expect(t.echoes.inFlight, 1, reason: 'the first read is held');
        _expectHeaderAndOnly(const []);
        expect(find.byKey(const Key('inline-error')), findsNothing);

        // The delay runs on clockProvider: tester.pump() moves no time.
        t.clock.advance(const Duration(milliseconds: 399));
        await tester.pump();
        expect(_copy(_listening), findsNothing, reason: 'not before 400 ms');

        t.clock.advance(const Duration(milliseconds: 1));
        await tester.pump();
        _expectFg2Mono(tester, _copy(_listening));
        _expectHeaderAndOnly([_listening]);

        echoes.gate!.complete();
        await pumpFrames(tester);
        expect(
          _copy(_listening),
          findsNothing,
          reason: 'the result replaces it',
        );
        expect(_copy(_nothingYet), findsOneWidget);
      },
    );

    testWidgets('a result inside 400 ms never shows listening for echoes', (
      tester,
    ) async {
      final echoes = FakeEchoesAccess(
        result: _ready([_echo()]),
        vaultPath: echoesVaultPath,
      )..gate = Completer<void>();
      final t = await _pump(tester, echoes: echoes);

      t.clock.advance(const Duration(milliseconds: 100));
      await tester.pump();
      echoes.gate!.complete();
      await pumpFrames(tester);
      expect(_row(_levelId), findsOneWidget);

      t.clock.advance(const Duration(seconds: 2));
      await pumpFrames(tester);
      expect(_copy(_listening), findsNothing);
      expect(_row(_levelId), findsOneWidget);
    });

    testWidgets('a note switch restarts the 400 ms first load delay', (
      tester,
    ) async {
      final t = await _pump(tester, result: _ready([_echo()]));
      expect(_row(_levelId), findsOneWidget);

      t.echoes.gate = Completer<void>();
      t.select(_otherOpenId);
      await tester.pump();
      await tester.pump();
      expect(t.echoes.inFlight, 1);
      expect(_row(_levelId), findsNothing, reason: 'the old note is gone');
      expect(_copy(_listening), findsNothing, reason: 'header only at first');

      t.clock.advance(const Duration(milliseconds: 399));
      await tester.pump();
      expect(_copy(_listening), findsNothing);
      t.clock.advance(const Duration(milliseconds: 1));
      await tester.pump();
      _expectFg2Mono(tester, _copy(_listening));
    });

    testWidgets('no echoes shows nothing surfaced yet then the hint line', (
      tester,
    ) async {
      await _pump(tester, result: _ready(const []));

      _expectFg2Mono(tester, _copy(_nothingYet), what: _nothingYet);
      _expectFg2Mono(tester, _copy(_appearWhen), what: _appearWhen);
      _expectBefore(tester, _nothingYet, _appearWhen);
      _expectHeaderAndOnly([_nothingYet, _appearWhen]);
      expect(_copy('still indexing'), findsNothing, reason: 'pending is 0');
    });

    testWidgets('pending passages show still indexing under the echo list', (
      tester,
    ) async {
      await _pump(tester, result: _ready([_echo(), _garden()], pending: 7));

      final line = _copy(_stillIndexing(7));
      _expectFg2Mono(tester, line);
      expect(
        tester.getRect(line).top,
        greaterThanOrEqualTo(tester.getRect(_row(_gardenId)).bottom - 0.5),
        reason: 'under the last row',
      );
      expect(_copy(_nothingYet), findsNothing, reason: 'there are echoes');
    });

    testWidgets('pending passages show still indexing under the empty copy', (
      tester,
    ) async {
      await _pump(tester, result: _ready(const [], pending: 3));

      _expectFg2Mono(tester, _copy(_stillIndexing(3)));
      _expectBefore(tester, _appearWhen, _stillIndexing(3));
      _expectBefore(tester, _nothingYet, _stillIndexing(3));
    });

    testWidgets('an echo list with nothing pending shows no still indexing', (
      tester,
    ) async {
      await _pump(tester, result: _ready([_echo()]));

      expect(_row(_levelId), findsOneWidget);
      expect(_copy('still indexing'), findsNothing);
    });

    for (final (name, reason, copy) in [
      (
        'embeddings off shows the start it with --with-embeddings copy',
        const EmbeddingsOff() as EchoesUnavailableReason,
        _embeddingsOff,
      ),
      (
        'no CLI shows the echoes need the memex CLI copy',
        const NoCli(),
        _noCli,
      ),
      ('outdated shows the update memex copy', const Outdated(), _outdated),
    ]) {
      testWidgets(name, (tester) async {
        await _pump(tester, result: EchoesUnavailable(reason));

        _expectFg2Mono(tester, _copy(copy));
        _expectHeaderAndOnly([copy]);
        expect(_download, findsNothing);
        expect(find.text('retry'), findsNothing);
      });
    }
  });

  // ================================================================ AC2
  group('AC2 download flow', () {
    testWidgets(
      'model not downloaded shows the copy and the Download model button',
      (tester) async {
        final t = await _pump(
          tester,
          result: const EchoesUnavailable(ModelNotDownloaded()),
        );

        _expectFg2Mono(tester, _copy(_modelMissing));
        _expectHeaderAndOnly([_modelMissing]);
        expect(_download, findsOneWidget);
        expect(
          find.descendant(of: _download, matching: find.text(_downloadLabel)),
          findsOneWidget,
        );
        expect(
          tester.getRect(_download).top,
          greaterThanOrEqualTo(tester.getRect(_copy(_modelMissing)).top),
          reason: 'the button follows the copy',
        );
        // L5: nothing downloads before the button is pressed.
        expect(t.echoes.calls.map((c) => c.allowDownload), everyElement(false));
        expect(t.notifier.downloads, 0);
      },
    );

    testWidgets(
      'pressing Download model calls download and shows downloading with the button hidden',
      (tester) async {
        final t = await _pump(
          tester,
          result: const EchoesUnavailable(ModelNotDownloaded()),
        );
        final before = t.echoes.calls.length;
        t.echoes.gate = Completer<void>();

        await tester.tap(_download);
        await tester.pump();
        await tester.pump();

        expect(t.notifier.downloads, 1);
        expect(t.echoes.calls, hasLength(before + 1));
        expect(t.echoes.calls.last.allowDownload, isTrue);
        _expectFg2Mono(tester, _copy(_downloading));
        _expectHeaderAndOnly([_downloading]);
        expect(_download, findsNothing, reason: 'the button is hidden');
        // No progress figure.
        expect(find.textContaining('%'), findsNothing);
        expect(find.textContaining(RegExp(r'\d+\s*(MB|KB|GB)')), findsNothing);
        for (final p in tester.widgetList<ProgressIndicator>(
          find.byType(ProgressIndicator),
        )) {
          expect(p.value, isNull, reason: 'no determinate progress');
        }
      },
    );

    testWidgets('a finished download shows the echoes result', (tester) async {
      final t = await _pump(
        tester,
        result: const EchoesUnavailable(ModelNotDownloaded()),
      );
      t.echoes.gate = Completer<void>();
      t.echoes.enqueue(_ready([_echo(), _garden()]));

      await tester.tap(_download);
      await pumpFrames(tester);
      expect(_copy(_downloading), findsOneWidget);

      t.echoes.gate!.complete();
      t.echoes.gate = null;
      await pumpFrames(tester);

      expect(_copy(_downloading), findsNothing);
      expect(_row(_levelId), findsOneWidget);
      expect(_row(_gardenId), findsOneWidget);
      expect(_download, findsNothing);
    });

    testWidgets(
      'a failed download shows couldnt load with the cause and retry downloads again',
      (tester) async {
        final t = await _pump(
          tester,
          result: const EchoesUnavailable(ModelNotDownloaded()),
        );
        t.echoes.enqueue(
          const EchoesUnavailable(EmbedderUnavailable('network unreachable')),
        );

        await tester.tap(_download);
        await pumpFrames(tester);

        _expectFg2Mono(tester, _copy(_couldntLoad), what: _couldntLoad);
        _expectFg2Mono(tester, _copy('network unreachable'), what: 'the cause');
        _expectBefore(tester, _couldntLoad, 'network unreachable');
        _expectHeaderAndOnly([_couldntLoad]);
        expect(find.text('retry'), findsOneWidget);
        expect(_download, findsNothing);

        final before = t.echoes.calls.length;
        await tester.tap(find.text('retry'));
        await pumpFrames(tester);

        expect(t.notifier.retries, 1);
        expect(t.echoes.calls, hasLength(before + 1));
        expect(
          t.echoes.calls.last.allowDownload,
          isTrue,
          reason: 'retry repeats the download run',
        );
      },
    );

    testWidgets(
      'embedder unavailable on a normal read shows the cause and retry reads again',
      (tester) async {
        final t = await _pump(
          tester,
          result: const EchoesUnavailable(EmbedderUnavailable('timed out')),
        );

        _expectFg2Mono(tester, _copy(_couldntLoad), what: _couldntLoad);
        _expectFg2Mono(tester, _copy('timed out'), what: 'the cause');
        t.echoes.result = _ready([_echo()]);

        await tester.tap(find.text('retry'));
        await pumpFrames(tester);

        expect(t.notifier.retries, 1);
        expect(t.echoes.calls, hasLength(2));
        expect(t.echoes.calls.last.allowDownload, isFalse);
        expect(_row(_levelId), findsOneWidget);
        expect(_copy(_couldntLoad), findsNothing);
      },
    );
  });

  // ================================================================ AC3
  group('AC3 row layout', () {
    testWidgets(
      'an echo row shows the title in accent and the age in fg2 mono at its right',
      (tester) async {
        await _pump(tester, result: _ready([_echo()]));

        final title = _inRow(_levelId, find.text('Level Design'));
        expect(title, findsOneWidget);
        expect(_drawnStyle(tester, title).color, OmColors.accent);

        final age = _inRow(_levelId, find.text('topic · 3 weeks ago'));
        _expectFg2Mono(tester, age, what: 'the age');

        final titleRect = tester.getRect(title);
        final ageRect = tester.getRect(age);
        final rowRect = tester.getRect(_row(_levelId));
        expect(
          ageRect.left,
          greaterThanOrEqualTo(titleRect.right - 0.5),
          reason: 'the age is right of the title',
        );
        expect(
          ageRect.top < titleRect.bottom && ageRect.bottom > titleRect.top,
          isTrue,
          reason: 'on the title line',
        );
        expect(
          ageRect.right,
          greaterThan(rowRect.center.dx),
          reason: 'at the right of the row',
        );
      },
    );

    testWidgets('echo rows follow the result order', (tester) async {
      await _pump(
        tester,
        result: _ready([
          _garden(),
          _echo(),
          _echo(
            id: _dailyId,
            title: '2026-09-12',
            role: 'daily',
            day: '2026-09-12',
          ),
        ]),
      );

      final tops = [
        _gardenId,
        _levelId,
        _dailyId,
      ].map((id) => tester.getRect(_row(id)).top).toList();
      expect(tops[0], lessThan(tops[1]));
      expect(tops[1], lessThan(tops[2]));
    });

    testWidgets(
      'an echo passage is the markdownPreviewText reduction in at most 3 ellipsized lines',
      (tester) async {
        final raw =
            '## Level **design**\n\n- Players learn from [[Graph Theory|graphs]] '
            'and `code` long before any tutorial text. ${'Every room teaches '
                    'one verb, then tests it twice, then twists it. ' * 12}';
        final reduced = markdownPreviewText(raw);
        expect(reduced, isNot(raw), reason: 'the fixture has markup');
        expect(reduced, startsWith('Level design Players learn from graphs'));

        await _pump(tester, result: _ready([_echo(passage: raw)]));

        final passage = _inRow(_levelId, find.text(reduced));
        expect(passage, findsOneWidget, reason: 'the full reduced text');
        expect(_inRow(_levelId, find.textContaining('**')), findsNothing);
        expect(_inRow(_levelId, find.textContaining('[[')), findsNothing);
        final text = tester.widget<Text>(passage);
        expect(text.maxLines, 3);
        expect(text.overflow, TextOverflow.ellipsis);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: passage, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isTrue, reason: 'cut to 3 lines');
        expect(paragraph.maxLines, 3);
      },
    );

    testWidgets('an echo passage tooltip holds the full reduced text', (
      tester,
    ) async {
      final raw =
          'A *long* passage about [[Rooms]] ${'and the verbs they teach ' * 20}';
      final reduced = markdownPreviewText(raw);
      await _pump(tester, result: _ready([_echo(passage: raw)]));

      final tips = tester
          .widgetList<Tooltip>(_inRow(_levelId, find.byType(Tooltip)))
          .map((t) => t.message)
          .toList();
      expect(tips, contains(reduced));
      // The tooltip wraps the passage.
      final passageTip = find.ancestor(
        of: _inRow(_levelId, find.text(reduced)),
        matching: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == reduced,
        ),
      );
      expect(passageTip, findsOneWidget);
    });
  });

  // ================================================================ AC4
  group('AC4 age wording', () {
    testWidgets(
      'daily echo ages read yesterday 5 days 3 weeks and 4 months from the clock today',
      (tester) async {
        // Every daily note was edited just now: the age comes from `day`.
        Echo daily(String id, String day) => _echo(
          id: id,
          title: day,
          role: 'daily',
          day: day,
          updatedAt: _now.millisecondsSinceEpoch,
        );
        await _pump(
          tester,
          result: _ready([
            daily('01JECHOD1', '2026-10-02'),
            daily('01JECHOD5', '2026-09-28'),
            daily('01JECHOD21', '2026-09-12'),
            daily('01JECHOD120', '2026-06-05'),
          ]),
        );

        for (final (id, age) in [
          ('01JECHOD1', 'yesterday'),
          ('01JECHOD5', '5 days ago'),
          ('01JECHOD21', '3 weeks ago'),
          ('01JECHOD120', '4 months ago'),
        ]) {
          final text = _inRow(id, find.text(age));
          _expectFg2Mono(tester, text, what: '$id age');
          expect(_inRow(id, find.textContaining('just now')), findsNothing);
          expect(_inRow(id, find.textContaining('topic ·')), findsNothing);
          expect(_inRow(id, find.textContaining('note ·')), findsNothing);
        }
      },
    );

    testWidgets(
      'non daily echo ages read topic or note and the note_updated_at age',
      (tester) async {
        await _pump(
          tester,
          result: _ready([
            _echo(updatedAt: _msAgo(const Duration(days: 21))),
            _garden(),
            _echo(
              id: _dailyId,
              title: 'Old topic',
              role: 'topic',
              updatedAt: _msAgo(const Duration(days: 400)),
            ),
          ]),
        );

        _expectFg2Mono(
          tester,
          _inRow(_levelId, find.text('topic · 3 weeks ago')),
        );
        _expectFg2Mono(
          tester,
          _inRow(_gardenId, find.text('note · 3 hours ago')),
        );
        _expectFg2Mono(
          tester,
          _inRow(_dailyId, find.text('topic · 1 year ago')),
        );
      },
    );
  });

  // ================================================================ AC5
  group('AC5 link plan', () {
    for (final (name, openRole, echoRole, plan) in [
      (
        'an open topic note links a topic echo from the open note',
        'topic',
        'topic',
        EchoLinkPlan.fromOpen,
      ),
      (
        'an open topic note links a plain echo from the open note',
        'topic',
        null,
        EchoLinkPlan.fromOpen,
      ),
      (
        'an open topic note links a daily echo from the open note',
        'topic',
        'daily',
        EchoLinkPlan.fromOpen,
      ),
      (
        'an open plain note links a topic echo from the open note',
        null,
        'topic',
        EchoLinkPlan.fromOpen,
      ),
      (
        'an open plain note links a daily echo from the open note',
        null,
        'daily',
        EchoLinkPlan.fromOpen,
      ),
      (
        'an open daily note files a topic echo as a footer chip',
        'daily',
        'topic',
        EchoLinkPlan.footerChip,
      ),
      (
        'an open daily note is linked from a plain echo',
        'daily',
        null,
        EchoLinkPlan.fromEcho,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final echo = _echo(
          role: echoRole,
          day: echoRole == 'daily' ? '2026-09-12' : null,
        );
        final t = await _pump(
          tester,
          result: _ready([echo]),
          openRole: openRole,
        );

        expect(_linkBox(_levelId), findsOneWidget, reason: 'link is shown');
        expect(
          find.descendant(of: _linkBox(_levelId), matching: find.text('link')),
          findsOneWidget,
        );
        await tester.tap(_linkBox(_levelId));
        await tester.pump();

        expect(t.links.calls, hasLength(1));
        expect(t.links.calls.single.plan, plan);
        expect(t.links.calls.single.openNoteId, echoesOpenNoteId);
        expect(t.links.calls.single.echo, echo);
      });
    }

    testWidgets('an open daily note shows no link for a daily echo', (
      tester,
    ) async {
      final t = await _pump(
        tester,
        result: _ready([
          _echo(role: 'daily', day: '2026-09-12', title: '2026-09-12'),
          _garden(),
        ]),
        openRole: 'daily',
      );

      expect(_row(_levelId), findsOneWidget);
      expect(_linkBox(_levelId), findsNothing);
      expect(_inRow(_levelId, find.text('link')), findsNothing);
      expect(_linkBox(_gardenId), findsOneWidget, reason: 'a plain echo links');
      expect(t.links.calls, isEmpty);
    });
  });

  // ================================================================ AC6
  group('AC6 link once', () {
    testWidgets(
      'pressing link calls link once with the open note the echo and the plan',
      (tester) async {
        final echo = _echo();
        final t = await _pump(tester, result: _ready([echo, _garden()]));

        await tester.tap(_linkBox(_levelId));
        await tester.pump();

        expect(t.links.calls, hasLength(1));
        final call = t.links.calls.single;
        expect(call.openNoteId, echoesOpenNoteId);
        expect(call.echo, echo);
        expect(call.plan, EchoLinkPlan.fromOpen);
        expect(t.tabs.followed, isEmpty, reason: 'link does not open');
      },
    );

    testWidgets('a same frame double press on link makes one call', (
      tester,
    ) async {
      final links = FakeEchoLinkActions()..gate = Completer<void>();
      final t = await _pump(tester, result: _ready([_echo()]), links: links);

      // Both presses land before any rebuild.
      await tester.tap(_linkBox(_levelId));
      await tester.tap(_linkBox(_levelId));
      await tester.pump();

      expect(t.links.calls, hasLength(1));
      links.gate!.complete();
      await pumpFrames(tester);
      expect(t.links.calls, hasLength(1));
    });

    testWidgets(
      'a press while the link is in flight makes no second call and the button is disabled',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);

        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        expect(t.links.calls, hasLength(1));
        expect(
          tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
          isNull,
          reason: 'disabled while in flight',
        );

        await tester.tap(_linkBox(_levelId), warnIfMissed: false);
        await tester.pump();
        expect(t.links.calls, hasLength(1));
        expect(
          t.tabs.followed,
          isEmpty,
          reason: 'a press in the disabled link box does not reach the row',
        );
        expect(t.h.read(echoScrollTargetProvider), isNull);
      },
    );

    testWidgets(
      'Enter on the focused link button links once and a held Enter repeats nothing',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);

        await _tabInto(tester, _linkBox(_levelId));
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(t.links.calls, hasLength(1));
        expect(t.tabs.followed, isEmpty, reason: 'Enter on link never opens');
      },
    );

    testWidgets('the link button is enabled again after a failed link', (
      tester,
    ) async {
      final links = FakeEchoLinkActions(
        failure: MemexException('add_link failed: database is locked'),
      );
      final t = await _pump(tester, result: _ready([_echo()]), links: links);

      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);
      expect(
        tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
        isNotNull,
      );

      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);
      expect(t.links.calls, hasLength(2));
    });
  });

  // ================================================================ AC7
  group('AC7 link outcome', () {
    testWidgets(
      'a linked echo row disappears at once and linkCompleted is called once',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(
          tester,
          result: _ready([_echo(), _garden()]),
          links: links,
        );
        final reads = t.echoes.calls.length;

        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        expect(_row(_levelId), findsOneWidget, reason: 'stays while in flight');
        expect(t.notifier.linksCompleted, 0);

        // Hold the re-read: the row must go before any new result.
        t.echoes.gate = Completer<void>();
        links.gate!.complete();
        await tester.pump();
        await tester.pump();

        expect(_row(_levelId), findsNothing, reason: 'removed at once');
        expect(_row(_gardenId), findsOneWidget, reason: 'only that row');
        expect(t.notifier.linksCompleted, 1);
        expect(t.echoes.calls, hasLength(reads + 1), reason: 'one re-read');
        expect(find.byKey(const Key('inline-error')), findsNothing);

        t.echoes.gate!.complete();
        t.echoes.gate = null;
        await pumpFrames(tester);
        expect(t.notifier.linksCompleted, 1);
      },
    );

    testWidgets('a linked echo stays hidden when the re-read still lists it', (
      tester,
    ) async {
      final t = await _pump(tester, result: _ready([_echo(), _garden()]));

      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);

      // The default result still lists it.
      expect(t.echoes.calls.length, greaterThanOrEqualTo(2));
      expect(_row(_levelId), findsNothing);
      expect(_row(_gardenId), findsOneWidget);
    });

    testWidgets('a linked echo shows again after a note switch', (
      tester,
    ) async {
      final t = await _pump(tester, result: _ready([_echo(), _garden()]));
      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);
      expect(_row(_levelId), findsNothing);

      t.select(_otherOpenId);
      await pumpFrames(tester);

      expect(t.echoes.calls.last.noteId, _otherOpenId);
      expect(_row(_levelId), findsOneWidget, reason: 'hidden per note id');
    });

    testWidgets(
      'a linked echo shows again once a result drops and relists it',
      (tester) async {
        final t = await _pump(tester, result: _ready([_echo(), _garden()]));
        t.echoes.enqueue(_ready([_garden()]));
        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);
        expect(_row(_levelId), findsNothing);

        // A later read lists it again (for example after an unlink).
        await t.notifier.retry();
        await pumpFrames(tester);
        expect(_row(_levelId), findsOneWidget);
      },
    );

    testWidgets(
      'a failed link keeps the row with an inline error and its message',
      (tester) async {
        final links = FakeEchoLinkActions(
          failure: MemexException('add_link failed: database is locked'),
        );
        final t = await _pump(
          tester,
          result: _ready([_echo(), _garden()]),
          links: links,
        );
        final reads = t.echoes.calls.length;

        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);

        expect(_row(_levelId), findsOneWidget, reason: 'the row stays');
        final error = _inRow(_levelId, find.byKey(const Key('inline-error')));
        expect(error, findsOneWidget, reason: 'inside that row');
        expect(
          find.descendant(
            of: error,
            matching: find.text('add_link failed: database is locked'),
          ),
          findsOneWidget,
        );
        expect(
          _inRow(_gardenId, find.byKey(const Key('inline-error'))),
          findsNothing,
        );
        expect(t.notifier.linksCompleted, 0);
        expect(t.notifier.retries, 0);
        expect(t.echoes.calls, hasLength(reads), reason: 'no re-read');

        await tester.tap(
          _inRow(_levelId, find.byKey(const Key('inline-error-dismiss'))),
        );
        await pumpFrames(tester);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_row(_levelId), findsOneWidget);
      },
    );

    testWidgets('a not_found link failure re-reads the list once', (
      tester,
    ) async {
      final links = FakeEchoLinkActions(
        failure: MemexException(
          'add_link failed: note not found',
          code: 'not_found',
        ),
      );
      final t = await _pump(
        tester,
        result: _ready([_echo(), _garden()]),
        links: links,
      );
      final reads = t.echoes.calls.length;

      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);

      expect(t.notifier.retries, 1);
      expect(t.echoes.calls, hasLength(reads + 1));
      expect(t.notifier.linksCompleted, 0);
      expect(
        find.descendant(
          of: find.byKey(const Key('inline-error')),
          matching: find.text('add_link failed: note not found'),
        ),
        findsOneWidget,
      );
    });

    for (final (name, code) in [
      ('a conflict link failure does not re-read the list', 'version_conflict'),
      ('a link failure with no code does not re-read the list', null),
    ]) {
      testWidgets(name, (tester) async {
        final links = FakeEchoLinkActions(
          failure: MemexException('add_link failed: nope', code: code),
        );
        final t = await _pump(tester, result: _ready([_echo()]), links: links);
        final reads = t.echoes.calls.length;

        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);

        expect(t.notifier.retries, 0);
        expect(t.echoes.calls, hasLength(reads));
        expect(
          _inRow(_levelId, find.text('add_link failed: nope')),
          findsOneWidget,
        );
      });
    }
  });

  // ================================================================ AC8
  group('AC8 open', () {
    testWidgets(
      'tapping an echo title follows the note and sets the scroll target',
      (tester) async {
        final t = await _pump(tester, result: _ready([_echo(), _garden()]));

        await tester.tap(_inRow(_levelId, find.text('Level Design')));
        await tester.pump();

        expect(t.tabs.followed, [const NoteTab(_levelId)]);
        expect(
          t.h.read(echoScrollTargetProvider),
          const EchoScrollTarget(_levelId, 42),
        );
        expect(t.links.calls, isEmpty);
      },
    );

    testWidgets(
      'tapping an echo passage follows the note and sets the scroll target',
      (tester) async {
        final t = await _pump(
          tester,
          result: _ready([_garden(), _echo(startByte: null)]),
        );

        await tester.tap(
          _inRow(_levelId, find.text('Levels teach by showing.')),
        );
        await tester.pump();

        expect(t.tabs.followed, [const NoteTab(_levelId)]);
        expect(
          t.h.read(echoScrollTargetProvider),
          const EchoScrollTarget(_levelId, null),
          reason: 'a null startByte opens at the top',
        );
      },
    );

    testWidgets(
      'a tap inside the echo link box neither follows nor sets the scroll target',
      (tester) async {
        final t = await _pump(tester, result: _ready([_echo()]));

        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);

        expect(t.links.calls, hasLength(1));
        expect(t.tabs.followed, isEmpty);
        expect(t.h.read(echoScrollTargetProvider), isNull);
      },
    );

    testWidgets(
      'the echo keys name the padded row the title and passage target and the 24 px link box',
      (tester) async {
        await _pump(tester, result: _ready([_echo()]));

        final row = tester.getRect(_row(_levelId));
        final open = tester.getRect(_open(_levelId));
        final link = tester.getRect(_linkBox(_levelId));
        final title = tester.getRect(
          _inRow(_levelId, find.text('Level Design')),
        );
        final passage = tester.getRect(
          _inRow(_levelId, find.text('Levels teach by showing.')),
        );

        expect(_rectInside(open, title), isTrue, reason: 'open covers title');
        expect(_rectInside(open, passage), isTrue, reason: 'and the passage');
        expect(_rectInside(row, open), isTrue);
        expect(_rectInside(row, link), isTrue);
        expect(open.left, greaterThan(row.left), reason: 'the row is padded');
        expect(link.height, 24, reason: 'the button box is 24 px');
        expect(
          row.width,
          greaterThanOrEqualTo(
            tester.getRect(find.byType(RightPanel)).width - 2,
          ),
          reason: 'the whole row spans the panel',
        );
      },
    );
  });

  // ================================================================ AC9
  group('AC9 other errors', () {
    testWidgets(
      'another read error shows an inline error with a working retry',
      (tester) async {
        final echoes = FakeEchoesAccess(
          result: _ready([_echo()]),
          vaultPath: echoesVaultPath,
        )..enqueue(MemexException('echoes failed: database is locked'));
        final t = await _pump(tester, echoes: echoes);

        final error = find.byKey(const Key('inline-error'));
        expect(error, findsOneWidget);
        expect(
          find.descendant(
            of: error,
            matching: find.text('echoes failed: database is locked'),
          ),
          findsOneWidget,
        );
        expect(_eyebrow, findsOneWidget);
        final retry = find.byKey(const Key('inline-error-retry'));
        expect(retry, findsOneWidget);

        await tester.tap(retry);
        await pumpFrames(tester);

        expect(t.notifier.retries, 1);
        expect(t.echoes.calls, hasLength(2));
        expect(error, findsNothing);
        expect(_row(_levelId), findsOneWidget);
      },
    );

    testWidgets('the last good result stays visible above the inline error', (
      tester,
    ) async {
      final t = await _pump(tester, result: _ready([_echo(), _garden()]));
      t.echoes.enqueue(MemexException('echoes failed: database is locked'));

      await t.notifier.retry();
      await pumpFrames(tester);

      final error = find.byKey(const Key('inline-error'));
      expect(error, findsOneWidget);
      expect(_row(_levelId), findsOneWidget);
      expect(_row(_gardenId), findsOneWidget);
      expect(
        tester.getRect(error).top,
        greaterThanOrEqualTo(tester.getRect(_row(_gardenId)).bottom - 0.5),
        reason: 'the previous result is above the error',
      );
      expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
    });
  });

  // ================================================================ AC10
  group('AC10 semantics', () {
    testWidgets(
      'an echo row is one focusable semantics node labelled Echo from title age and passage',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, result: _ready([_echo(), _garden()]));

        const label =
            'Echo from Level Design, 3 weeks ago: Levels teach by showing.';
        final node = find.bySemanticsLabel(label);
        expect(node, findsOneWidget);
        expect(
          tester.getSemantics(node),
          isSemantics(label: label, isFocusable: true, hasTapAction: true),
        );
        expect(
          find.bySemanticsLabel(
            'Echo from Garden, 3 hours ago: '
            'Tomatoes want more sun.',
          ),
          findsOneWidget,
          reason: 'a non-daily row uses the relative part only',
        );
        // One node: the title, age and passage are not nodes of their own.
        expect(find.bySemanticsLabel('Level Design'), findsNothing);
        expect(find.bySemanticsLabel('topic · 3 weeks ago'), findsNothing);
        expect(find.bySemanticsLabel('Levels teach by showing.'), findsNothing);
        handle.dispose();
      },
    );

    testWidgets('a daily echo row label uses its day age', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        result: _ready([
          _echo(
            title: '2026-09-28',
            role: 'daily',
            day: '2026-09-28',
            updatedAt: _now.millisecondsSinceEpoch,
          ),
        ]),
      );

      expect(
        find.bySemanticsLabel(
          'Echo from 2026-09-28, 5 days ago: Levels teach by showing.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('Enter on a focused echo row opens it', (tester) async {
      final t = await _pump(tester, result: _ready([_echo()]));

      await _tabInto(tester, _row(_levelId), notInside: _linkBox(_levelId));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(t.tabs.followed, [const NoteTab(_levelId)]);
      expect(
        t.h.read(echoScrollTargetProvider),
        const EchoScrollTarget(_levelId, 42),
      );
      expect(t.links.calls, isEmpty);
    });

    testWidgets('the link button is labelled Link title to this note', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, result: _ready([_echo()]));

      final link = find.bySemanticsLabel('Link Level Design to this note');
      expect(link, findsOneWidget);
      expect(
        tester.getSemantics(link),
        isSemantics(
          label: 'Link Level Design to this note',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets(
      'the download button is labelled Download the embedding model 130 megabytes',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          result: const EchoesUnavailable(ModelNotDownloaded()),
        );

        final button = find.bySemanticsLabel(_downloadSemantics);
        expect(button, findsOneWidget);
        expect(
          tester.getSemantics(button),
          isSemantics(
            label: _downloadSemantics,
            isButton: true,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      },
    );
  });

  // ================================================================ AC11
  group('AC11 text scale', () {
    // pumpEchoesTab's 0.5 is the real app's 1x with the wide test font
    // (see pumpWorkspace), so 1.5x is 0.75.
    const scale15 = 0.75;

    void expectNoOverflow(WidgetTester tester, String state) {
      expect(tester.takeException(), isNull, reason: '$state overflows');
      for (final tab in ['connections', 'echoes', 'activity']) {
        final chip = find.text(tab);
        expect(chip, findsOneWidget, reason: 'the $tab tab chip');
        expect(
          _rectInside(
            tester.getRect(find.byType(RightPanel)),
            tester.getRect(chip),
          ),
          isTrue,
          reason: 'the $tab chip is inside the panel ($state)',
        );
      }
    }

    testWidgets(
      'every echoes state fits at 1.5x text scale in the 340 px panel',
      (tester) async {
        final echoes = FakeEchoesAccess(vaultPath: echoesVaultPath);
        final t = await _pump(
          tester,
          echoes: echoes,
          noteId: null,
          textScale: scale15,
        );
        expect(tester.getSize(find.byType(RightPanel)).width, 340);
        expect(_copy(_noNote), findsOneWidget);
        expectNoOverflow(tester, 'no note');

        Future<void> step(
          String state,
          Future<void> Function() go,
          String copy,
        ) async {
          await go();
          await pumpFrames(tester);
          expect(_copy(copy), findsOneWidget, reason: state);
          expectNoOverflow(tester, state);
        }

        echoes
          ..enqueue(_ready(const [], pending: 3))
          ..enqueue(const EchoesUnavailable(EmbeddingsOff()))
          ..enqueue(const EchoesUnavailable(NoCli()))
          ..enqueue(const EchoesUnavailable(Outdated()))
          ..enqueue(MemexException('echoes failed: database is locked'))
          ..enqueue(
            _ready([
              _echo(
                title: 'A note title far too long for one line of the panel',
              ),
              _garden(),
            ], pending: 12345),
          )
          ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
          ..enqueue(
            const EchoesUnavailable(
              EmbedderUnavailable(
                'failed to fetch https://huggingface.co/BAAI/bge-small-en-v1.5/'
                'resolve/main/model.onnx: connection refused',
              ),
            ),
          );

        echoes.gate = Completer<void>();
        t.select(echoesOpenNoteId);
        await pumpFrames(tester);
        t.clock.advance(const Duration(milliseconds: 400));
        await step('first load', () async {}, _listening);
        echoes.gate!.complete();
        echoes.gate = null;
        await step('empty with pending', () async {}, _stillIndexing(3));
        expect(_copy(_appearWhen), findsOneWidget);
        await step('embeddings off', t.notifier.retry, _embeddingsOff);
        await step('no CLI', t.notifier.retry, _noCli);
        await step('outdated', t.notifier.retry, _outdated);
        await step('other error', t.notifier.retry, 'database is locked');
        await step(
          'rows with pending',
          t.notifier.retry,
          _stillIndexing(12345),
        );
        await step('model not downloaded', t.notifier.retry, _modelMissing);
        expect(_download, findsOneWidget);
        echoes.gate = Completer<void>();
        await step('downloading', () async {
          await tester.tap(_download);
        }, _downloading);
        echoes.gate!.complete();
        echoes.gate = null;
        await step('embedder unavailable', () async {}, _couldntLoad);
        expect(find.text('retry'), findsOneWidget);
        await step(
          'virtual Today',
          () async => t.select('virtual-today:2026-10-03'),
          _nothingWritten,
        );
      },
    );

    testWidgets(
      'a long title and passage row fits at 1.5x text scale in the 340 px panel',
      (tester) async {
        const longTitle =
            'An extremely long note title about level design, pacing, '
            'teaching verbs and the rooms that test them twice';
        final passage =
            'Every room teaches one verb, then tests it twice. ' * 30;
        await _pump(
          tester,
          result: _ready([
            _echo(title: longTitle, passage: passage),
            _echo(
              id: _dailyId,
              title: '2026-06-05',
              role: 'daily',
              day: '2026-06-05',
              passage: passage,
            ),
          ], pending: 3),
          textScale: scale15,
        );

        expectNoOverflow(tester, 'long row');
        final panel = tester.getRect(find.byType(RightPanel));
        final age = _inRow(_levelId, find.text('topic · 3 weeks ago'));
        expect(age, findsOneWidget);
        expect(
          _rectInside(panel, tester.getRect(age)),
          isTrue,
          reason: 'the age stays visible inside the panel',
        );
        expect(_rectInside(panel, tester.getRect(_linkBox(_levelId))), isTrue);
        expect(_rectInside(panel, tester.getRect(_row(_dailyId))), isTrue);
      },
    );
  });

  // ================================================================ pins
  // Contracts the first pass left unpinned (verify round 1): each test names
  // the AC it belongs to.
  group('pins', () {
    /// `selectedNoteAsyncProvider` held on [gate], then serving a note.
    Override servedNote(Completer<void> gate, {required String id}) =>
        selectedNoteAsyncProvider.overrideWith((ref) async {
          await gate.future;
          return VaultScoped<Note?>(
            const LocalVaultRef(echoesVaultPath),
            Note(
              id: id,
              title: 'Served',
              contentMd: '',
              frontmatter: '{}',
              version: 1,
              createdAt: 0,
              updatedAt: 0,
              tags: const [],
            ),
          );
        });

    Color rowFill(WidgetTester tester, String id) => tester
        .widget<ColoredBox>(_inRow(id, find.byType(ColoredBox)).first)
        .color;

    // ------------------------------------------------ AC5: role loaded
    testWidgets('the link stays hidden until the open note has loaded', (
      tester,
    ) async {
      final gate = Completer<void>();
      final t = await _pump(
        tester,
        result: _ready([_echo()]),
        extraOverrides: [servedNote(gate, id: echoesOpenNoteId)],
      );

      expect(_row(_levelId), findsOneWidget);
      expect(_linkBox(_levelId), findsNothing, reason: 'no role yet');

      gate.complete();
      await pumpFrames(tester);
      expect(_linkBox(_levelId), findsOneWidget, reason: 'the role loaded');
      expect(t.links.calls, isEmpty);
    });

    testWidgets('the link stays hidden when the loaded note is another one', (
      tester,
    ) async {
      final gate = Completer<void>()..complete();
      await _pump(
        tester,
        result: _ready([_echo()]),
        extraOverrides: [servedNote(gate, id: _otherOpenId)],
      );

      expect(_row(_levelId), findsOneWidget);
      expect(_linkBox(_levelId), findsNothing, reason: 'not the open note');
    });

    testWidgets('the link stays hidden when the open note is not found', (
      tester,
    ) async {
      await _pump(tester, result: _ready([_echo()]), seedOpenNote: false);

      expect(_row(_levelId), findsOneWidget);
      expect(_linkBox(_levelId), findsNothing);
    });

    // ------------------------------------------------ AC9: dismissed error
    testWidgets(
      'a dismissed read error stays hidden until a different error arrives',
      (tester) async {
        final echoes = FakeEchoesAccess(vaultPath: echoesVaultPath)
          ..enqueue(MemexException('echoes failed: first'));
        final t = await _pump(tester, echoes: echoes);
        final error = find.byKey(const Key('inline-error'));
        expect(error, findsOneWidget);

        await tester.tap(find.byKey(const Key('inline-error-dismiss')));
        await pumpFrames(tester);
        expect(error, findsNothing, reason: 'dismissed');
        expect(find.text('echoes failed: first'), findsNothing);
        expect(_eyebrow, findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(error, findsNothing, reason: 'a rebuild keeps it dismissed');

        t.echoes.enqueue(MemexException('echoes failed: second'));
        await t.notifier.retry();
        await pumpFrames(tester);
        expect(error, findsOneWidget, reason: 'a different error shows');
        expect(find.text('echoes failed: second'), findsOneWidget);
      },
    );

    // ------------------------------------------------ AC4: age fallbacks
    testWidgets(
      'a daily echo with no usable day reads its note updated age without a prefix',
      (tester) async {
        await _pump(
          tester,
          result: _ready([
            _echo(role: 'daily', day: null, title: '2026-09-12'),
            _echo(
              id: _gardenId,
              title: '2026-09-20',
              role: 'daily',
              day: 'not-a-day',
              updatedAt: _msAgo(const Duration(days: 10)),
            ),
          ]),
        );

        expect(_inRow(_levelId, find.text('3 weeks ago')), findsOneWidget);
        expect(_inRow(_gardenId, find.text('10 days ago')), findsOneWidget);
        expect(_inRow(_levelId, find.textContaining('·')), findsNothing);
        expect(_inRow(_gardenId, find.textContaining('·')), findsNothing);
      },
    );

    testWidgets('a non daily echo ignores its day and reads the updated age', (
      tester,
    ) async {
      await _pump(
        tester,
        result: _ready([
          _echo(role: 'topic', day: '2026-09-28'),
          _echo(id: _gardenId, title: 'Garden', role: null, day: '2026-09-28'),
        ]),
      );

      expect(
        _inRow(_levelId, find.text('topic · 3 weeks ago')),
        findsOneWidget,
      );
      expect(
        _inRow(_gardenId, find.text('note · 3 weeks ago')),
        findsOneWidget,
      );
    });

    // ------------------------------------------------ AC10: keys and fill
    testWidgets(
      'the numpad Enter opens a focused row and its repeat and key up reach nothing',
      (tester) async {
        final t = await _pump(tester, result: _ready([_echo()]));
        await _tabInto(tester, _row(_levelId), notInside: _linkBox(_levelId));

        final seen = <KeyEvent>[];
        final root = FocusManager.instance.rootScope;
        final previous = root.onKeyEvent;
        root.onKeyEvent = (_, event) {
          seen.add(event);
          return KeyEventResult.ignored;
        };
        addTearDown(() => root.onKeyEvent = previous);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.numpadEnter);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.numpadEnter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.numpadEnter);
        await tester.pump();

        expect(t.tabs.followed, [const NoteTab(_levelId)], reason: 'once');
        expect(seen, isEmpty, reason: 'the row handles down, repeat and up');

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(t.tabs.followed, hasLength(1), reason: 'only Enter opens');
        expect(
          seen.map((e) => e.logicalKey),
          contains(LogicalKeyboardKey.space),
          reason: 'another key passes on to the ancestors',
        );
      },
    );

    testWidgets('a keyboard focused row is filled and a focused link is not', (
      tester,
    ) async {
      await _pump(tester, result: _ready([_echo(), _garden()]));
      expect(rowFill(tester, _levelId), Colors.transparent, reason: 'idle');

      await _tabInto(tester, _row(_levelId), notInside: _linkBox(_levelId));
      expect(rowFill(tester, _levelId), OmColors.surface3, reason: 'focused');
      expect(rowFill(tester, _gardenId), Colors.transparent);

      await _tabInto(tester, _linkBox(_levelId));
      expect(
        rowFill(tester, _levelId),
        Colors.transparent,
        reason: 'the link has the focus, not the row',
      );
    });

    testWidgets(
      'a focused echo row reports focus and a semantic tap opens it',
      (tester) async {
        final handle = tester.ensureSemantics();
        final t = await _pump(tester, result: _ready([_echo()]));
        const label =
            'Echo from Level Design, 3 weeks ago: Levels teach by showing.';
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          isSemantics(
            label: label,
            isFocusable: true,
            isFocused: false,
            hasTapAction: true,
          ),
        );

        await _tabInto(tester, _row(_levelId), notInside: _linkBox(_levelId));
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          isSemantics(
            label: label,
            isFocusable: true,
            isFocused: true,
            hasTapAction: true,
          ),
        );

        tester.semantics.tap(find.semantics.byLabel(label));
        await tester.pump();
        expect(t.tabs.followed, [const NoteTab(_levelId)]);
        handle.dispose();
      },
    );

    testWidgets(
      'an echo row node holds the link button only and the link less row is a leaf',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          result: _ready([
            _echo(role: 'daily', day: '2026-09-28', title: '2026-09-28'),
            _garden(),
          ]),
          openRole: 'daily',
        );

        final daily = tester.getSemantics(
          find.bySemanticsLabel(
            'Echo from 2026-09-28, 5 days ago: Levels teach by showing.',
          ),
        );
        expect(daily.childrenCount, 0, reason: 'no link: a leaf node');
        final plain = tester.getSemantics(
          find.bySemanticsLabel(
            'Echo from Garden, 3 hours ago: Tomatoes want more sun.',
          ),
        );
        expect(plain.childrenCount, 1, reason: 'only the link button');
        handle.dispose();
      },
    );

    testWidgets(
      'a failed link keeps the row label free of the error and the error its own node',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(
          tester,
          result: _ready([_echo()]),
          links: FakeEchoLinkActions(
            failure: MemexException('add_link failed: database is locked'),
          ),
        );
        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);

        expect(
          find.bySemanticsLabel(
            'Echo from Level Design, 3 weeks ago: Levels teach by showing.',
          ),
          findsOneWidget,
          reason: 'the error text is not in the row label',
        );
        expect(
          find.bySemanticsLabel(RegExp('database is locked')),
          findsOneWidget,
        );
        handle.dispose();
      },
    );

    // ------------------------------------------------ AC7: link edges
    testWidgets(
      'a link that fails without a memex code shows its message only',
      (tester) async {
        final t = await _pump(
          tester,
          result: _ready([_echo()]),
          links: FakeEchoLinkActions(failure: StateError('boom')),
        );
        final reads = t.echoes.calls.length;

        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);

        expect(_inRow(_levelId, find.text('Bad state: boom')), findsOneWidget);
        expect(t.notifier.retries, 0);
        expect(t.notifier.linksCompleted, 0);
        expect(t.echoes.calls, hasLength(reads));
      },
    );

    testWidgets(
      'a link that completes after a note switch hides nothing and still re-reads',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(
          tester,
          result: _ready([_echo(), _garden()]),
          links: links,
        );
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        t.select(_otherOpenId);
        await pumpFrames(tester);

        links.gate!.complete();
        await pumpFrames(tester);
        expect(t.notifier.linksCompleted, 1);

        t.select(echoesOpenNoteId);
        await pumpFrames(tester);
        expect(_row(_levelId), findsOneWidget, reason: 'not hidden for A');
        expect(
          tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
          isNotNull,
          reason: 'no longer in flight',
        );
      },
    );

    testWidgets(
      'a link that fails after a note switch records no error and still re-reads on not_found',
      (tester) async {
        final links = FakeEchoLinkActions(
          failure: MemexException('add_link failed: gone', code: 'not_found'),
        )..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        t.select(_otherOpenId);
        await pumpFrames(tester);
        final reads = t.echoes.calls.length;

        links.gate!.complete();
        await pumpFrames(tester);
        expect(t.notifier.retries, 1);
        expect(t.echoes.calls, hasLength(reads + 1));

        t.select(echoesOpenNoteId);
        await pumpFrames(tester);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_row(_levelId), findsOneWidget);
      },
    );

    testWidgets(
      'a link in flight on one note leaves the link free on the next',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);
        t.h.db.seedNote(id: _otherOpenId, title: 'Other note');
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        expect(t.links.calls, hasLength(1));

        t.select(_otherOpenId);
        await pumpFrames(tester);
        expect(
          tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
          isNotNull,
          reason: 'busy is per open note',
        );
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        expect(t.links.calls, hasLength(2));
        expect(t.links.calls.last.openNoteId, _otherOpenId);
      },
    );

    testWidgets('a link that completes after the tab unmounts still re-reads', (
      tester,
    ) async {
      final links = FakeEchoLinkActions()..gate = Completer<void>();
      final t = await _pump(tester, result: _ready([_echo()]), links: links);
      await tester.tap(_linkBox(_levelId));
      await tester.pump();

      t.h.container.read(rightPanelTabProvider.notifier).state =
          RightPanelTab.activity;
      await pumpFrames(tester);
      expect(_row(_levelId), findsNothing, reason: 'the tab is gone');

      links.gate!.complete();
      await pumpFrames(tester);
      expect(t.notifier.linksCompleted, 1);
      expect(tester.takeException(), isNull);
    });

    // ------------------------------------------------ AC1: delay reset, gaps
    testWidgets(
      'the listening copy waits 400 ms again on a note switch after it showed',
      (tester) async {
        final echoes = FakeEchoesAccess(
          result: _ready([_echo()]),
          vaultPath: echoesVaultPath,
        )..gate = Completer<void>();
        final t = await _pump(tester, echoes: echoes);
        t.clock.advance(const Duration(milliseconds: 400));
        await tester.pump();
        expect(_copy(_listening), findsOneWidget);

        echoes.gate!.complete();
        echoes.gate = null;
        await pumpFrames(tester);
        expect(_row(_levelId), findsOneWidget);

        echoes.gate = Completer<void>();
        t.select(_otherOpenId);
        await tester.pump();
        await tester.pump();
        expect(t.echoes.inFlight, 1);
        expect(_copy(_listening), findsNothing, reason: 'a fresh 400 ms');
        t.clock.advance(const Duration(milliseconds: 400));
        await tester.pump();
        expect(_copy(_listening), findsOneWidget);
      },
    );

    testWidgets('still indexing sits 12 px under the last row', (tester) async {
      await _pump(tester, result: _ready([_echo(), _garden()], pending: 3));

      final gap =
          tester.getRect(_copy('still indexing')).top -
          tester.getRect(_row(_gardenId)).bottom;
      expect(gap, closeTo(12, 0.5));
    });

    testWidgets('still indexing follows the empty copy with no extra gap', (
      tester,
    ) async {
      await _pump(tester, result: _ready(const [], pending: 3));

      final gap =
          tester.getRect(_copy('still indexing')).top -
          tester.getRect(_copy(_nothingYet)).bottom;
      expect(gap, closeTo(0, 0.5));
    });

    testWidgets(
      'still indexing follows the empty copy once the last echo is linked',
      (tester) async {
        await _pump(tester, result: _ready([_echo()], pending: 3));
        await tester.tap(_linkBox(_levelId));
        await pumpFrames(tester);

        expect(_row(_levelId), findsNothing);
        final gap =
            tester.getRect(_copy('still indexing')).top -
            tester.getRect(_copy(_nothingYet)).bottom;
        expect(gap, closeTo(0, 0.5));
      },
    );

    // ------------------------------------------------ AC11: tab row
    testWidgets('each tab chip in the fitted row switches the tab', (
      tester,
    ) async {
      final t = await _pump(tester);
      RightPanelTab current() => t.h.read(rightPanelTabProvider);

      await tester.tap(find.text('activity'));
      await pumpFrames(tester);
      expect(current(), RightPanelTab.activity);

      await tester.tap(find.text('connections'));
      await pumpFrames(tester);
      expect(current(), RightPanelTab.connections);

      await tester.tap(find.text('echoes'));
      await pumpFrames(tester);
      expect(current(), RightPanelTab.echoes);
      expect(_eyebrow, findsOneWidget);
    });

    for (final (name, scale, shrinks) in [
      ('the tab chips keep their natural size at 0.5 text scale', 0.5, false),
      ('the tab chips shrink together to fit at 1.5x text scale', 0.75, true),
    ]) {
      testWidgets(name, (tester) async {
        await _pump(tester, textScale: scale);

        final fit = find
            .ancestor(
              of: find.text('connections'),
              matching: find.byType(FittedBox),
            )
            .first;
        final box = tester.renderObject<RenderFittedBox>(fit);
        final child = box.child!.size;
        if (shrinks) {
          expect(box.size.width, lessThan(child.width - 1), reason: 'scaled');
        } else {
          expect(box.size.width, closeTo(child.width, 0.01), reason: 'natural');
          expect(box.size.height, closeTo(child.height, 0.01));
        }
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.text('activity')).right,
          lessThan(tester.getRect(find.byType(RightPanel)).right),
        );
      });
    }
  });

  // ======================================== fix round 1 (review r1 F1-F3)
  group('link state outlives the tab', () {
    Future<void> showTab(WidgetTester tester, _Tab t, RightPanelTab tab) async {
      t.h.container.read(rightPanelTabProvider.notifier).state = tab;
      await pumpFrames(tester);
    }

    testWidgets(
      'a tab switch in the middle of a link keeps the link disabled and a second press makes no call',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        expect(t.links.calls, hasLength(1));

        await showTab(tester, t, RightPanelTab.activity);
        expect(_row(_levelId), findsNothing, reason: 'the tab is gone');
        await showTab(tester, t, RightPanelTab.echoes);

        expect(_row(_levelId), findsOneWidget);
        expect(
          tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
          isNull,
          reason: 'still in flight after the remount',
        );
        await tester.tap(_linkBox(_levelId), warnIfMissed: false);
        await tester.pump();
        expect(t.links.calls, hasLength(1), reason: 'no second write');

        links.gate!.complete();
        await pumpFrames(tester);
        expect(t.links.calls, hasLength(1));
        expect(_row(_levelId), findsNothing, reason: 'the link finished');
      },
    );

    testWidgets(
      'a link that finishes while the tab is hidden keeps its row hidden when the tab returns',
      (tester) async {
        final links = FakeEchoLinkActions()..gate = Completer<void>();
        final t = await _pump(
          tester,
          result: _ready([_echo(), _garden()]),
          links: links,
        );
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        await showTab(tester, t, RightPanelTab.activity);
        links.gate!.complete();
        await pumpFrames(tester);

        // Hold any read so the old result is what the tab shows first.
        t.echoes.gate = Completer<void>();
        await showTab(tester, t, RightPanelTab.echoes);
        expect(_row(_levelId), findsNothing, reason: 'hidden before a re-read');
        expect(_row(_gardenId), findsOneWidget);

        t.echoes.gate!.complete();
        t.echoes.gate = null;
        await pumpFrames(tester);
        expect(
          _row(_levelId),
          findsNothing,
          reason: 'hidden after the re-read',
        );
        expect(_row(_gardenId), findsOneWidget);
        expect(t.links.calls, hasLength(1));
      },
    );

    testWidgets('a linked row stays hidden across a tab switch and back', (
      tester,
    ) async {
      final t = await _pump(tester, result: _ready([_echo(), _garden()]));
      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);
      expect(_row(_levelId), findsNothing);

      t.echoes.gate = Completer<void>();
      await showTab(tester, t, RightPanelTab.activity);
      await showTab(tester, t, RightPanelTab.echoes);

      expect(_row(_levelId), findsNothing, reason: 'no flash of the old row');
      expect(_row(_gardenId), findsOneWidget);
      t.echoes.gate!.complete();
      t.echoes.gate = null;
      await pumpFrames(tester);
      expect(_row(_levelId), findsNothing);
    });

    testWidgets(
      'a link that fails while the tab is hidden shows its inline error when the tab returns',
      (tester) async {
        final links = FakeEchoLinkActions(
          failure: MemexException('add_link failed: database is locked'),
        )..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        await showTab(tester, t, RightPanelTab.activity);
        links.gate!.complete();
        await pumpFrames(tester);
        await showTab(tester, t, RightPanelTab.echoes);

        final error = _inRow(_levelId, find.byKey(const Key('inline-error')));
        expect(error, findsOneWidget);
        expect(
          find.descendant(
            of: error,
            matching: find.text('add_link failed: database is locked'),
          ),
          findsOneWidget,
        );
        expect(
          tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
          isNotNull,
          reason: 'the failed link is free to retry',
        );
      },
    );

    testWidgets('a vault switch resets the hidden rows and the link errors', (
      tester,
    ) async {
      final links = FakeEchoLinkActions();
      final t = await _pump(
        tester,
        result: _ready([_echo(), _garden()]),
        links: links,
      );
      // Garden fails, Level Design links.
      links.failure = MemexException('add_link failed: gone');
      await tester.tap(_linkBox(_gardenId));
      await pumpFrames(tester);
      links.failure = null;
      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);
      expect(_row(_levelId), findsNothing);
      expect(
        _inRow(_gardenId, find.byKey(const Key('inline-error'))),
        findsOneWidget,
      );

      t.h.container.read(currentVaultProvider.notifier).state =
          const LocalVaultRef('/other-vault');
      await pumpFrames(tester);

      expect(_row(_levelId), findsOneWidget, reason: 'hidden rows reset');
      expect(
        find.byKey(const Key('inline-error')),
        findsNothing,
        reason: 'errors reset',
      );
    });

    testWidgets('a vault switch frees a link that was in flight', (
      tester,
    ) async {
      final links = FakeEchoLinkActions()..gate = Completer<void>();
      final t = await _pump(tester, result: _ready([_echo()]), links: links);
      await tester.tap(_linkBox(_levelId));
      await tester.pump();
      expect(tester.widget<OmButton>(_linkButton(_levelId)).onPressed, isNull);

      t.h.container.read(currentVaultProvider.notifier).state =
          const LocalVaultRef('/other-vault');
      await pumpFrames(tester);

      expect(
        tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
        isNotNull,
        reason: 'busy belongs to the vault',
      );
    });
    for (final (name, failure) in [
      (
        'a link that succeeds after a note switch does not hide the row on the new note',
        null,
      ),
      (
        'a link that fails after a note switch shows no inline error on the new note',
        MemexException('add_link failed: database is locked'),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final links = FakeEchoLinkActions(failure: failure)
          ..gate = Completer<void>();
        final t = await _pump(tester, result: _ready([_echo()]), links: links);
        t.h.db.seedNote(id: _otherOpenId, title: 'Other note');
        await tester.tap(_linkBox(_levelId));
        await tester.pump();
        t.select(_otherOpenId);
        await pumpFrames(tester);
        expect(_row(_levelId), findsOneWidget, reason: 'the new note lists it');

        links.gate!.complete();
        await pumpFrames(tester);

        expect(_row(_levelId), findsOneWidget, reason: 'the link was for A');
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(
          tester.widget<OmButton>(_linkButton(_levelId)).onPressed,
          isNotNull,
        );
      });
    }
    testWidgets('pressing link again clears the earlier link error at once', (
      tester,
    ) async {
      final links = FakeEchoLinkActions(
        failure: MemexException('add_link failed: database is locked'),
      );
      final t = await _pump(tester, result: _ready([_echo()]), links: links);
      await tester.tap(_linkBox(_levelId));
      await pumpFrames(tester);
      expect(find.byKey(const Key('inline-error')), findsOneWidget);

      links.gate = Completer<void>();
      await tester.tap(_linkBox(_levelId));
      await tester.pump();

      expect(t.links.calls, hasLength(2));
      expect(
        find.byKey(const Key('inline-error')),
        findsNothing,
        reason: 'the new attempt starts clean',
      );
    });
  });

  group('first load delay on a note switch', () {
    testWidgets(
      'a note switch during a first load hides the listening copy until the new note waits 400 ms',
      (tester) async {
        final echoes = FakeEchoesAccess(vaultPath: echoesVaultPath)
          ..gate = Completer<void>();
        final t = await _pump(tester, echoes: echoes);
        t.clock.advance(const Duration(milliseconds: 400));
        await tester.pump();
        expect(_copy(_listening), findsOneWidget, reason: 'note A listening');

        t.select(_otherOpenId);
        await tester.pump();
        await tester.pump();
        expect(_copy(_listening), findsNothing, reason: 'header only at 0 ms');
        _expectHeaderAndOnly(const []);

        t.clock.advance(const Duration(milliseconds: 399));
        await tester.pump();
        expect(_copy(_listening), findsNothing, reason: 'not at 399 ms');

        t.clock.advance(const Duration(milliseconds: 1));
        await tester.pump();
        _expectFg2Mono(tester, _copy(_listening));
      },
    );

    testWidgets(
      'a note switch before the listening copy showed leaves the old 400 ms mark empty',
      (tester) async {
        final echoes = FakeEchoesAccess(vaultPath: echoesVaultPath)
          ..gate = Completer<void>();
        final t = await _pump(tester, echoes: echoes);
        t.clock.advance(const Duration(milliseconds: 300));
        await tester.pump();
        expect(_copy(_listening), findsNothing);

        t.select(_otherOpenId);
        await tester.pump();
        await tester.pump();

        t.clock.advance(const Duration(milliseconds: 100));
        await tester.pump();
        expect(_copy(_listening), findsNothing, reason: 'the old note mark');
        t.clock.advance(const Duration(milliseconds: 299));
        await tester.pump();
        expect(_copy(_listening), findsNothing, reason: '399 ms after switch');

        t.clock.advance(const Duration(milliseconds: 1));
        await tester.pump();
        _expectFg2Mono(tester, _copy(_listening));
      },
    );
  });

  // ================================================================ AC12
  test('GLOSSARY.md has the Echo entry under Echoes right before Backups', () {
    final glossary = File('../GLOSSARY.md').readAsStringSync();
    const section = '## Echoes (#391)';
    const entry =
        '**Echo**:\n'
        "A passage of the person's own writing in another note that is "
        'semantically close to the open note and not linked to it, shown in '
        'the echoes tab.\n'
        '_Avoid_: suggestion, recommendation, related note';

    expect(section.allMatches(glossary), hasLength(1));
    expect('**Echo**:'.allMatches(glossary), hasLength(1));
    final at = glossary.indexOf(section);
    final backups = glossary.indexOf('## Backups (#315)');
    expect(backups, greaterThan(at), reason: 'before Backups (D25)');
    final between = glossary.substring(at + section.length, backups).trim();
    expect(between, entry, reason: 'only the entry, right before Backups');
  });
}
