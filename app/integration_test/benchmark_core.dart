// WI #133 (Spec #122 Requirements 3-11, 37): the pure core of the profile-mode
// long-note benchmark (`long_note_benchmark_test.dart`): which cases it runs,
// how samples are summarised, which Requirement judges each metric, and what
// it reports. It imports no `integration_test` package, so the gate's
// `test/perf/long_note_benchmark_core_test.dart` runs it as plain Dart.
//
// The tests in `test/perf/long_note_benchmark_core_test.dart` are the
// contract.
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, PhysicalKeyboardKey;

import '../test/support/long_note_fixtures.dart';

/// The metric names the benchmark reports (the keys under a case in the
/// report, the `Metric` column of the results table, the names the README
/// explains).
abstract final class BenchMetric {
  static const String flingBuild = 'fling-build';
  static const String flingRaster = 'fling-raster';
  static const String jumpBuild = 'jump30-build';
  static const String jumpRaster = 'jump30-raster';
  static const String openFirstScreen = 'open-first-screen';
  static const String keystroke = 'keystroke';
  static const String arrow = 'arrow';
  static const String shiftSelect = 'shift-arrow-select';
  static const String pointerDrag = 'pointer-drag';
  static const String findKeystroke = 'find-bar-keystroke';
  static const String findNextMatch = 'find-next-match';
  static const String resizeBuild = 'resize-build';
  static const String resizeRaster = 'resize-raster';
  static const String selectAll = 'select-all';
  static const String clearSelection = 'select-all-clear';

  /// Every metric, in the order above.
  static const List<String> all = [
    flingBuild,
    flingRaster,
    jumpBuild,
    jumpRaster,
    openFirstScreen,
    keystroke,
    arrow,
    shiftSelect,
    pointerDrag,
    findKeystroke,
    findNextMatch,
    resizeBuild,
    resizeRaster,
    selectAll,
    clearSelection,
  ];

  /// The four scrolling metrics (fling and 30 `jumpTo` steps, build and
  /// raster).
  static const List<String> scroll = [
    flingBuild,
    flingRaster,
    jumpBuild,
    jumpRaster,
  ];
}

/// The frame budget of 60 fps, in milliseconds: what "holds 60 fps" (Spec
/// #122 Requirement 3) asks the p90 frame to fit in.
const double sixtyFpsFrameMs = 16.7;

/// Millisecond samples, summarised.
class MsStats {
  const MsStats({
    required this.count,
    required this.median,
    required this.p90,
    required this.max,
  });

  final int count;
  final double median;
  final double p90;
  final double max;

  /// `{count, median, p90, max}`, JSON-encodable.
  Map<String, Object> toJson() => {
    'count': count,
    'median': median,
    'p90': p90,
    'max': max,
  };
}

/// Summarises [samples] (any order): the count, the median (the mean of the
/// two middle samples for an even count), the p90 (nearest rank: the sample
/// at 1-based rank `ceil(0.9 * count)` of the sorted samples) and the max.
/// No samples give a count of 0 and 0.0 for the rest.
MsStats summarize(Iterable<double> samples) {
  final sorted = samples.toList()..sort();
  final n = sorted.length;
  if (n == 0) return const MsStats(count: 0, median: 0, p90: 0, max: 0);
  final median = n.isOdd
      ? sorted[n ~/ 2]
      : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
  // ceil(0.9 * n) in integers, so no floating point rounds a rank over.
  final rank = (9 * n + 9) ~/ 10;
  return MsStats(
    count: n,
    median: median,
    p90: sorted[rank - 1],
    max: sorted.last,
  );
}

/// One cell of the matrix.
class BenchCase {
  const BenchCase({
    required this.kind,
    required this.variant,
    required this.outlineOpen,
    required this.spellingOn,
  });

  final LongNoteKind kind;
  final LongNoteVariant variant;
  final bool outlineOpen;
  final bool spellingOn;

