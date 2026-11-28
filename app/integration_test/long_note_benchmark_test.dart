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
// The app runs on the real clock (`SystemClock`), not the harness's
// `FakeClock`: the spell check's viewport-pause and post-edit timers and the
// editor's save debounce only fire on it. The binding's frame policy is
// `fullyLive`, so a scroll animation runs on the engine's vsync like a real
// fling (the default policy renders only the frames the test pumps).
//
// How a time is taken:
// - Frame metrics (fling, jump30, resize) come from the engine's
//   `FrameTiming`s: build is the UI thread's frame, raster the raster
//   thread's. Only frames inside the measured phase count (the idle frames
//   before and after are dropped by their vsync time against the begin-frame
//   times of the phase; a clock that does not match leaves no frame and
//   reads INCOMPLETE).
// - An event's UI time (keystroke, Arrow, Shift selection, pointer drag,
//   Find bar keystroke, next match, Select All) is the time its input handler
//   runs plus the UI-thread time of every frame it caused (the two frames
//   after it), measured around the framework's begin-frame and draw-frame
//   callbacks. Waiting for the next vsync is not counted.
// - An open time is the wall time from the request to the frame that shows
//   the result (it includes waiting for vsync, at most one frame).
import 'dart:async';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/pasteboard_reader.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/spell_check_controller.dart'
    show spellCheckDebounce;
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

  /// While true, [beginUs] collects the begin-frame time of every frame.
  bool recording = false;

  /// The engine timestamps (microseconds) of the frames begun while
  /// [recording].
  final beginUs = <int>[];

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
      if (recording) beginUs.add(d.inMicroseconds);
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
  } catch (e, stack) {
    // The error and the top frames of its stack, repo-relative: the first
    // line alone does not say where a throw came from.
    _failures.add(failureRecord(id, name, e, stack));
  }
}

/// Real time passes (the test binding is live, the clock real): lets futures,
/// timers and animations finish.
Future<void> _settle(WidgetTester tester) async {
  await pumpFrames(tester);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await tester.pump();
}

/// How far outside the begin-frame times of a phase a frame's vsync may sit
/// and still count as part of it (the vsync starts a frame before its begin).
const _edgeUs = 50000;

