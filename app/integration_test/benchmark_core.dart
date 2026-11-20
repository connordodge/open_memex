// WI #133 (Spec #122 Requirements 3-11, 37): the pure core of the profile-mode
// long-note benchmark (`long_note_benchmark_test.dart`): which cases it runs,
// how samples are summarised, which Requirement judges each metric, and what
// it reports. It imports no `integration_test` package, so the gate's
// `test/perf/long_note_benchmark_core_test.dart` runs it as plain Dart.
//
// SKELETON (red mode): signatures and neutral stubs only. The implementer
// fills every body; the tests in `test/perf/long_note_benchmark_core_test.dart`
// are the contract.
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
}

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
  Map<String, Object> toJson() => const {};
}

/// Summarises [samples] (any order): the count, the median (the mean of the
/// two middle samples for an even count), the p90 (nearest rank: the sample
/// at 1-based rank `ceil(0.9 * count)` of the sorted samples) and the max.
/// No samples give a count of 0 and 0.0 for the rest.
MsStats summarize(Iterable<double> samples) =>
    const MsStats(count: 0, median: 0, p90: 0, max: 0);

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
  String get id => '';
}

/// The matrix: kinds in the order N1, N2, N5, N3, N4; within a kind the
/// variants plain, misspelled, misspelled-heavy (N1, N2, N5 only), decorated;
/// within a variant Outline open then closed; within that spelling on then
/// off.
List<BenchCase> benchmarkMatrix() => const [];

/// The cases of [all] whose id starts with one of the comma-separated terms
/// of [filter] (surrounding spaces ignored), in [all]'s order and each once.
/// An empty or blank [filter] selects all of [all]. A term that matches no
/// case throws an [ArgumentError] naming it.
List<BenchCase> selectCases(List<BenchCase> all, String filter) => const [];

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
  String get id => '';
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
}

/// Every Requirement's target (Spec #122 Requirements 3-11).
const List<BenchTarget> benchTargets = [];

/// The target that judges [metric] of the case or scenario [caseId], or null
/// when none does.
BenchTarget? targetFor(String caseId, String metric) => null;

/// `PASS` when [stats].max meets [target]'s limit (`<=`, or `<` when
/// strict), `MISS` when it does not, and `INCOMPLETE` (judged first) when
/// [stats].count is below the target's minSamples.
String judge(BenchTarget target, MsStats stats) => '';

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
  Map<String, Object> toJson() => const {};
}

/// What a benchmark run collects and reports.
class BenchReport {
  /// Summarises [samples] and stores them under [caseId] and [metric]; a
  /// second record of the same pair replaces the first.
  void record(String caseId, String metric, Iterable<double> samples) {}

  /// The stored summary, or null when nothing was recorded.
  MsStats? stats(String caseId, String metric) => null;

  /// One row per recorded pair that a target judges, in the order first
  /// recorded.
  List<VerdictRow> verdicts() => const [];

  /// A map with `cases` (case id, then metric, then the stats JSON),
  /// `verdicts` (each row's JSON) and `markdown` (the [toMarkdown] text),
  /// JSON-encodable, for `binding.reportData`.
  Map<String, Object> toData() => const {};

  /// A Markdown table, one line per verdict: the header
  /// `| Requirement | Case | Metric | Limit (ms) | Max (ms) | Verdict |`, the
  /// separator `| --- | --- | --- | --- | --- | --- |`, then one line per
  /// verdict row with the limit in whole milliseconds and the max with one
  /// decimal, for example `| 8 | n1-plain-outline-closed-spell-on |
  /// find-bar-keystroke | 50 | 62.5 | MISS |` (on one line).
  String toMarkdown() => '';
}