  /// The kind (`n1` to `n5`), the variant (`plain`, `misspelled`,
  /// `misspelled-heavy`, `decorated`), `outline-open` or `outline-closed`,
  /// then `spell-on` or `spell-off`, joined by dashes: for example
  /// `n1-plain-outline-open-spell-on`.
  String get id =>
      '${_kindId(kind)}-${_variantId(variant)}-'
      '${outlineOpen ? 'outline-open' : 'outline-closed'}-'
      '${spellingOn ? 'spell-on' : 'spell-off'}';
}

String _kindId(LongNoteKind kind) => switch (kind) {
  LongNoteKind.n1Plain120k => 'n1',
  LongNoteKind.n2Bullets120k => 'n2',
  LongNoteKind.n3Plain500k => 'n3',
  LongNoteKind.n4Bullets500k => 'n4',
  LongNoteKind.n5PlainLongLines120k => 'n5',
};

String _variantId(LongNoteVariant variant) => switch (variant) {
  LongNoteVariant.plain => 'plain',
  LongNoteVariant.misspelled => 'misspelled',
  LongNoteVariant.misspelledHeavy => 'misspelled-heavy',
  LongNoteVariant.decorated => 'decorated',
};

/// The matrix: kinds in the order N1, N2, N5, N3, N4; within a kind the
/// variants plain, misspelled, misspelled-heavy (N1, N2, N5 only), decorated;
/// within a variant Outline open then closed; within that spelling on then
/// off.
List<BenchCase> benchmarkMatrix() {
  const kinds = [
    LongNoteKind.n1Plain120k,
    LongNoteKind.n2Bullets120k,
    LongNoteKind.n5PlainLongLines120k,
    LongNoteKind.n3Plain500k,
    LongNoteKind.n4Bullets500k,
  ];
  const variants = [
    LongNoteVariant.plain,
    LongNoteVariant.misspelled,
    LongNoteVariant.misspelledHeavy,
    LongNoteVariant.decorated,
  ];
  const huge = {LongNoteKind.n3Plain500k, LongNoteKind.n4Bullets500k};
  return [
    for (final kind in kinds)
      for (final variant in variants)
        if (variant != LongNoteVariant.misspelledHeavy || !huge.contains(kind))
          for (final outlineOpen in const [true, false])
            for (final spellingOn in const [true, false])
              BenchCase(
                kind: kind,
                variant: variant,
                outlineOpen: outlineOpen,
                spellingOn: spellingOn,
              ),
  ];
}

