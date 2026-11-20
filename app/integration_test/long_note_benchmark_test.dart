// WI #133 (Spec #122 Requirements 3-11, 37): the profile-mode long-note
// benchmark. It runs the real note editor (the whole workspace over the test
// fakes, as the gate's perf tests do) on the shared synthetic notes N1-N5 and
// reports frame build and raster times, per-event UI times and open times
// through `binding.reportData`, judged against Spec #122's Requirements.
//
// Run it with a foreground window (see `integration_test/README.md`):
//
//   flutter drive --profile -d macos \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/long_note_benchmark_test.dart
//
// `flutter test` never runs it: it sits outside `test/`, and the gate's
// `test/perf/long_note_benchmark_wiring_test.dart` pins that. The pure parts
// (the matrix, the statistics, the targets, the report) are in
// `benchmark_core.dart` and tested there.
//
// How a time is taken:
// - Frame metrics (fling, jump30, resize) come from the engine's
//   `FrameTiming`s: build is the UI thread's frame, raster the raster
//   thread's.
// - An event's UI time (keystroke, Arrow, Shift selection, pointer drag,
//   Find bar keystroke, next match, Select All) is the time its input handler
//   runs plus the UI-thread time of every frame it caused (the two frames
//   after it), measured around the framework's begin-frame and draw-frame
//   callbacks. Waiting for the next vsync is not counted.
// - An open time is the wall time from the request to the frame that shows
//   the result (it includes waiting for vsync, at most one frame).
import 'dart:async';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';
import 'package:open_memex_app/src/widgets/find/find_keys.dart';

import '../test/support/editor_rows_probe.dart';
import '../test/support/fake_spelling_service.dart';
import '../test/support/fake_vault_db.dart';
import '../test/support/font_fetch_hold.dart';
import '../test/support/long_note_fixtures.dart';
import '../test/support/note_reveal_pump.dart';
import '../test/support/segment_editing_finder.dart';
import 'benchmark_core.dart';

const _noteId = 'bench-note';
const _viewSize = Size(1440, 900);

/// Which cases and scenarios run: a comma-separated list of id prefixes (see
/// the README); empty runs everything.
const _filter = String.fromEnvironment('BENCH_CASES');

/// Events per per-event metric (Requirement 8 needs at least 20).
const _events = 24;

// ------------------------------------------------------------------ state

final _report = BenchReport();

/// What went wrong in a phase that did not finish, reported with the data.
final _failures = <String>[];

final _timings = <FrameTiming>[];

/// Sums the UI thread's frame time, from the begin-frame to the end of the
/// draw-frame callback.
class _FrameProbe {
  final _watch = Stopwatch();

  /// UI-thread milliseconds of every frame since [reset].
  double frameMs = 0;

  void reset() => frameMs = 0;

  /// Wraps the dispatcher's frame callbacks. They are set once a frame has
  /// been scheduled, so call it after the first pump.
  void install() {
    final dispatcher = PlatformDispatcher.instance;
    final begin = dispatcher.onBeginFrame;
    final draw = dispatcher.onDrawFrame;
    if (begin == null || draw == null) {
      throw StateError('no frame has run yet: the frame callbacks are unset');
    }
    dispatcher.onBeginFrame = (Duration d) {
      _watch
        ..reset()
        ..start();
      begin(d);
    };
    dispatcher.onDrawFrame = () {
      draw();
      _watch.stop();
      frameMs += _watch.elapsedMicroseconds / 1000.0;
    };
  }
}

final _probe = _FrameProbe();
bool _probeInstalled = false;

// ---------------------------------------------------------------- helpers

double _ms(Duration d) => d.inMicroseconds / 1000.0;

