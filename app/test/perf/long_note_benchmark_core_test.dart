// WI #133 (Spec #122 Requirements 3-11, 37): the pure core of the
// profile-mode long-note benchmark (`integration_test/benchmark_core.dart`).
// The benchmark itself is a MANUAL run (a foreground window, `flutter drive
// --profile`); what it runs, how it summarises, which Requirement judges each
// metric and what it reports is plain Dart, and is pinned here.
//
// Everything is built from run-time values (no `const` instance), so the
// constructors run.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/benchmark_core.dart';
import '../support/long_note_fixtures.dart';

const _n1 = 'n1-plain-outline-open-spell-on';
const _n2 = 'n2-decorated-outline-closed-spell-off';
const _n3 = 'n3-plain-outline-open-spell-on';
const _n4 = 'n4-misspelled-outline-closed-spell-on';
const _n5 = 'n5-misspelled-heavy-outline-open-spell-on';

/// 1.0 .. [n].toDouble(), in a shuffled but fixed order.
List<double> _ramp(int n) {
  final out = [for (var i = 1; i <= n; i++) i.toDouble()];
  // A fixed shuffle: reverse the halves.
  return [...out.reversed.take(n ~/ 2), ...out.reversed.skip(n ~/ 2)];
}

BenchTarget _target({
  double limit = 16,
  bool strict = false,
  int minSamples = 1,
}) => BenchTarget(
  requirement: 'x',
  metrics: [BenchMetric.keystroke],
  covers: ['n1-'],
  limitMs: limit,
  strict: strict,
  minSamples: minSamples,
);

BenchTarget _targetOf(String caseId, String metric) {
  final t = targetFor(caseId, metric);
  if (t == null) {
    throw TestFailure('no target judges $metric of $caseId');
  }
  return t;
}

MsStats _statsOf(BenchReport r, String caseId, String metric) {
  final s = r.stats(caseId, metric);
  if (s == null) throw TestFailure('nothing recorded for $metric of $caseId');
  return s;
}