/// The cases of [all] whose id starts with one of the comma-separated terms
/// of [filter] (surrounding spaces ignored), in [all]'s order and each once.
/// An empty or blank [filter] selects all of [all]. A term that matches no
/// case throws an [ArgumentError] naming it.
List<BenchCase> selectCases(List<BenchCase> all, String filter) {
  final terms = [
    for (final t in filter.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  ];
  if (terms.isEmpty) return all;
  for (final term in terms) {
    if (!all.any((c) => c.id.startsWith(term))) {
      throw ArgumentError.value(
        term,
        'BENCH_CASES',
        'matches no case id (ids look like n1-plain-outline-open-spell-on)',
      );
    }
  }
  return [
    for (final c in all)
      if (terms.any(c.id.startsWith)) c,
  ];
}

/// The runs outside the matrix.
enum ExtraScenario {
  /// Source mode on N1.
  sourceModeN1,

  /// A daily note with N1-sized content, the capture gutter showing.
  dailyN1CaptureGutter,

  /// Pasting the whole N1 text into an empty note.
  pasteN1IntoEmptyNote,

  /// Reloading N1 after an outside edit.
  reloadN1AfterOutsideEdit;

  /// `source-n1`, `daily-n1-capture-gutter`, `paste-n1-empty-note`,
  /// `reload-n1-outside-edit`.
  String get id => switch (this) {
    ExtraScenario.sourceModeN1 => 'source-n1',
    ExtraScenario.dailyN1CaptureGutter => 'daily-n1-capture-gutter',
    ExtraScenario.pasteN1IntoEmptyNote => 'paste-n1-empty-note',
    ExtraScenario.reloadN1AfterOutsideEdit => 'reload-n1-outside-edit',
  };
}

/// One Requirement's limit on one metric over a set of cases.
class BenchTarget {
  const BenchTarget({
    required this.requirement,
    required this.metrics,
    required this.covers,
    required this.limitMs,
    this.strict = false,
    this.minSamples = 1,
    this.p90LimitMs,
  });

  /// The Spec #122 Requirement number, as written there: `3`, `6a`, `8`.
  final String requirement;

  /// The [BenchMetric]s it limits.
  final List<String> metrics;

  /// The case ids it covers, as id prefixes (`n1-`, `source-n1`).
  final List<String> covers;

  final double limitMs;

  /// True: the observed value must be below [limitMs]; false: at most it.
  final bool strict;

  /// Fewer samples than this make the verdict incomplete.
  final int minSamples;

  /// When set, the p90 of the samples must also be at most this (a second
  /// verdict row, for "holds 60 fps": most frames fit the frame budget while
  /// [limitMs] caps the worst one).
  final double? p90LimitMs;
}

/// Every Requirement's target (Spec #122 Requirements 3-11).
///
/// Every verdict reads the max of the samples: Requirements 3, 6 and 6a say
/// no frame over a limit, and 4, 7 and 8 say at most a limit per event. The
/// scrolling targets of Requirements 3, 10 and 11 also read the p90 against
/// the 60 fps frame budget (`p90LimitMs`), because they say the scroll "holds
/// 60 fps".
const List<BenchTarget> benchTargets = [
  // 3: scrolling N1, N2 and N5 (every variant) holds 60 fps, no frame over
  // 32 ms.
  BenchTarget(
    requirement: '3',
    metrics: [
      BenchMetric.flingBuild,
      BenchMetric.flingRaster,
      BenchMetric.jumpBuild,
      BenchMetric.jumpRaster,
    ],
    covers: ['n1-', 'n2-', 'n5-'],
    limitMs: 32,
    p90LimitMs: sixtyFpsFrameMs,
  ),
  // 4: one character typed mid-note in N1 or N2, at most 16 ms (L10).
  BenchTarget(
    requirement: '4',
    metrics: [BenchMetric.keystroke],
    covers: ['n1-', 'n2-'],
    limitMs: 16,
  ),
  // 5: N1 or N2 shows its first screen within 500 ms.
  BenchTarget(
    requirement: '5',
    metrics: [BenchMetric.openFirstScreen],
    covers: ['n1-', 'n2-'],
    limitMs: 500,
  ),
  // 6: N3 and N4: no frame over 100 ms, open within 2 s.
  BenchTarget(
    requirement: '6',
    metrics: [
      BenchMetric.flingBuild,
      BenchMetric.flingRaster,
      BenchMetric.jumpBuild,
      BenchMetric.jumpRaster,
      BenchMetric.keystroke,
      BenchMetric.arrow,
    ],
    covers: ['n3-', 'n4-'],
    limitMs: 100,
  ),
  BenchTarget(
    requirement: '6',
    metrics: [BenchMetric.openFirstScreen],
    covers: ['n3-', 'n4-'],
    limitMs: 2000,
  ),
  // 6a: resizing the window on N1 and N3, no frame over 100 ms.
  BenchTarget(
    requirement: '6a',
    metrics: [BenchMetric.resizeBuild, BenchMetric.resizeRaster],
    covers: ['n1-', 'n3-'],
    limitMs: 100,
  ),
  // 6b: Select All on N1 and N2 under 100 ms; on N3 and N4 up to 1 s.
  BenchTarget(
    requirement: '6b',
    metrics: [BenchMetric.selectAll, BenchMetric.clearSelection],
    covers: ['n1-', 'n2-'],
    limitMs: 100,
    strict: true,
  ),
  BenchTarget(
    requirement: '6b',
    metrics: [BenchMetric.selectAll, BenchMetric.clearSelection],
    covers: ['n3-', 'n4-'],
    limitMs: 1000,
  ),
  // 7: Arrow, Shift selection and pointer drag in N1 and N2, at most 16 ms.
  BenchTarget(
    requirement: '7',
    metrics: [
      BenchMetric.arrow,
      BenchMetric.shiftSelect,
      BenchMetric.pointerDrag,
    ],
    covers: ['n1-', 'n2-'],
    limitMs: 16,
  ),
  // 8: a Find bar keystroke and a next match, at most 50 ms (20+ events).
  BenchTarget(
    requirement: '8',
    metrics: [BenchMetric.findKeystroke, BenchMetric.findNextMatch],
    covers: ['n1-', 'n2-'],
    limitMs: 50,
    minSamples: 20,
  ),
  // 9: pasting N1 into an empty note, and reloading it, open within 500 ms.
  BenchTarget(
    requirement: '9',
    metrics: [BenchMetric.openFirstScreen],
    covers: ['paste-n1-', 'reload-n1-'],
    limitMs: 500,
  ),
  // 10: Source mode on N1 meets the scroll and open limits.
  BenchTarget(
    requirement: '10',
    metrics: [
      BenchMetric.flingBuild,
      BenchMetric.flingRaster,
      BenchMetric.jumpBuild,
      BenchMetric.jumpRaster,
    ],
    covers: ['source-n1'],
    limitMs: 32,
    p90LimitMs: sixtyFpsFrameMs,
  ),
  BenchTarget(
    requirement: '10',
    metrics: [BenchMetric.openFirstScreen],
    covers: ['source-n1'],
    limitMs: 500,
  ),
  // 11: a daily note with N1-sized content and the capture gutter.
  BenchTarget(
    requirement: '11',
    metrics: [
      BenchMetric.flingBuild,
      BenchMetric.flingRaster,
      BenchMetric.jumpBuild,
      BenchMetric.jumpRaster,
    ],
    covers: ['daily-n1-'],
    limitMs: 32,
    p90LimitMs: sixtyFpsFrameMs,
  ),
  BenchTarget(
    requirement: '11',
    metrics: [BenchMetric.openFirstScreen],
    covers: ['daily-n1-'],
    limitMs: 500,
  ),
];

/// The target that judges [metric] of the case or scenario [caseId], or null
/// when none does.
BenchTarget? targetFor(String caseId, String metric) {
  for (final t in benchTargets) {
    if (t.metrics.contains(metric) && t.covers.any(caseId.startsWith)) {
      return t;
    }
  }
  return null;
}

/// `PASS` when [stats].max meets [target]'s limit (`<=`, or `<` when
/// strict), `MISS` when it does not, and `INCOMPLETE` (judged first) when
/// [stats].count is below the target's minSamples.
String judge(BenchTarget target, MsStats stats) {
  if (stats.count == 0 || stats.count < target.minSamples) {
    return 'INCOMPLETE';
  }
  final meets = target.strict
      ? stats.max < target.limitMs
      : stats.max <= target.limitMs;
  return meets ? 'PASS' : 'MISS';
}

/// The p90 verdict of a target with a `p90LimitMs`: `PASS` when
/// [stats].p90 is at most it, `MISS` when it is not, and `INCOMPLETE` (judged
/// first) with no samples or fewer than the target's minSamples. A target
/// without a p90 limit has no p90 verdict: `PASS`.
String judgeP90(BenchTarget target, MsStats stats) {
  final limit = target.p90LimitMs;
  if (limit == null) return 'PASS';
  if (stats.count == 0 || stats.count < target.minSamples) {
    return 'INCOMPLETE';
  }
  return stats.p90 <= limit ? 'PASS' : 'MISS';
}

/// The metrics a Requirement judges for [caseId], in [BenchMetric.all]'s
/// order: the ones the benchmark must record for that case or scenario.
List<String> expectedMetrics(String caseId) => [
  for (final m in BenchMetric.all)
    if (targetFor(caseId, m) != null) m,
];

/// The id the benchmark records a scroll under with the caret in the note
/// (Requirement 3: "with the caret in the note and not"). It starts with
/// [caseId], so the same targets judge it.
String caretCaseId(String caseId) => '$caseId-caret';

/// One judged (case, metric) of a [BenchReport].
class VerdictRow {
  const VerdictRow({
    required this.requirement,
    required this.caseId,
    required this.metric,
    required this.limitMs,
    required this.observedMs,
    required this.verdict,
  });

  final String requirement;
  final String caseId;
  final String metric;
  final double limitMs;

  /// The max of the samples.
  final double observedMs;

  /// `PASS`, `MISS` or `INCOMPLETE`.
  final String verdict;

  /// `{requirement, case, metric, limitMs, observedMs, verdict}`.
  Map<String, Object> toJson() => {
    'requirement': requirement,
    'case': caseId,
    'metric': metric,
    'limitMs': limitMs,
    'observedMs': observedMs,
    'verdict': verdict,
  };
}

/// What a benchmark run collects and reports.
class BenchReport {
  // Insertion-ordered: a pair keeps the place of its first record.
  final Map<(String, String), MsStats> _stats = {};

  // Pairs the run was meant to record (see [expectCase]), in order.
  final List<(String, String)> _expected = [];

  /// Summarises [samples] and stores them under [caseId] and [metric]; a
  /// second record of the same pair replaces the first.
  void record(String caseId, String metric, Iterable<double> samples) {
    _stats[(caseId, metric)] = summarize(samples);
  }

  /// Declares that the run is meant to record [metrics] (by default
  /// [expectedMetrics]) of [caseId]. A declared pair that no [record] fills
  /// gets an `INCOMPLETE` row in [verdicts], so a phase that failed or was
  /// skipped shows in the table instead of vanishing from it. Pairs no target
  /// judges are ignored.
  void expectCase(String caseId, {Iterable<String>? metrics}) {
    for (final m in metrics ?? expectedMetrics(caseId)) {
      final pair = (caseId, m);
      if (targetFor(caseId, m) != null && !_expected.contains(pair)) {
        _expected.add(pair);
      }
    }
  }

  /// The stored summary, or null when nothing was recorded.
  MsStats? stats(String caseId, String metric) => _stats[(caseId, metric)];

  /// One row per recorded pair that a target judges, in the order first
  /// recorded, each followed by its p90 row (metric `<metric> (p90)`, the
  /// p90 as the observed value) when its target has a `p90LimitMs`; then an
  /// `INCOMPLETE` row (observed 0) for every pair declared with [expectCase]
  /// and never recorded.
  List<VerdictRow> verdicts() {
    final rows = <VerdictRow>[];
    void add(String caseId, String metric, MsStats stats) {
      final target = targetFor(caseId, metric);
      if (target == null) return;
      rows.add(
        VerdictRow(
          requirement: target.requirement,
          caseId: caseId,
          metric: metric,
          limitMs: target.limitMs,
          observedMs: stats.max,
          verdict: judge(target, stats),
        ),
      );
      final p90Limit = target.p90LimitMs;
      if (p90Limit != null) {
        rows.add(
          VerdictRow(
            requirement: target.requirement,
            caseId: caseId,
            metric: '$metric (p90)',
            limitMs: p90Limit,
            observedMs: stats.p90,
            verdict: judgeP90(target, stats),
          ),
        );
      }
    }

    for (final e in _stats.entries) {
      final (caseId, metric) = e.key;
      add(caseId, metric, e.value);
    }
    for (final (caseId, metric) in _expected) {
      if (!_stats.containsKey((caseId, metric))) {
        add(caseId, metric, summarize(const <double>[]));
      }
    }
    return rows;
  }

  /// A map with `cases` (case id, then metric, then the stats JSON),
  /// `verdicts` (each row's JSON) and `markdown` (the [toMarkdown] text),
  /// JSON-encodable, for `binding.reportData`.
  Map<String, Object> toData() {
    final cases = <String, Map<String, Object>>{};
    for (final e in _stats.entries) {
      final (caseId, metric) = e.key;
      (cases[caseId] ??= <String, Object>{})[metric] = e.value.toJson();
    }
    return {
      'cases': cases,
      'verdicts': [for (final v in verdicts()) v.toJson()],
      'markdown': toMarkdown(),
    };
  }

  /// A Markdown table, one line per verdict: the header
  /// `| Requirement | Case | Metric | Limit (ms) | Max (ms) | Verdict |`, the
  /// separator `| --- | --- | --- | --- | --- | --- |`, then one line per
  /// verdict row with the limit in whole milliseconds (one decimal when it is
  /// not whole, the 60 fps budget 16.7) and the max with one decimal, for example `| 8 | n1-plain-outline-closed-spell-on |
  /// find-bar-keystroke | 50 | 62.5 | MISS |` (on one line).
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln(
        '| Requirement | Case | Metric | Limit (ms) | Max (ms) | Verdict |',
      )
      ..writeln('| --- | --- | --- | --- | --- | --- |');
    for (final v in verdicts()) {
      b.writeln(
        '| ${v.requirement} | ${v.caseId} | ${v.metric} | '
        '${v.limitMs.toStringAsFixed(v.limitMs == v.limitMs.roundToDouble() ? 0 : 1)} | '
        '${v.observedMs.toStringAsFixed(1)} | ${v.verdict} |',
      );
    }
    return b.toString();
  }
}