/// Which of the run's cases and scenarios [_filter] selects: terms that name
/// an [ExtraScenario] pick scenarios, every other term picks matrix cases.
({List<BenchCase> cases, List<ExtraScenario> scenarios}) _selection() {
  final terms = [
    for (final t in _filter.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  ];
  final matrix = benchmarkMatrix();
  if (terms.isEmpty) return (cases: matrix, scenarios: ExtraScenario.values);
  final scenarios = [
    for (final s in ExtraScenario.values)
      if (terms.any(s.id.startsWith)) s,
  ];
  final matrixTerms = [
    for (final t in terms)
      if (!ExtraScenario.values.any((s) => s.id.startsWith(t))) t,
  ];
  return (
    cases: matrixTerms.isEmpty
        ? const []
        : selectCases(matrix, matrixTerms.join(',')),
    scenarios: scenarios,
  );
}

/// Whether a Requirement judges [metric] of [id] (an unjudged metric is not
/// measured: it only costs time).
bool _judged(String id, String metric) => targetFor(id, metric) != null;

/// Runs one named phase of [id]; a failure is recorded with the results and
/// the run goes on.
Future<void> _phase(
  String id,
  String name,
  Future<void> Function() body,
) async {
  try {
    await body();
  } catch (e) {
    final text = e.toString().split('\n').first;
    _failures.add('$id $name: $text');
  }
}

/// Real time passes (the test binding is live): lets futures, timers and
/// animations finish.
Future<void> _settle(WidgetTester tester) async {
  await pumpFrames(tester);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Runs [body], then waits until the engine has reported its frame timings
/// and returns every frame since the start.
Future<List<FrameTiming>> _frames(Future<void> Function() body) async {
  _timings.clear();
  await body();
  var seen = -1;
  var stable = 0;
  for (var i = 0; i < 60 && stable < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (_timings.length == seen) {
      stable++;
    } else {
      stable = 0;
      seen = _timings.length;
    }
  }
  return List.of(_timings);
}

void _recordFrames(
  String id,
  List<FrameTiming> frames,
  String buildMetric,
  String rasterMetric,
) {
  _report
    ..record(id, buildMetric, [for (final f in frames) _ms(f.buildDuration)])
    ..record(id, rasterMetric, [for (final f in frames) _ms(f.rasterDuration)]);
}

/// The UI time of one event: [input] runs (its handler time counts), then
/// two frames are pumped, and the UI-thread time of the frames it caused is
/// added. The next vsync wait is not counted.
Future<double> _event(
  WidgetTester tester,
  FutureOr<void> Function() input,
) async {
  _probe.reset();
  final watch = Stopwatch()..start();
  await input();
  final wallMs = watch.elapsedMicroseconds / 1000.0;
  final framesInInput = _probe.frameMs;
  final inputMs = (wallMs - framesInInput).clamp(0.0, double.infinity);
  await tester.pump();
  await tester.pump();
  final total = inputMs + _probe.frameMs;
  await Future<void>.delayed(const Duration(milliseconds: 40));
  return total;
}

/// The note editor's tallest vertical scrollable (the page in live preview,
/// the field in Source mode when it scrolls itself).
ScrollableState _scrollable(WidgetTester tester) {
  ScrollableState? best;
  for (final s in tester.stateList<ScrollableState>(
    find.descendant(
      of: find.byType(EditorPage),
      matching: find.byType(Scrollable),
    ),
  )) {
    if (s.position.axis != Axis.vertical) continue;
    if (best == null ||
        s.position.maxScrollExtent > best.position.maxScrollExtent) {
      best = s;
    }
  }
  if (best == null) throw TestFailure('no vertical scrollable in the editor');
  return best;
}

/// Pins `defaultTargetPlatform` to macOS (the benchmark is a macOS run; on
/// any other host the editing shortcuts would differ).
void _asMac() {
  if (defaultTargetPlatform == TargetPlatform.macOS) return;
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
}

// ------------------------------------------------------------------- rig

/// Pumps the workspace on a vault holding one note, at the benchmark's
/// window size and real text scale.
Future<NoteRevealHarness> _pump(
  WidgetTester tester, {
  required String content,
  required FakeSpellingService spelling,
  String? role,
}) async {
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _noteId,
      title: role == 'daily' ? '2026-10-03' : 'Benchmark note',
      content: content,
      role: role,
    );
  final h = await pumpNoteReveal(
    tester,
    db: db,
    open: null,
    surfaceSize: _viewSize,
    overrides: [
      spellingServiceProvider.overrideWithValue(spelling),
      learnedWordKeysProvider.overrideWithValue(const <String>{}),
    ],
  );
  // The harness shrinks text for the gate's wide test font; the benchmark
  // runs at the real scale.
  tester.platformDispatcher.clearTextScaleFactorTestValue();
  await tester.pump();
  if (!_probeInstalled) {
    _probe.install();
    _probeInstalled = true;
  }
  return h;
}

/// Opens the note and returns the milliseconds from the request to the frame
/// that shows its first text segment.
Future<double> _open(WidgetTester tester, NoteRevealHarness h) async {
  _timings.clear();
  final watch = Stopwatch()..start();
  h.tabs.navigate(NoteTab(_noteId));
  var shown = false;
  var ms = 0.0;
  for (var i = 0; i < 400 && !shown; i++) {
    await tester.pump();
    ms = watch.elapsedMicroseconds / 1000.0;
    shown = find.byKey(textSegmentKey(0)).evaluate().isNotEmpty;
  }
  if (!shown) throw TestFailure('the note never showed its first segment');
  return ms;
}

/// Fling the page, then 30 `jumpTo` steps; records both as build and raster
/// frame metrics for [id].
Future<void> _scroll(WidgetTester tester, String id) async {
  final scrollable = _scrollable(tester);
  final position = scrollable.position;
  if (position.maxScrollExtent <= 0) {
    throw TestFailure('the note does not scroll');
  }
  position.jumpTo(0);
  await _settle(tester);

  final fling = await _frames(() async {
    await tester.fling(
      find.byWidget(scrollable.widget),
      const Offset(0, -700),
      3500,
    );
    var still = 0;
    var last = position.pixels;
    for (var i = 0; i < 80 && still < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      still = position.pixels == last ? still + 1 : 0;
      last = position.pixels;
    }
  });
  _recordFrames(id, fling, BenchMetric.flingBuild, BenchMetric.flingRaster);

  position.jumpTo(0);
  await _settle(tester);
  final jump = await _frames(() async {
    var offset = 0.0;
    for (var i = 0; i < 30; i++) {
      offset += 400;
      if (offset > position.maxScrollExtent) offset = 400;
      position.jumpTo(offset);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  });
  _recordFrames(id, jump, BenchMetric.jumpBuild, BenchMetric.jumpRaster);
}

/// Window resize drags: 30 steps narrower, 30 back, a frame each.
Future<void> _resize(WidgetTester tester, String id) async {
  final frames = await _frames(() async {
    for (var i = 1; i <= 30; i++) {
      tester.view.physicalSize = Size(
        _viewSize.width - i * 15,
        _viewSize.height,
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    for (var i = 29; i >= 0; i--) {
      tester.view.physicalSize = Size(
        _viewSize.width - i * 15,
        _viewSize.height,
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  });
  _recordFrames(id, frames, BenchMetric.resizeBuild, BenchMetric.resizeRaster);
}

/// Puts the caret mid-note, in a row's text (after a `: ` the fixtures put
/// in every line), and gives the row focus.
Future<void> _focusMiddle(WidgetTester tester) async {
  final text = segmentEditingAt(tester, 0).text;
  final colon = text.indexOf(': ', text.length ~/ 2);
  final at = colon < 0 ? text.length ~/ 2 : colon + 2;
  await focusSegmentAt(tester, find.byKey(textSegmentKey(0)), offset: at);
  await pumpFrames(tester);
}

/// The focused row's field.
EditableTextState _field(WidgetTester tester) {
  final host = rowsHostOf(tester);
  final row = host.focusedRow;
  final field = row == null ? null : host.rowField(row);
  if (field == null) throw TestFailure('no row field has focus');
  return field;
}

/// Typing: one `x` at the caret of the focused field, [_events] times.
Future<List<double>> _typing(WidgetTester tester) async {
  final out = <double>[];
  for (var i = 0; i < _events; i++) {
    final field = _field(tester);
    final value = field.textEditingValue;
    final at = value.selection.baseOffset;
    final next = TextEditingValue(
      text: value.text.replaceRange(at, at, 'x'),
      selection: TextSelection.collapsed(offset: at + 1),
    );
    out.add(await _event(tester, () => field.updateEditingValue(next)));
  }
  return out;
}

/// The macOS text system's selector [selector] on the focused field, [_events]
/// times.
Future<List<double>> _selectors(WidgetTester tester, String selector) async {
  final out = <double>[];
  for (var i = 0; i < _events; i++) {
    final field = _field(tester);
    out.add(await _event(tester, () => field.performSelector(selector)));
  }
  return out;
}

Offset _textPoint(WidgetTester tester, NoteRevealHarness h) {
  final view = h.viewport();
  return Offset(view.center.dx, view.top + 180);
}

/// A mouse press on the text, then [_events] small drags down.
Future<List<double>> _pointerDrag(
  WidgetTester tester,
  NoteRevealHarness h,
) async {
  final gesture = await tester.startGesture(
    _textPoint(tester, h),
    kind: PointerDeviceKind.mouse,
  );
  final out = <double>[];
  try {
    for (var i = 0; i < _events; i++) {
      out.add(await _event(tester, () => gesture.moveBy(const Offset(0, 6))));
    }
  } finally {
    await gesture.up();
    await tester.pump();
  }
  return out;
}

/// Cmd-[key], one event.
Future<double> _cmd(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  try {
    return await _event(
      tester,
      () => tester.sendKeyEvent(key, platform: 'macos'),
    );
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    await tester.pump();
  }
}

/// A click on the text: what clears a selection.
Future<double> _click(WidgetTester tester, NoteRevealHarness h) async {
  final at = _textPoint(tester, h);
  return _event(tester, () async {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
  });
}

/// The Find bar's query field.
EditableTextState _findField(WidgetTester tester) =>
    tester.state<EditableTextState>(
      find.descendant(
        of: find.byKey(findBarFieldKey),
        matching: find.byType(EditableText),
      ),
    );

/// Find bar keystrokes (a character added or taken off a query that matches
/// every line) and next matches (Cmd-G), [_events] each.
Future<({List<double> keys, List<double> next})> _find(
  WidgetTester tester,
  NoteRevealHarness h,
) async {
  h.container
      .read(findMenuActionsProvider.notifier)
      .dispatch(FindMenuAction.show);
  await pumpFrames(tester);
  if (find.byKey(findBarKey).evaluate().isEmpty) {
    throw TestFailure('the Find bar did not open');
  }
  void type(String query) => _findField(tester).updateEditingValue(
    TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    ),
  );
  // Not measured: the query the events then grow and shrink.
  type('Speaker');
  await _settle(tester);
  const cycle = [
    'Speaker ',
    'Speaker 1',
    'Speaker 12',
    'Speaker 123',
    'Speaker 12',
    'Speaker 1',
    'Speaker ',
    'Speaker',
  ];
  final keys = <double>[];
  for (var i = 0; i < _events; i++) {
    keys.add(await _event(tester, () => type(cycle[i % cycle.length])));
  }
  await _settle(tester);
  final next = <double>[];
  for (var i = 0; i < _events; i++) {
    next.add(
      await _event(tester, () {
        h.container
            .read(findMenuActionsProvider.notifier)
            .dispatch(FindMenuAction.next);
      }),
    );
  }
  return (keys: keys, next: next);
}

// ------------------------------------------------------------- the matrix

Future<void> _runCase(WidgetTester tester, BenchCase c) async {
  final id = c.id;
  _asMac();
  final note = longNote(c.kind, variant: c.variant);
  final spelling = FakeSpellingService();
  seedMisspellings(spelling, note);
  final h = await _pump(tester, content: '${note.text}\n', spelling: spelling);
  await h.container
      .read(settingsProvider.notifier)
      .setCheckSpelling(c.spellingOn);
  h.container.read(rightPanelOpenProvider.notifier).state = c.outlineOpen;
  if (c.outlineOpen) {
    h.container.read(rightPanelTabProvider.notifier).state =
        RightPanelTab.outline;
  }

  late double openMs;
  await _phase(id, 'open', () async {
    openMs = await _open(tester, h);
    _report.record(id, BenchMetric.openFirstScreen, [openMs]);
  });
  await _settle(tester);

  await _phase(id, 'scroll', () => _scroll(tester, id));

  final wantsEditing = [
    BenchMetric.keystroke,
    BenchMetric.arrow,
    BenchMetric.shiftSelect,
    BenchMetric.pointerDrag,
    BenchMetric.selectAll,
  ].any((m) => _judged(id, m));
  if (wantsEditing) {
    await _phase(id, 'focus', () async {
      final position = _scrollable(tester).position;
      position.jumpTo(position.maxScrollExtent / 2);
      await _settle(tester);
      await _focusMiddle(tester);
    });
    if (_judged(id, BenchMetric.keystroke)) {
      await _phase(id, 'keystroke', () async {
        _report.record(id, BenchMetric.keystroke, await _typing(tester));
      });
    }
    if (_judged(id, BenchMetric.arrow)) {
      await _phase(id, 'arrow', () async {
        _report.record(
          id,
          BenchMetric.arrow,
          await _selectors(tester, 'moveDown:'),
        );
      });
    }
    if (_judged(id, BenchMetric.shiftSelect)) {
      await _phase(id, 'shift-select', () async {
        _report.record(
          id,
          BenchMetric.shiftSelect,
          await _selectors(tester, 'moveDownAndModifySelection:'),
        );
      });
    }
    if (_judged(id, BenchMetric.pointerDrag)) {
      await _phase(id, 'pointer-drag', () async {
        _report.record(
          id,
          BenchMetric.pointerDrag,
          await _pointerDrag(tester, h),
        );
        await _settle(tester);
      });
    }
    if (_judged(id, BenchMetric.selectAll)) {
      await _phase(id, 'select-all', () async {
        await _focusMiddle(tester);
        final all = await _cmd(tester, LogicalKeyboardKey.keyA);
        await _settle(tester);
        final clear = await _click(tester, h);
        _report
          ..record(id, BenchMetric.selectAll, [all])
          ..record(id, BenchMetric.clearSelection, [clear]);
      });
    }
  }

  if (_judged(id, BenchMetric.resizeBuild)) {
    await _phase(id, 'resize', () async {
      await _resize(tester, id);
      tester.view.physicalSize = _viewSize;
      await _settle(tester);
    });
  }

  if (_judged(id, BenchMetric.findKeystroke)) {
    await _phase(id, 'find', () async {
      final r = await _find(tester, h);
      _report
        ..record(id, BenchMetric.findKeystroke, r.keys)
        ..record(id, BenchMetric.findNextMatch, r.next);
    });
  }
}

// ------------------------------------------------------- the extra scenarios

/// Source mode on N1: switching to it is the open; then scroll.
Future<void> _sourceMode(WidgetTester tester) async {
  const id = 'source-n1';
  _asMac();
  final note = longNote(LongNoteKind.n1Plain120k);
  final h = await _pump(
    tester,
    content: '${note.text}\n',
    spelling: FakeSpellingService(),
  );
  await _open(tester, h);
  await _settle(tester);
  await _phase(id, 'open', () async {
    final watch = Stopwatch()..start();
    await tester.tap(find.byKey(const Key('editor-source-toggle')));
    var shown = false;
    var ms = 0.0;
    for (var i = 0; i < 400 && !shown; i++) {
      await tester.pump();
      ms = watch.elapsedMicroseconds / 1000.0;
      shown = h.sourceSurface.evaluate().isNotEmpty;
    }
    if (!shown) throw TestFailure('Source mode never showed');
    _report.record(id, BenchMetric.openFirstScreen, [ms]);
  });
  await _settle(tester);
  await _phase(id, 'scroll', () => _scroll(tester, id));
}

/// A daily note holding N1's text, the capture gutter beside it.
Future<void> _dailyNote(WidgetTester tester) async {
  const id = 'daily-n1-capture-gutter';
  _asMac();
  final note = longNote(LongNoteKind.n1Plain120k);
  final h = await _pump(
    tester,
    content: '${note.text}\n',
    spelling: FakeSpellingService(),
    role: 'daily',
  );
  await _phase(id, 'open', () async {
    _report.record(id, BenchMetric.openFirstScreen, [await _open(tester, h)]);
  });
  await _settle(tester);
  await _phase(id, 'scroll', () => _scroll(tester, id));
}

/// Pasting all of N1 into an empty note: the time until the note shows it.
Future<void> _pasteIntoEmpty(WidgetTester tester) async {
  const id = 'paste-n1-empty-note';
  _asMac();
  final text = longNote(LongNoteKind.n1Plain120k).text;
  final h = await _pump(tester, content: '', spelling: FakeSpellingService());
  await _open(tester, h);
  await _settle(tester);
  // The clipboard answers with N1 and nothing else: the machine's own
  // clipboard is never read or written.
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          return <String, Object?>{'text': text};
        case 'Clipboard.hasStrings':
          return <String, Object?>{'value': true};
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  await _phase(id, 'paste', () async {
    await focusSegmentAt(tester, find.byKey(textSegmentKey(0)));
    await pumpFrames(tester);
    bool pasted() => segmentEditingAt(tester, 0).text.length >= text.length;
    final watch = Stopwatch()..start();
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.metaLeft,
      platform: 'macos',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV, platform: 'macos');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
    var ms = 0.0;
    var done = false;
    for (var i = 0; i < 12 && !done; i++) {
      await tester.pump();
      ms = watch.elapsedMicroseconds / 1000.0;
      done = pasted();
    }
    if (!done) {
      // The key did not reach a paste: ask the focused field for it.
      watch
        ..reset()
        ..start();
      await _field(tester).pasteText(SelectionChangedCause.keyboard);
      for (var i = 0; i < 400 && !done; i++) {
        await tester.pump();
        ms = watch.elapsedMicroseconds / 1000.0;
        done = pasted();
      }
    }
    if (!done) throw TestFailure('the pasted text never reached the note');
    _report.record(id, BenchMetric.openFirstScreen, [ms]);
  });
}

/// Reloading N1 after an outside edit: the time until the editor shows the
/// stored text.
Future<void> _reloadAfterOutsideEdit(WidgetTester tester) async {
  const id = 'reload-n1-outside-edit';
  _asMac();
  final text = longNote(LongNoteKind.n1Plain120k).text;
  final h = await _pump(
    tester,
    content: '$text\n',
    spelling: FakeSpellingService(),
  );
  await _open(tester, h);
  await _settle(tester);
  const marker = 'Edited outside the app: ';
  await _phase(id, 'reload', () async {
    h.db.db.execute(
      'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
      ['$marker$text\n', 2, _noteId],
    );
    final watch = Stopwatch()..start();
    final applied = await h.container
        .read(editorControllerProvider.notifier)
        .serverChanged(_noteId);
    if (!applied) throw TestFailure('the editor kept its own text');
    var ms = 0.0;
    var shown = false;
    for (var i = 0; i < 400 && !shown; i++) {
      await tester.pump();
      ms = watch.elapsedMicroseconds / 1000.0;
      shown = segmentEditingAt(tester, 0).text.startsWith(marker);
    }
    if (!shown) throw TestFailure('the outside edit never showed');
    _report.record(id, BenchMetric.openFirstScreen, [ms]);
  });
}

// ------------------------------------------------------------------- main

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  holdFontFetches();
  binding.addTimingsCallback(_timings.addAll);

  const timeout = Timeout(Duration(minutes: 30));
  final selection = _selection();

  void publish() {
    // The test binding checks the override is unset when a test ends.
    debugDefaultTargetPlatformOverride = null;
    binding.reportData = {..._report.toData(), 'failures': List.of(_failures)};
  }

  for (final c in selection.cases) {
    testWidgets(c.id, (tester) async {
      try {
        await _runCase(tester, c);
      } finally {
        publish();
      }
    }, timeout: timeout);
  }

  final runners = <ExtraScenario, Future<void> Function(WidgetTester)>{
    ExtraScenario.sourceModeN1: _sourceMode,
    ExtraScenario.dailyN1CaptureGutter: _dailyNote,
    ExtraScenario.pasteN1IntoEmptyNote: _pasteIntoEmpty,
    ExtraScenario.reloadN1AfterOutsideEdit: _reloadAfterOutsideEdit,
  };
  for (final s in selection.scenarios) {
    testWidgets(s.id, (tester) async {
      try {
        await runners[s]!(tester);
      } finally {
        publish();
      }
    }, timeout: timeout);
  }
}