void main() {
  group('summarize', () {
    test('summarize of no samples is a zero count and zero stats', () {
      // Control: a sample is counted.
      expect(summarize([1.0]).count, 1);
      final s = summarize(<double>[]);
      expect(s.count, 0);
      expect(s.median, 0.0);
      expect(s.p90, 0.0);
      expect(s.max, 0.0);
    });

    test('summarize of one sample gives that sample for every stat', () {
      final s = summarize([7.5]);
      expect(s.count, 1);
      expect(s.median, 7.5);
      expect(s.p90, 7.5);
      expect(s.max, 7.5);
    });

    test('summarize median of an odd count is the middle sorted sample', () {
      expect(summarize([9.0, 1.0, 5.0]).median, 5.0);
      expect(summarize([30.0, 10.0, 50.0, 20.0, 40.0]).median, 30.0);
    });

    test('summarize median of an even count is the mean of the middle two', () {
      expect(summarize([4.0, 1.0, 3.0, 2.0]).median, 2.5);
      expect(summarize([10.0, 40.0]).median, 25.0);
    });

    test('summarize p90 is the nearest rank sample of the sorted samples', () {
      // rank = ceil(0.9 * n), 1-based.
      expect(summarize(_ramp(10)).p90, 9.0);
      expect(summarize(_ramp(11)).p90, 10.0);
      expect(summarize(_ramp(20)).p90, 18.0);
      expect(summarize(_ramp(100)).p90, 90.0);
      expect(summarize([3.0, 9.0]).p90, 9.0);
    });

    test('summarize max is the largest sample wherever it sits', () {
      expect(summarize([2.0, 80.5, 3.0, 1.0]).max, 80.5);
      expect(summarize([80.5, 2.0, 3.0]).max, 80.5);
      expect(summarize([2.0, 3.0, 80.5]).max, 80.5);
    });

    test(
      'summarize counts every sample and reads a lazy iterable of samples',
      () {
        final s = summarize(_ramp(25).map((v) => v * 2));
        expect(s.count, 25);
        expect(s.max, 50.0);
        expect(s.median, 26.0);
      },
    );

    test('summarize leaves its input list unsorted and unchanged', () {
      final input = List<double>.unmodifiable([5.0, 1.0, 3.0]);
      final s = summarize(input);
      expect(s.median, 3.0);
      expect(input, [5.0, 1.0, 3.0]);
    });

    test('MsStats toJson holds count median p90 and max', () {
      final stats = MsStats(
        count: int.parse('4'),
        median: double.parse('2.5'),
        p90: double.parse('4.0'),
        max: double.parse('4.5'),
      );
      expect(stats.toJson(), {
        'count': 4,
        'median': 2.5,
        'p90': 4.0,
        'max': 4.5,
      });
    });
  });

  group('matrix', () {
    test('benchmarkMatrix holds 72 distinct cases', () {
      final ids = [for (final c in benchmarkMatrix()) c.id];
      expect(ids, hasLength(72));
      expect(ids.toSet(), hasLength(72));
      expect(ids, everyElement(isNotEmpty));
    });

    test('benchmarkMatrix lists the kinds in the order N1 N2 N5 N3 N4', () {
      final order = <LongNoteKind>[];
      for (final c in benchmarkMatrix()) {
        if (order.isEmpty || order.last != c.kind) order.add(c.kind);
      }
      expect(order, [
        LongNoteKind.n1Plain120k,
        LongNoteKind.n2Bullets120k,
        LongNoteKind.n5PlainLongLines120k,
        LongNoteKind.n3Plain500k,
        LongNoteKind.n4Bullets500k,
      ]);
    });

    test('benchmarkMatrix starts with the N1 plain cells in a fixed order', () {
      final ids = [for (final c in benchmarkMatrix()) c.id];
      expect(ids.take(5).toList(), [
        'n1-plain-outline-open-spell-on',
        'n1-plain-outline-open-spell-off',
        'n1-plain-outline-closed-spell-on',
        'n1-plain-outline-closed-spell-off',
        'n1-misspelled-outline-open-spell-on',
      ]);
    });

    test(
      'benchmarkMatrix orders the variants plain misspelled heavy decorated',
      () {
        final n5 = [
          for (final c in benchmarkMatrix())
            if (c.kind == LongNoteKind.n5PlainLongLines120k) c.variant,
        ];
        final order = <LongNoteVariant>[];
        for (final v in n5) {
          if (order.isEmpty || order.last != v) order.add(v);
        }
        expect(order, [
          LongNoteVariant.plain,
          LongNoteVariant.misspelled,
          LongNoteVariant.misspelledHeavy,
          LongNoteVariant.decorated,
        ]);
      },
    );

    test('benchmarkMatrix runs misspelled-heavy on N1 N2 and N5 only', () {
      final heavy = {
        for (final c in benchmarkMatrix())
          if (c.variant == LongNoteVariant.misspelledHeavy) c.kind,
      };
      expect(heavy, {
        LongNoteKind.n1Plain120k,
        LongNoteKind.n2Bullets120k,
        LongNoteKind.n5PlainLongLines120k,
      });
    });

    test(
      'benchmarkMatrix covers every outline and spelling pair of each variant',
      () {
        final cases = benchmarkMatrix();
        final kinds = {for (final c in cases) c.kind};
        expect(kinds, hasLength(5));
        for (final kind in kinds) {
          final variants = {
            for (final c in cases)
              if (c.kind == kind) c.variant,
          };
          expect(
            variants.length,
            kind == LongNoteKind.n3Plain500k ||
                    kind == LongNoteKind.n4Bullets500k
                ? 3
                : 4,
            reason: '$kind variants',
          );
          for (final variant in variants) {
            final pairs = [
              for (final c in cases)
                if (c.kind == kind && c.variant == variant)
                  (c.outlineOpen, c.spellingOn),
            ];
            expect(
              pairs,
              unorderedEquals([
                (true, true),
                (true, false),
                (false, true),
                (false, false),
              ]),
              reason: '$kind $variant',
            );
          }
        }
      },
    );

    test(
      'benchmarkMatrix orders Outline open before closed and spelling on before off',
      () {
        final c = benchmarkMatrix().take(4).toList();
        expect(
          [for (final x in c) (x.outlineOpen, x.spellingOn)],
          [(true, true), (true, false), (false, true), (false, false)],
        );
      },
    );

    for (final row in [
      (
        'BenchCase id of N1 plain with Outline open and spelling on',
        LongNoteKind.n1Plain120k,
        LongNoteVariant.plain,
        true,
        true,
        'n1-plain-outline-open-spell-on',
      ),
      (
        'BenchCase id of N2 misspelled with Outline open and spelling off',
        LongNoteKind.n2Bullets120k,
        LongNoteVariant.misspelled,
        true,
        false,
        'n2-misspelled-outline-open-spell-off',
      ),
      (
        'BenchCase id of N3 decorated with Outline closed and spelling on',
        LongNoteKind.n3Plain500k,
        LongNoteVariant.decorated,
        false,
        true,
        'n3-decorated-outline-closed-spell-on',
      ),
      (
        'BenchCase id of N4 plain with Outline closed and spelling off',
        LongNoteKind.n4Bullets500k,
        LongNoteVariant.plain,
        false,
        false,
        'n4-plain-outline-closed-spell-off',
      ),
      (
        'BenchCase id of N5 misspelled-heavy with Outline open and spelling on',
        LongNoteKind.n5PlainLongLines120k,
        LongNoteVariant.misspelledHeavy,
        true,
        true,
        'n5-misspelled-heavy-outline-open-spell-on',
      ),
    ]) {
      test(row.$1, () {
        final c = BenchCase(
          kind: row.$2,
          variant: row.$3,
          outlineOpen: row.$4,
          spellingOn: row.$5,
        );
        expect(c.id, row.$6);
      });
    }

    test('selectCases with an empty or blank filter selects every case', () {
      final all = benchmarkMatrix();
      expect(all, isNotEmpty);
      expect(selectCases(all, ''), all);
      expect(selectCases(all, '   '), all);
    });

    test('selectCases matches ids by prefix', () {
      final all = benchmarkMatrix();
      expect(
        [for (final c in selectCases(all, 'n1-plain')) c.id],
        [
          'n1-plain-outline-open-spell-on',
          'n1-plain-outline-open-spell-off',
          'n1-plain-outline-closed-spell-on',
          'n1-plain-outline-closed-spell-off',
        ],
      );
      expect(selectCases(all, 'n1'), hasLength(16));
      expect(selectCases(all, 'n3-'), hasLength(12));
    });

    test('selectCases joins comma separated terms ignoring spaces', () {
      final all = benchmarkMatrix();
      final ids = [
        for (final c in selectCases(
          all,
          ' n5-decorated-outline-open ,n1-plain-outline-closed-spell-off',
        ))
          c.id,
      ];
      // In the matrix's order (N1 before N5), not the filter's.
      expect(ids, [
        'n1-plain-outline-closed-spell-off',
        'n5-decorated-outline-open-spell-on',
        'n5-decorated-outline-open-spell-off',
      ]);
    });

    test('selectCases returns a case once when two terms match it', () {
      final all = benchmarkMatrix();
      final ids = [
        for (final c in selectCases(all, 'n1-plain,n1-plain-outline-open'))
          c.id,
      ];
      expect(ids, hasLength(4));
      expect(ids.toSet(), hasLength(4));
    });

    test(
      'selectCases throws an ArgumentError naming a term that matches nothing',
      () {
        final all = benchmarkMatrix();
        expect(all, isNotEmpty);
        expect(
          () => selectCases(all, 'n1-plain,n9-nothing'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'message',
              contains('n9-nothing'),
            ),
          ),
        );
        expect(() => selectCases(all, 'zzz'), throwsArgumentError);
      },
    );

    for (final row in [
      (
        'ExtraScenario sourceModeN1 id is source-n1',
        ExtraScenario.sourceModeN1,
        'source-n1',
      ),
      (
        'ExtraScenario dailyN1CaptureGutter id is daily-n1-capture-gutter',
        ExtraScenario.dailyN1CaptureGutter,
        'daily-n1-capture-gutter',
      ),
      (
        'ExtraScenario pasteN1IntoEmptyNote id is paste-n1-empty-note',
        ExtraScenario.pasteN1IntoEmptyNote,
        'paste-n1-empty-note',
      ),
      (
        'ExtraScenario reloadN1AfterOutsideEdit id is reload-n1-outside-edit',
        ExtraScenario.reloadN1AfterOutsideEdit,
        'reload-n1-outside-edit',
      ),
    ]) {
      test(row.$1, () => expect(row.$2.id, row.$3));
    }
  });

  group('targets', () {
    // (test name, case id, metric, requirement, limit ms, strict, min samples)
    for (final row in <(String, String, String, String, double, bool, int)>[
      (
        'Requirement 3 judges fling build on N1 at 32 ms',
        _n1,
        BenchMetric.flingBuild,
        '3',
        32,
        false,
        1,
      ),
      (
        'Requirement 3 judges fling raster on N2 at 32 ms',
        _n2,
        BenchMetric.flingRaster,
        '3',
        32,
        false,
        1,
      ),
      (
        'Requirement 3 judges jump30 build on N5 at 32 ms',
        _n5,
        BenchMetric.jumpBuild,
        '3',
        32,
        false,
        1,
      ),
      (
        'Requirement 3 judges jump30 raster on N5 at 32 ms',
        _n5,
        BenchMetric.jumpRaster,
        '3',
        32,
        false,
        1,
      ),
      (
        'Requirement 4 judges keystroke on N1 at 16 ms',
        _n1,
        BenchMetric.keystroke,
        '4',
        16,
        false,
        1,
      ),
      (
        'Requirement 4 judges keystroke on N2 at 16 ms',
        _n2,
        BenchMetric.keystroke,
        '4',
        16,
        false,
        1,
      ),
      (
        'Requirement 5 judges open on N1 at 500 ms',
        _n1,
        BenchMetric.openFirstScreen,
        '5',
        500,
        false,
        1,
      ),
      (
        'Requirement 5 judges open on N2 at 500 ms',
        _n2,
        BenchMetric.openFirstScreen,
        '5',
        500,
        false,
        1,
      ),
      (
        'Requirement 6 judges fling build on N3 at 100 ms',
        _n3,
        BenchMetric.flingBuild,
        '6',
        100,
        false,
        1,
      ),
      (
        'Requirement 6 judges jump30 raster on N4 at 100 ms',
        _n4,
        BenchMetric.jumpRaster,
        '6',
        100,
        false,
        1,
      ),
      (
        'Requirement 6 judges keystroke on N3 at 100 ms',
        _n3,
        BenchMetric.keystroke,
        '6',
        100,
        false,
        1,
      ),
      (
        'Requirement 6 judges arrow on N4 at 100 ms',
        _n4,
        BenchMetric.arrow,
        '6',
        100,
        false,
        1,
      ),
      (
        'Requirement 6 judges open on N3 at 2000 ms',
        _n3,
        BenchMetric.openFirstScreen,
        '6',
        2000,
        false,
        1,
      ),
      (
        'Requirement 6 judges open on N4 at 2000 ms',
        _n4,
        BenchMetric.openFirstScreen,
        '6',
        2000,
        false,
        1,
      ),
      (
        'Requirement 6a judges resize build on N1 at 100 ms',
        _n1,
        BenchMetric.resizeBuild,
        '6a',
        100,
        false,
        1,
      ),
      (
        'Requirement 6a judges resize raster on N3 at 100 ms',
        _n3,
        BenchMetric.resizeRaster,
        '6a',
        100,
        false,
        1,
      ),
      (
        'Requirement 6b judges select all on N1 under 100 ms',
        _n1,
        BenchMetric.selectAll,
        '6b',
        100,
        true,
        1,
      ),
      (
        'Requirement 6b judges select all on N2 under 100 ms',
        _n2,
        BenchMetric.selectAll,
        '6b',
        100,
        true,
        1,
      ),
      (
        'Requirement 6b judges clearing the selection on N1 under 100 ms',
        _n1,
        BenchMetric.clearSelection,
        '6b',
        100,
        true,
        1,
      ),
      (
        'Requirement 6b judges select all on N3 at 1000 ms',
        _n3,
        BenchMetric.selectAll,
        '6b',
        1000,
        false,
        1,
      ),
      (
        'Requirement 6b judges clearing the selection on N4 at 1000 ms',
        _n4,
        BenchMetric.clearSelection,
        '6b',
        1000,
        false,
        1,
      ),
      (
        'Requirement 7 judges arrow on N1 at 16 ms',
        _n1,
        BenchMetric.arrow,
        '7',
        16,
        false,
        1,
      ),
      (
        'Requirement 7 judges shift selection on N2 at 16 ms',
        _n2,
        BenchMetric.shiftSelect,
        '7',
        16,
        false,
        1,
      ),
      (
        'Requirement 7 judges a pointer drag on N1 at 16 ms',
        _n1,
        BenchMetric.pointerDrag,
        '7',
        16,
        false,
        1,
      ),
      (
        'Requirement 8 judges the Find bar keystroke on N1 at 50 ms over 20 events',
        _n1,
        BenchMetric.findKeystroke,
        '8',
        50,
        false,
        20,
      ),
      (
        'Requirement 8 judges the Find bar keystroke on N2 at 50 ms over 20 events',
        _n2,
        BenchMetric.findKeystroke,
        '8',
        50,
        false,
        20,
      ),
      (
        'Requirement 8 judges next match on N1 at 50 ms over 20 events',
        _n1,
        BenchMetric.findNextMatch,
        '8',
        50,
        false,
        20,
      ),
      (
        'Requirement 8 judges next match on N2 at 50 ms over 20 events',
        _n2,
        BenchMetric.findNextMatch,
        '8',
        50,
        false,
        20,
      ),
      (
        'Requirement 9 judges the paste scenario open at 500 ms',
        'paste-n1-empty-note',
        BenchMetric.openFirstScreen,
        '9',
        500,
        false,
        1,
      ),
      (
        'Requirement 9 judges the reload scenario open at 500 ms',
        'reload-n1-outside-edit',
        BenchMetric.openFirstScreen,
        '9',
        500,
        false,
        1,
      ),
      (
        'Requirement 10 judges source mode fling build at 32 ms',
        'source-n1',
        BenchMetric.flingBuild,
        '10',
        32,
        false,
        1,
      ),
      (
        'Requirement 10 judges source mode jump30 raster at 32 ms',
        'source-n1',
        BenchMetric.jumpRaster,
        '10',
        32,
        false,
        1,
      ),
      (
        'Requirement 10 judges source mode open at 500 ms',
        'source-n1',
        BenchMetric.openFirstScreen,
        '10',
        500,
        false,
        1,
      ),
      (
        'Requirement 11 judges the daily note fling raster at 32 ms',
        'daily-n1-capture-gutter',
        BenchMetric.flingRaster,
        '11',
        32,
        false,
        1,
      ),
      (
        'Requirement 11 judges the daily note jump30 build at 32 ms',
        'daily-n1-capture-gutter',
        BenchMetric.jumpBuild,
        '11',
        32,
        false,
        1,
      ),
      (
        'Requirement 11 judges the daily note open at 500 ms',
        'daily-n1-capture-gutter',
        BenchMetric.openFirstScreen,
        '11',
        500,
        false,
        1,
      ),
    ]) {
      test(row.$1, () {
        final t = _targetOf(row.$2, row.$3);
        expect(t.requirement, row.$4);
        expect(t.limitMs, row.$5);
        expect(t.strict, row.$6);
        expect(t.minSamples, row.$7);
        expect(t.metrics, contains(row.$3));
      });
    }

    // (test name, case id, metric): no Requirement judges this pair.
    for (final row in <(String, String, String)>[
      ('no target judges resize on N2', _n2, BenchMetric.resizeBuild),
      ('no target judges resize on N4', _n4, BenchMetric.resizeRaster),
      ('no target judges resize on N5', _n5, BenchMetric.resizeBuild),
      (
        'no target judges the Find bar keystroke on N5',
        _n5,
        BenchMetric.findKeystroke,
      ),
      ('no target judges next match on N3', _n3, BenchMetric.findNextMatch),
      ('no target judges shift selection on N4', _n4, BenchMetric.shiftSelect),
      ('no target judges a pointer drag on N3', _n3, BenchMetric.pointerDrag),
      ('no target judges select all on N5', _n5, BenchMetric.selectAll),
      ('no target judges keystroke on N5', _n5, BenchMetric.keystroke),
      (
        'no target judges the paste scenario fling',
        'paste-n1-empty-note',
        BenchMetric.flingBuild,
      ),
      (
        'no target judges the daily note keystroke',
        'daily-n1-capture-gutter',
        BenchMetric.keystroke,
      ),
      (
        'no target judges source mode keystroke',
        'source-n1',
        BenchMetric.keystroke,
      ),
      ('no target judges a metric it does not know', _n1, 'bogus-metric'),
      (
        'no target judges a case it does not know',
        'x1-plain',
        BenchMetric.keystroke,
      ),
    ]) {
      test(row.$1, () {
        // Control: the table is filled at all.
        expect(targetFor(_n1, BenchMetric.keystroke), isNotNull);
        expect(targetFor(row.$2, row.$3), isNull);
      });
    }

    test('every target limits only metrics the benchmark names', () {
      expect(benchTargets, isNotEmpty);
      for (final t in benchTargets) {
        expect(t.metrics, isNotEmpty, reason: t.requirement);
        expect(t.covers, isNotEmpty, reason: t.requirement);
        for (final m in t.metrics) {
          expect(BenchMetric.all, contains(m), reason: t.requirement);
        }
      }
    });

    test('every Requirement from 3 to 11 has a target', () {
      final reqs = {for (final t in benchTargets) t.requirement};
      expect(
        reqs,
        containsAll([
          '3',
          '4',
          '5',
          '6',
          '6a',
          '6b',
          '7',
          '8',
          '9',
          '10',
          '11',
        ]),
      );
    });

    test('no case and metric pair is judged by two targets', () {
      final ids = <String>[
        for (final c in benchmarkMatrix()) c.id,
        for (final s in ExtraScenario.values) s.id,
      ];
      // 72 matrix cases and 4 scenarios, all named.
      expect(ids.toSet(), hasLength(76));
      for (final id in ids) {
        for (final m in BenchMetric.all) {
          final hits = benchTargets.where(
            (t) =>
                t.metrics.contains(m) && t.covers.any((p) => id.startsWith(p)),
          );
          expect(hits.length, lessThanOrEqualTo(1), reason: '$id $m');
          expect(targetFor(id, m), hits.isEmpty ? isNull : same(hits.single));
        }
      }
    });
  });

  group('judge', () {
    test('judge passes a max at the limit and misses one just above it', () {
      final t = _target(limit: 16);
      expect(judge(t, summarize([4.0, 16.0])), 'PASS');
      expect(judge(t, summarize([4.0, 16.001])), 'MISS');
      expect(judge(t, summarize([1.0, 2.0])), 'PASS');
    });

    test('judge of a strict target misses a max at the limit', () {
      final t = _target(limit: 100, strict: true);
      expect(judge(t, summarize([100.0])), 'MISS');
      expect(judge(t, summarize([99.99])), 'PASS');
      expect(judge(t, summarize([100.01])), 'MISS');
    });

    test('judge reads the max, not the median or the p90', () {
      final t = _target(limit: 16);
      final samples = [for (var i = 0; i < 99; i++) 2.0, 40.0];
      final s = summarize(samples);
      expect(s.median, lessThan(16));
      expect(s.p90, lessThan(16));
      expect(judge(t, s), 'MISS');
    });

    test('judge calls too few samples INCOMPLETE even when the max passes', () {
      final t = _target(limit: 50, minSamples: 20);
      expect(judge(t, summarize(List.filled(19, 3.0))), 'INCOMPLETE');
      expect(judge(t, summarize(List.filled(20, 3.0))), 'PASS');
    });

    test(
      'judge calls too few samples INCOMPLETE before it reads the limit',
      () {
        final t = _target(limit: 50, minSamples: 20);
        expect(judge(t, summarize(List.filled(19, 80.0))), 'INCOMPLETE');
        expect(judge(t, summarize(List.filled(20, 80.0))), 'MISS');
      },
    );

    test('judge calls no samples INCOMPLETE', () {
      expect(judge(_target(), summarize(<double>[])), 'INCOMPLETE');
    });

    test('judge applies the Find bar target to real counts', () {
      final t = _targetOf(_n1, BenchMetric.findKeystroke);
      expect(judge(t, summarize(List.filled(25, 49.0))), 'PASS');
      expect(judge(t, summarize([...List.filled(24, 10.0), 62.5])), 'MISS');
      expect(judge(t, summarize(List.filled(5, 10.0))), 'INCOMPLETE');
    });
  });

  group('report', () {
    BenchReport findReport() => BenchReport()
      ..record(_n1, BenchMetric.findKeystroke, [...List.filled(24, 12.0), 62.5])
      ..record(_n1, BenchMetric.findNextMatch, List.filled(20, 9.5))
      ..record(_n1, BenchMetric.keystroke, [10.0, 14.0, 20.26]);

    test('BenchReport stats returns what record summarised', () {
      final r = BenchReport()..record(_n1, BenchMetric.arrow, [3.0, 1.0, 2.0]);
      final s = _statsOf(r, _n1, BenchMetric.arrow);
      expect(s.count, 3);
      expect(s.median, 2.0);
      expect(s.max, 3.0);
    });

    test('BenchReport stats of a pair never recorded is null', () {
      final r = BenchReport()..record(_n1, BenchMetric.arrow, [1.0]);
      // Control: the recorded pair is there.
      expect(r.stats(_n1, BenchMetric.arrow), isNotNull);
      expect(r.stats(_n1, BenchMetric.keystroke), isNull);
      expect(r.stats(_n2, BenchMetric.arrow), isNull);
    });

    test('BenchReport record replaces an earlier record of the same pair', () {
      final r = BenchReport()
        ..record(_n1, BenchMetric.arrow, [90.0, 91.0])
        ..record(_n1, BenchMetric.arrow, [4.0]);
      final s = _statsOf(r, _n1, BenchMetric.arrow);
      expect(s.count, 1);
      expect(s.max, 4.0);
    });

    test(
      'BenchReport verdicts hold a row per judged pair with its limit and max',
      () {
        final rows = findReport().verdicts();
        expect(rows, hasLength(3));
        final find = rows.first;
        expect(find.requirement, '8');
        expect(find.caseId, _n1);
        expect(find.metric, BenchMetric.findKeystroke);
        expect(find.limitMs, 50.0);
        expect(find.observedMs, 62.5);
        expect(find.verdict, 'MISS');
        expect(rows[1].metric, BenchMetric.findNextMatch);
        expect(rows[1].observedMs, 9.5);
        expect(rows[1].verdict, 'PASS');
        expect(rows[2].requirement, '4');
        expect(rows[2].limitMs, 16.0);
        expect(rows[2].observedMs, 20.26);
        expect(rows[2].verdict, 'MISS');
      },
    );

    test('BenchReport verdicts skip a recorded pair no target judges', () {
      final r = BenchReport()
        ..record(_n5, BenchMetric.findKeystroke, List.filled(20, 99.0))
        ..record(_n1, BenchMetric.keystroke, [3.0]);
      final rows = r.verdicts();
      expect(rows, hasLength(1));
      expect(rows.single.caseId, _n1);
    });

    test(
      'BenchReport verdicts keep the order the pairs were first recorded',
      () {
        final r = BenchReport()
          ..record(_n2, BenchMetric.keystroke, [3.0])
          ..record(_n1, BenchMetric.keystroke, [3.0])
          ..record(_n2, BenchMetric.keystroke, [5.0]);
        final rows = r.verdicts();
        expect([for (final v in rows) v.caseId], [_n2, _n1]);
        expect(rows.first.observedMs, 5.0);
      },
    );

    test(
      'BenchReport verdicts call a Find run with too few events INCOMPLETE',
      () {
        final r = BenchReport()
          ..record(_n1, BenchMetric.findNextMatch, List.filled(3, 1.0));
        final rows = r.verdicts();
        expect(rows, hasLength(1));
        expect(rows.first.verdict, 'INCOMPLETE');
      },
    );

    test('VerdictRow toJson names its six fields', () {
      final row = VerdictRow(
        requirement: '6a',
        caseId: _n3,
        metric: BenchMetric.resizeBuild,
        limitMs: double.parse('100'),
        observedMs: double.parse('87.25'),
        verdict: 'PASS',
      );
      expect(row.toJson(), {
        'requirement': '6a',
        'case': _n3,
        'metric': BenchMetric.resizeBuild,
        'limitMs': 100.0,
        'observedMs': 87.25,
        'verdict': 'PASS',
      });
    });

    test(
      'BenchReport toData survives a JSON round trip with cases verdicts and markdown',
      () {
        final r = findReport();
        final data = jsonDecode(jsonEncode(r.toData())) as Map<String, dynamic>;
        expect(data.keys, unorderedEquals(['cases', 'verdicts', 'markdown']));
        final cases = data['cases'] as Map<String, dynamic>;
        expect(cases.keys, [_n1]);
        final metrics = cases[_n1] as Map<String, dynamic>;
        expect(metrics.keys, [
          BenchMetric.findKeystroke,
          BenchMetric.findNextMatch,
          BenchMetric.keystroke,
        ]);
        expect(metrics[BenchMetric.findKeystroke], {
          'count': 25,
          'median': 12.0,
          'p90': 12.0,
          'max': 62.5,
        });
        final verdicts = data['verdicts'] as List<dynamic>;
        expect(verdicts, hasLength(3));
        expect((verdicts.first as Map<String, dynamic>)['verdict'], 'MISS');
        expect(data['markdown'], r.toMarkdown());
      },
    );

    test(
      'BenchReport toData of an empty report has empty cases and verdicts',
      () {
        final data = BenchReport().toData();
        expect(data['cases'], isEmpty);
        expect(data['verdicts'], isEmpty);
      },
    );

    test(
      'BenchReport toData keeps a recorded pair no target judges under cases',
      () {
        final r = BenchReport()..record(_n5, BenchMetric.findKeystroke, [1.0]);
        final cases = r.toData()['cases'] as Map<Object?, Object?>?;
        expect(cases, isNotNull);
        expect(cases!.keys, [_n5]);
        expect(r.toData()['verdicts'], isEmpty);
      },
    );

    test(
      'BenchReport toMarkdown writes the header a separator and one line per verdict',
      () {
        final lines = findReport().toMarkdown().trimRight().split('\n');
        expect(lines, [
          '| Requirement | Case | Metric | Limit (ms) | Max (ms) | Verdict |',
          '| --- | --- | --- | --- | --- | --- |',
          '| 8 | $_n1 | find-bar-keystroke | 50 | 62.5 | MISS |',
          '| 8 | $_n1 | find-next-match | 50 | 9.5 | PASS |',
          '| 4 | $_n1 | keystroke | 16 | 20.3 | MISS |',
        ]);
      },
    );

    test(
      'BenchReport toMarkdown of an empty report is only the header and separator',
      () {
        final lines = BenchReport().toMarkdown().trimRight().split('\n');
        expect(lines, [
          '| Requirement | Case | Metric | Limit (ms) | Max (ms) | Verdict |',
          '| --- | --- | --- | --- | --- | --- |',
        ]);
      },
    );

    test(
      'BenchReport toMarkdown prints a whole millisecond max with one decimal',
      () {
        final r = BenchReport()
          ..record(_n1, BenchMetric.openFirstScreen, [212.0]);
        expect(
          r.toMarkdown(),
          contains('| 5 | $_n1 | open-first-screen | 500 | 212.0 | PASS |'),
        );
      },
    );
  });
}