// ------------------------------------------------- profile-build run helpers

/// The [PhysicalKeyboardKey] to pass with [key] to a simulated key event.
///
/// The test binding looks a simulated key's physical key up by comparing
/// `debugName`s, and `debugName` is null outside debug builds: in a profile
/// build the lookup finds nothing and the simulation throws "Null check
/// operator used on a null value" (the first profile run: every Select All
/// and the paste). A key sent with the physical key this returns skips the
/// lookup. Throws for a key the benchmark does not send.
PhysicalKeyboardKey benchmarkPhysicalKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.metaLeft) return PhysicalKeyboardKey.metaLeft;
  if (key == LogicalKeyboardKey.keyA) return PhysicalKeyboardKey.keyA;
  if (key == LogicalKeyboardKey.keyV) return PhysicalKeyboardKey.keyV;
  throw ArgumentError.value(key.keyId, 'key', 'no physical key for this key');
}

/// Polls [isMet] until it holds, at most [attempts] times: each time it does
/// not, [nudge] (an explicit request, such as a focus request) runs, then
/// [pause] (real time passing). Returns whether [isMet] holds at the end.
/// Bounded, and it never waits when [isMet] already holds.
Future<bool> awaitCondition({
  required bool Function() isMet,
  required Future<void> Function() pause,
  Future<void> Function()? nudge,
  int attempts = 60,
}) async {
  for (var i = 0; i < attempts; i++) {
    if (isMet()) return true;
    if (nudge != null) await nudge();
    if (isMet()) return true;
    await pause();
  }
  return isMet();
}