/// Runs [body], then waits until the engine has reported its frame timings
/// and returns the frames of the phase: those whose vsync time lies between
/// the first and the last begin-frame of [body] (give or take [_edgeUs]).
/// Frames of an idle app before and after it are not part of the metric.
Future<List<FrameTiming>> _frames(Future<void> Function() body) async {
  _timings.clear();
  _probe
    ..beginUs.clear()
    ..recording = true;
  try {
    await body();
  } finally {
    _probe.recording = false;
  }
  if (_probe.beginUs.isEmpty) return const [];
  final from = _probe.beginUs.first - _edgeUs;
  final to = _probe.beginUs.last + _edgeUs;
  int vsync(FrameTiming f) => f.timestampInMicroseconds(FramePhase.vsyncStart);
  // The engine reports in batches: wait until a frame past the phase arrived.
  for (var i = 0; i < 120; i++) {
    if (_timings.any((f) => vsync(f) > to)) break;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return [
    for (final f in _timings)
      if (vsync(f) >= from && vsync(f) <= to) f,
  ];
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
/// any other host the editing shortcuts would differ). The override exists
/// only in debug builds (profile and release throw on a write), so a profile
/// run on another host stops here instead of measuring the wrong shortcuts.
void _asMac() {
  if (defaultTargetPlatform == TargetPlatform.macOS) return;
  if (!kDebugMode) {
    throw TestFailure('the benchmark runs on macOS: no platform override');
  }
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
}

// ------------------------------------------------------------------- rig

bool _windowAwaited = false;

/// Before the run's first pump: waits, on the real clock, until the app is
/// active. The window is brought to the front a few seconds after launch, and
/// a focus request made before that does not stick. A window that never
/// becomes active is recorded; the run goes on (the focus waits then report
/// what they could not do).
Future<void> _awaitWindow(WidgetTester tester) async {
  if (_windowAwaited) return;
  _windowAwaited = true;
  bool active() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  final ok = await awaitCondition(
    isMet: active,
    pause: () async {
      await Future<void>.delayed(_focusPause);
      await tester.pump();
    },
    attempts: _focusTries,
  );
  if (!ok) {
    _failures.add(
      'window: the app was not active after the wait '
      '(lifecycle: ${WidgetsBinding.instance.lifecycleState})',
    );
  }
}

/// Pumps the workspace on a vault holding one note, at the benchmark's
/// window size and real text scale.
Future<NoteRevealHarness> _pump(
  WidgetTester tester, {
  required String content,
  required FakeSpellingService spelling,
  String? role,
  List<Override> extraOverrides = const [],
}) async {
  await _awaitWindow(tester);
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
      // The harness installs a FakeClock, which fires no timer until it is
      // advanced: the spell check's re-checks and the save debounce would
      // never run. The later override wins.
      clockProvider.overrideWithValue(const SystemClock()),
      spellingServiceProvider.overrideWithValue(spelling),
      learnedWordKeysProvider.overrideWithValue(const <String>{}),
      ...extraOverrides,
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

/// How far down the scroll phases reach: the fling's run-out and 30 steps of
/// 400 px, with room to spare.
const _scrollReach = 16000.0;

/// With spelling on, walks down the page a screen at a time, letting the
/// viewport pause long enough for the spell check to answer, so every
/// paragraph the scroll phases pass already has its squiggles (the check
/// only covers one screen around the viewport, after a pause). Then back to
/// the top.
Future<void> _warmSpelling(WidgetTester tester, ScrollPosition position) async {
  final reach = _scrollReach < position.maxScrollExtent
      ? _scrollReach
      : position.maxScrollExtent;
  final step = position.viewportDimension;
  for (var offset = 0.0; offset <= reach; offset += step) {
    position.jumpTo(offset);
    await tester.pump();
    await Future<void>.delayed(
      spellCheckDebounce + const Duration(milliseconds: 250),
    );
    await tester.pump();
  }
  position.jumpTo(0);
  await _settle(tester);
}

/// Fling the page, then 30 `jumpTo` steps; records both as build and raster
/// frame metrics for [id]. [warm] first lets the spell check cover the part
/// of the page the scroll passes.
Future<void> _scroll(
  WidgetTester tester,
  String id, {
  bool warm = false,
}) async {
  final scrollable = _scrollable(tester);
  final position = scrollable.position;
  if (position.maxScrollExtent <= 0) {
    throw TestFailure('the note does not scroll');
  }
  position.jumpTo(0);
  await _settle(tester);
  if (warm) await _warmSpelling(tester, position);

  final fling = await _frames(() async {
    await tester.fling(
      find.byWidget(scrollable.widget),
      const Offset(0, -700),
      3500,
    );
    // The binding is fully live: the ballistic scroll runs on the engine's
    // frames. Wait, in real time, until it stops.
    var still = 0;
    var last = position.pixels;
    for (var i = 0; i < 100 && still < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
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

/// Whether the first segment's rows host has a row with focus.
bool _rowHasFocus(WidgetTester tester) {
  try {
    return rowsHostOf(tester).focusedRow != null;
  } on StateError {
    return false;
  }
}

/// How long [_holdFocus] waits in all: 60 tries, half a second apart.
const _focusTries = 60;
const _focusPause = Duration(milliseconds: 500);

/// Waits, on the real clock, until a row field of the first segment holds
/// focus, asking for it with [request] every time it does not. The app window
/// may not be key yet (the first case of a run starts before the window comes
/// to the front), and a focus request made then does not stick. Throws when
/// focus never arrives.
Future<void> _holdFocus(
  WidgetTester tester,
  Future<void> Function() request,
) async {
  final held = await awaitCondition(
    isMet: () => _rowHasFocus(tester),
    nudge: request,
    pause: () async {
      await Future<void>.delayed(_focusPause);
      await tester.pump();
    },
    attempts: _focusTries,
  );
  if (!held) {
    final seconds = _focusTries * _focusPause.inMilliseconds ~/ 1000;
    throw TestFailure(
      'no row field held focus after $seconds s '
      '(app lifecycle: ${WidgetsBinding.instance.lifecycleState})',
    );
  }
}

/// Puts the caret mid-note, in a row's text (after a `: ` the fixtures put
/// in every line), and gives the row focus; waits until a row field holds it.
Future<void> _focusMiddle(WidgetTester tester) async {
  Future<void> request() async {
    final text = segmentEditingAt(tester, 0).text;
    final colon = text.indexOf(': ', text.length ~/ 2);
    final at = colon < 0 ? text.length ~/ 2 : colon + 2;
    await focusSegmentAt(tester, find.byKey(textSegmentKey(0)), offset: at);
    await pumpFrames(tester);
  }

  await request();
  await _holdFocus(tester, request);
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

// Simulated macOS key events. Each passes its physical key: without one the
// test binding looks it up by `debugName`, which is null in a profile build,
// and the simulation throws a null check error (see [benchmarkPhysicalKey]).

Future<bool> _keyDown(WidgetTester tester, LogicalKeyboardKey key) =>
    tester.sendKeyDownEvent(
      key,
      platform: 'macos',
      physicalKey: benchmarkPhysicalKey(key),
    );

Future<bool> _keyPress(WidgetTester tester, LogicalKeyboardKey key) =>
    tester.sendKeyEvent(
      key,
      platform: 'macos',
      physicalKey: benchmarkPhysicalKey(key),
    );

Future<bool> _keyUp(WidgetTester tester, LogicalKeyboardKey key) =>
    tester.sendKeyUpEvent(
      key,
      platform: 'macos',
      physicalKey: benchmarkPhysicalKey(key),
    );

/// Cmd-[key], one event.
Future<double> _cmd(WidgetTester tester, LogicalKeyboardKey key) async {
  await _keyDown(tester, LogicalKeyboardKey.metaLeft);
  try {
    return await _event(tester, () => _keyPress(tester, key));
  } finally {
    await _keyUp(tester, LogicalKeyboardKey.metaLeft);
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

/// Scrolls to the middle of the page and puts the caret in a row there.
Future<void> _focusInMiddle(WidgetTester tester) async {
  final position = _scrollable(tester).position;
  position.jumpTo(position.maxScrollExtent / 2);
  await _settle(tester);
  await _focusMiddle(tester);
}

Future<void> _runCase(WidgetTester tester, BenchCase c) async {
  final id = c.id;
  // Every pair a Requirement judges is owed a verdict: one that a failed
  // phase never records reads INCOMPLETE.
  _report
    ..expectCase(id)
    ..expectCase(caretCaseId(id), metrics: BenchMetric.scroll);
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

  // No caret in the note; with spelling on, the spell check first covers the
  // page the scroll passes (see [_warmSpelling]).
  await _phase(id, 'scroll', () => _scroll(tester, id, warm: c.spellingOn));

  // The same scroll with the caret in the note (Requirement 3), recorded
  // under its own id.
  // Only when the caret landed: without one the rows would read as a caret
  // scroll that never had a caret, so a failed focus leaves them INCOMPLETE.
  await _phase(id, 'focus', () => _focusInMiddle(tester));
  if (rowsHostOf(tester).focusedRow != null) {
    await _phase(
      id,
      'scroll with caret',
      () => _scroll(tester, caretCaseId(id)),
    );
  }

  final wantsEditing = [
    BenchMetric.keystroke,
    BenchMetric.arrow,
    BenchMetric.shiftSelect,
    BenchMetric.pointerDrag,
    BenchMetric.selectAll,
  ].any((m) => _judged(id, m));
  if (wantsEditing) {
    await _phase(id, 'refocus', () => _focusInMiddle(tester));
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
  _report.expectCase(id);
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
  _report.expectCase(id);
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

/// A pasteboard that holds text and nothing else. The editor's paste first
/// asks the app's pasteboard reader whether files or an image sit on the
/// clipboard to attach; the default reader asks the machine's own clipboard,
/// which the benchmark never reads.
class _TextOnlyPasteboard implements PasteboardReader {
  const _TextOnlyPasteboard();

  @override
  Future<PasteboardContents> read() async =>
      const PasteboardContents(hasText: true);
}

/// Pasting all of N1 into an empty note: the time until the note shows it.
Future<void> _pasteIntoEmpty(WidgetTester tester) async {
  const id = 'paste-n1-empty-note';
  _report.expectCase(id);
  _asMac();
  final text = longNote(LongNoteKind.n1Plain120k).text;
  final h = await _pump(
    tester,
    content: '',
    spelling: FakeSpellingService(),
    extraOverrides: [
      pasteboardReaderProvider.overrideWithValue(const _TextOnlyPasteboard()),
    ],
  );
  await _open(tester, h);
  await _settle(tester);
  // The clipboard answers with N1 and nothing else: the machine's own
  // clipboard is never read or written.
  var reads = 0;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          reads++;
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
    Future<void> focusRow() async {
      await focusSegmentAt(tester, find.byKey(textSegmentKey(0)));
      await pumpFrames(tester);
    }

    await focusRow();
    await _holdFocus(tester, focusRow);
    bool pasted() => segmentEditingAt(tester, 0).text.length >= text.length;
    final watch = Stopwatch()..start();
    await _keyDown(tester, LogicalKeyboardKey.metaLeft);
    await _keyPress(tester, LogicalKeyboardKey.keyV);
    await _keyUp(tester, LogicalKeyboardKey.metaLeft);
    // Cmd-V reaches the clipboard within a few frames, or never.
    for (var i = 0; i < 30 && reads == 0; i++) {
      await tester.pump();
    }
    if (reads == 0) {
      // The key started no paste: ask the focused field for it (nothing is
      // in flight, so the text cannot land twice).
      watch
        ..reset()
        ..start();
      await _field(tester).pasteText(SelectionChangedCause.keyboard);
    }
    // A paste in flight is waited for, however long it takes.
    var ms = watch.elapsedMicroseconds / 1000.0;
    var done = pasted();
    for (var i = 0; i < 2000 && !done; i++) {
      await tester.pump();
      ms = watch.elapsedMicroseconds / 1000.0;
      done = pasted();
    }
    if (!done) throw TestFailure('the pasted text never reached the note');
    _report.record(id, BenchMetric.openFirstScreen, [ms]);
  });
}

/// Reloading N1 after an outside edit: the time until the editor shows the
/// stored text.
Future<void> _reloadAfterOutsideEdit(WidgetTester tester) async {
  const id = 'reload-n1-outside-edit';
  _report.expectCase(id);
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
  // Every frame the framework asks for is drawn (the default policy draws
  // only the frames a test pumps, so a fling would advance in 100 ms steps).
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  holdFontFetches();
  binding.addTimingsCallback(_timings.addAll);

  const timeout = Timeout(Duration(minutes: 30));
  final selection = _selection();

  void publish() {
    try {
      binding.reportData = {
        ..._report.toData(),
        'failures': List.of(_failures),
      };
    } finally {
      // The test binding checks the override is unset when a test ends. The
      // override is a debug-only setter: a write throws in profile and
      // release, and that must never keep the report from being set.
      if (kDebugMode) debugDefaultTargetPlatformOverride = null;
    }
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