/// [text] with every machine-specific path made repo-relative: a file URI or
/// absolute path under the app package becomes `app/<dir>/...`, any other
/// path under a home directory keeps only its last segment (`.../name.dart`),
/// and a bare home directory becomes `~`.
String repoRelative(String text) {
  var out = text.replaceAllMapped(
    RegExp(
      r'(?:file://)?/[^\s():]*?/app/((?:lib|test|integration_test|test_driver)/)',
    ),
    (m) => 'app/${m[1]}',
  );
  out = out.replaceAllMapped(
    RegExp(r'(?:file://)?/(?:Users|home)/[^\s():]*/([^\s():/]+)'),
    (m) => '.../${m[1]}',
  );
  return out.replaceAll(RegExp(r'/(?:Users|home)/[^/\s():]+'), '~');
}

/// The first [count] frames of [stack], as `at <frame>` strings: no index, no
/// async-gap marker, paths repo-relative ([repoRelative]).
List<String> topFrames(StackTrace stack, {int count = 3}) {
  final out = <String>[];
  for (final line in stack.toString().split('\n')) {
    final frame = line.trim().replaceFirst(RegExp(r'^#\d+\s+'), '');
    if (frame.isEmpty || frame.startsWith('<asynchronous')) continue;
    out.add('at ${repoRelative(frame)}');
    if (out.length == count) break;
  }
  return out;
}

/// What the report keeps of a phase that threw: the case id, the phase and
/// the first line of the error, then the top [frames] stack frames, one per
/// line, so the next run shows where the throw came from.
String failureRecord(
  String id,
  String phase,
  Object error,
  StackTrace stack, {
  int frames = 3,
}) {
  final first = repoRelative(error.toString().split('\n').first);
  return [
    '$id $phase: $first',
    for (final f in topFrames(stack, count: frames)) '    $f',
  ].join('\n');
}
