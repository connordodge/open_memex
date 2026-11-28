// WI #133 (Spec #122 Requirements 3, 8, 10, 11): the verdict rows of the
// profile-mode benchmark that the first round of the core tests left open:
//
// - the 60 fps half of "holds 60 fps" (a p90 limit on the scroll targets and
//   the `<metric> (p90)` rows it adds);
// - a (case, metric) a Requirement judges that a phase never recorded reads
//   INCOMPLETE (`BenchReport.expectCase`), instead of vanishing from the table;
// - the scroll with the caret in the note (`caretCaseId`) is judged like its
//   case;
// - every target is reachable: some case or scenario the benchmark declares is
//   judged by it.
//
// Everything is built from run-time values, so the constructors run.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/benchmark_core.dart';

const _n1 = 'n1-plain-outline-open-spell-on';
const _n2 = 'n2-plain-outline-closed-spell-off';
const _n3 = 'n3-plain-outline-open-spell-on';
const _n5 = 'n5-plain-outline-open-spell-on';
const _source = 'source-n1';
const _daily = 'daily-n1-capture-gutter';
const _paste = 'paste-n1-empty-note';

/// [count] samples of [ms], then one of [last] (a long tail frame).
List<double> _tail(int count, double ms, double last) => [
  for (var i = 0; i < count; i++) ms,
  last,
];

List<VerdictRow> _rows(BenchReport r, String caseId) => [
  for (final v in r.verdicts())
    if (v.caseId == caseId) v,
];

VerdictRow _row(BenchReport r, String caseId, String metric) =>
    r.verdicts().singleWhere((v) => v.caseId == caseId && v.metric == metric);

void main() {
  group('sixty fps', () {
    test('the 60 fps frame budget is 16.7 ms', () {
      expect(sixtyFpsFrameMs, closeTo(16.7, 1e-9));
    });

    for (final (name, id, metric, req) in [
      (
        'Requirement 3 holds 60 fps: N1 fling build has a p90 limit of 16.7',
        _n1,
        BenchMetric.flingBuild,
        '3',
      ),
      (
        'Requirement 3 holds 60 fps: N1 fling raster has a p90 limit of 16.7',
        _n1,
        BenchMetric.flingRaster,
        '3',
      ),
      (
        'Requirement 3 holds 60 fps: N2 jump30 build has a p90 limit of 16.7',
        _n2,
        BenchMetric.jumpBuild,
        '3',
      ),
      (
        'Requirement 3 holds 60 fps: N5 jump30 raster has a p90 limit of 16.7',
        _n5,
        BenchMetric.jumpRaster,
        '3',
      ),
      (
        'Requirement 10 holds 60 fps: source mode fling build has a p90 limit of 16.7',
        _source,
        BenchMetric.flingBuild,
        '10',
      ),
      (
        'Requirement 11 holds 60 fps: daily note jump30 raster has a p90 limit of 16.7',
        _daily,
        BenchMetric.jumpRaster,
        '11',
      ),
    ]) {
      test(name, () {
        final t = targetFor(id, metric)!;
        expect(t.requirement, req);
        expect(t.p90LimitMs, isNotNull);
        expect(t.p90LimitMs, closeTo(16.7, 1e-9));
        // The max limit stays the 32 ms of "no frame over 32 ms".
        expect(t.limitMs, 32);
      });
    }

    for (final (name, id, metric) in [
      ('Requirement 4 keystroke has no p90 limit', _n1, BenchMetric.keystroke),
      ('Requirement 5 open has no p90 limit', _n1, BenchMetric.openFirstScreen),
      (
        'Requirement 6 fling on N3 has no p90 limit',
        _n3,
        BenchMetric.flingBuild,
      ),
      ('Requirement 6a resize has no p90 limit', _n1, BenchMetric.resizeBuild),
      (
        'Requirement 6b select all has no p90 limit',
        _n1,
        BenchMetric.selectAll,
      ),
      ('Requirement 7 arrow has no p90 limit', _n1, BenchMetric.arrow),
      (
        'Requirement 8 find keystroke has no p90 limit',
        _n1,
        BenchMetric.findKeystroke,
      ),
      (
        'Requirement 9 paste open has no p90 limit',
        _paste,
        BenchMetric.openFirstScreen,
      ),
      (
        'Requirement 10 source open has no p90 limit',
        _source,
        BenchMetric.openFirstScreen,
      ),
    ]) {
      test(name, () {
        expect(targetFor(id, metric)!.p90LimitMs, isNull);
      });
    }

    test('judgeP90 passes a p90 at the 16.7 ms limit', () {
      final t = targetFor(_n1, BenchMetric.flingBuild)!;
      final s = summarize([for (var i = 0; i < 10; i++) 16.7]);
      expect(judgeP90(t, s), 'PASS');
    });

    test('judgeP90 misses a p90 just over the 16.7 ms limit', () {
      final t = targetFor(_n1, BenchMetric.flingBuild)!;
      final s = summarize([for (var i = 0; i < 10; i++) 16.71]);
      expect(judgeP90(t, s), 'MISS');
    });

    test('judgeP90 reads the p90, not the max', () {
      final t = targetFor(_n1, BenchMetric.flingBuild)!;
      // 21 samples: the nearest-rank p90 is the 19th, so the one 30 ms tail
      // frame (under the 32 ms max limit) does not decide it.
      final s = summarize(_tail(20, 10, 30));
      expect(s.p90, 10);
      expect(s.max, 30);
      expect(judgeP90(t, s), 'PASS');
      expect(judge(t, s), 'PASS');
    });

    test(
      'judgeP90 misses when most frames are over 16.7 ms though none is over 32',
      () {
        final t = targetFor(_n1, BenchMetric.flingBuild)!;
        final s = summarize([for (var i = 0; i < 20; i++) 25.0]);
        expect(judge(t, s), 'PASS');
        expect(judgeP90(t, s), 'MISS');
      },
    );

    test('judgeP90 of no samples is INCOMPLETE', () {
      final t = targetFor(_n1, BenchMetric.flingBuild)!;
      expect(judgeP90(t, summarize(const <double>[])), 'INCOMPLETE');
    });

    test('judgeP90 of too few samples for the target is INCOMPLETE', () {
      final t = BenchTarget(
        requirement: 'x',
        metrics: [BenchMetric.flingBuild],
        covers: ['n1-'],
        limitMs: 32,
        minSamples: 5,
        p90LimitMs: 16.7,
      );
      expect(judgeP90(t, summarize([1.0, 2.0, 3.0, 4.0])), 'INCOMPLETE');
      expect(judgeP90(t, summarize([1.0, 2.0, 3.0, 4.0, 5.0])), 'PASS');
    });

    test('judgeP90 of a target without a p90 limit is PASS', () {
      final t = targetFor(_n1, BenchMetric.keystroke)!;
      expect(judgeP90(t, summarize([999.0])), 'PASS');
    });

    test(
      'BenchReport verdicts add a p90 row right after the max row of a scroll metric',
      () {
        final r = BenchReport()
          ..record(_n1, BenchMetric.flingBuild, _tail(20, 10, 30))
          ..record(_n1, BenchMetric.keystroke, [8.0]);
        final rows = r.verdicts();
        expect(rows.map((v) => v.metric), [
          BenchMetric.flingBuild,
          '${BenchMetric.flingBuild} (p90)',
          BenchMetric.keystroke,
        ]);
        final max = rows[0];
        expect(max.requirement, '3');
        expect(max.limitMs, 32);
        expect(max.observedMs, 30);
        expect(max.verdict, 'PASS');
        final p90 = rows[1];
        expect(p90.requirement, '3');
        expect(p90.caseId, _n1);
        expect(p90.limitMs, closeTo(16.7, 1e-9));
        expect(p90.observedMs, 10);
        expect(p90.verdict, 'PASS');
      },
    );

    test('BenchReport verdicts MISS the p90 row while the max row passes', () {
      final r = BenchReport()
        ..record(_n1, BenchMetric.jumpRaster, [
          for (var i = 0; i < 20; i++) 20.0,
        ]);
      expect(_row(r, _n1, BenchMetric.jumpRaster).verdict, 'PASS');
      final p90 = _row(r, _n1, '${BenchMetric.jumpRaster} (p90)');
      expect(p90.verdict, 'MISS');
      expect(p90.observedMs, 20);
    });

    test('BenchReport verdicts MISS the max row while the p90 row passes', () {
      final r = BenchReport()
        ..record(_n1, BenchMetric.flingBuild, _tail(20, 10, 40));
      expect(_row(r, _n1, BenchMetric.flingBuild).verdict, 'MISS');
      expect(_row(r, _n1, '${BenchMetric.flingBuild} (p90)').verdict, 'PASS');
    });

    test('BenchReport verdicts give a metric without a p90 limit one row', () {
      final r = BenchReport()
        ..record(_n1, BenchMetric.keystroke, [4.0])
        ..record(_n3, BenchMetric.flingBuild, [90.0]);
      expect(r.verdicts().map((v) => v.metric), [
        BenchMetric.keystroke,
        BenchMetric.flingBuild,
      ]);
    });

    test(
      'BenchReport toMarkdown prints the 60 fps limit with one decimal and others whole',
      () {
        final r = BenchReport()
          ..record(_n1, BenchMetric.flingBuild, [12.0, 14.0])
          ..record(_n1, BenchMetric.keystroke, [4.0]);
        final lines = r.toMarkdown().trimRight().split('\n');
        expect(
          lines,
          contains('| 3 | $_n1 | fling-build | 32 | 14.0 | PASS |'),
        );
        expect(
          lines,
          contains('| 3 | $_n1 | fling-build (p90) | 16.7 | 14.0 | PASS |'),
        );
        expect(lines, contains('| 4 | $_n1 | keystroke | 16 | 4.0 | PASS |'));
      },
    );
  });

  group('expected rows', () {
    test(
      'BenchReport expectCase with nothing recorded gives INCOMPLETE rows',
      () {
        final r = BenchReport()
          ..expectCase(
            _n3,
            metrics: [BenchMetric.keystroke, BenchMetric.arrow],
          );
        final rows = r.verdicts();
        expect(rows.map((v) => (v.caseId, v.metric, v.verdict)), [
          (_n3, BenchMetric.keystroke, 'INCOMPLETE'),
          (_n3, BenchMetric.arrow, 'INCOMPLETE'),
        ]);
        expect(rows.first.requirement, '6');
        expect(rows.first.limitMs, 100);
        expect(rows.first.observedMs, 0);
      },
    );

    test(
      'BenchReport expectCase gives a scroll metric an INCOMPLETE max row and p90 row',
      () {
        final r = BenchReport()
          ..expectCase(_n1, metrics: [BenchMetric.flingBuild]);
        final rows = r.verdicts();
        expect(rows.map((v) => (v.metric, v.verdict)), [
          (BenchMetric.flingBuild, 'INCOMPLETE'),
          ('${BenchMetric.flingBuild} (p90)', 'INCOMPLETE'),
        ]);
        expect(rows[1].limitMs, closeTo(16.7, 1e-9));
      },
    );

    test(
      'BenchReport expectCase by default expects every metric a target judges for the case',
      () {
        final r = BenchReport()..expectCase(_source);
        expect(r.verdicts().map((v) => v.metric), [
          for (final m in BenchMetric.scroll) ...[m, '$m (p90)'],
          BenchMetric.openFirstScreen,
        ]);
        expect(r.verdicts().every((v) => v.verdict == 'INCOMPLETE'), isTrue);
      },
    );

    test(
      'BenchReport expectCase leaves a recorded pair at its recorded verdict',
      () {
        final r = BenchReport()
          ..expectCase(_n1, metrics: [BenchMetric.keystroke, BenchMetric.arrow])
          ..record(_n1, BenchMetric.keystroke, [30.0]);
        final byMetric = {for (final v in r.verdicts()) v.metric: v};
        expect(byMetric, hasLength(2));
        expect(byMetric[BenchMetric.keystroke]!.verdict, 'MISS');
        expect(byMetric[BenchMetric.keystroke]!.observedMs, 30);
        expect(byMetric[BenchMetric.arrow]!.verdict, 'INCOMPLETE');
      },
    );

    test(
      'BenchReport expectCase placed after a record does not duplicate its row',
      () {
        final r = BenchReport()
          ..record(_n1, BenchMetric.keystroke, [3.0])
          ..expectCase(_n1, metrics: [BenchMetric.keystroke]);
        expect(r.verdicts(), hasLength(1));
        expect(r.verdicts().single.verdict, 'PASS');
      },
    );

    test('BenchReport expectCase twice gives one row per pair', () {
      final r = BenchReport()
        ..expectCase(_n1, metrics: [BenchMetric.keystroke])
        ..expectCase(_n1, metrics: [BenchMetric.keystroke]);
      expect(r.verdicts(), hasLength(1));
    });

    test('BenchReport expectCase ignores a pair no target judges', () {
      final r = BenchReport()
        ..expectCase(_n3, metrics: [BenchMetric.pointerDrag])
        ..expectCase(_n5, metrics: [BenchMetric.keystroke]);
      expect(r.verdicts(), isEmpty);
    });

    test(
      'BenchReport verdicts list recorded rows first and the never recorded ones after',
      () {
        final r = BenchReport()
          ..expectCase(_n1, metrics: [BenchMetric.keystroke, BenchMetric.arrow])
          ..record(_n1, BenchMetric.arrow, [2.0]);
        expect(r.verdicts().map((v) => (v.metric, v.verdict)), [
          (BenchMetric.arrow, 'PASS'),
          (BenchMetric.keystroke, 'INCOMPLETE'),
        ]);
      },
    );

    test(
      'BenchReport expectCase of a Find pair with 19 events is INCOMPLETE and with 20 is judged',
      () {
        final r = BenchReport()
          ..expectCase(_n1, metrics: [BenchMetric.findKeystroke])
          ..record(_n1, BenchMetric.findKeystroke, [
            for (var i = 0; i < 19; i++) 5.0,
          ]);
        expect(r.verdicts().single.verdict, 'INCOMPLETE');
        r.record(_n1, BenchMetric.findKeystroke, [
          for (var i = 0; i < 20; i++) 5.0,
        ]);
        expect(r.verdicts().single.verdict, 'PASS');
      },
    );

    test(
      'BenchReport the caret scroll is judged like its case and expected as scroll only',
      () {
        final caret = caretCaseId(_n1);
        expect(caret, '$_n1-caret');
        final r = BenchReport()
          ..expectCase(caret, metrics: BenchMetric.scroll)
          ..record(caret, BenchMetric.flingBuild, [
            for (var i = 0; i < 20; i++) 20.0,
          ]);
        final rows = _rows(r, caret);
        // Four scroll metrics, each with a max row and a p90 row.
        expect(rows, hasLength(8));
        expect(rows.every((v) => v.requirement == '3'), isTrue);
        expect(_row(r, caret, BenchMetric.flingBuild).verdict, 'PASS');
        expect(
          _row(r, caret, '${BenchMetric.flingBuild} (p90)').verdict,
          'MISS',
        );
        expect(_row(r, caret, BenchMetric.jumpRaster).verdict, 'INCOMPLETE');
      },
    );

    test(
      'BenchReport toData and toMarkdown carry an INCOMPLETE row for an unrecorded pair',
      () {
        final r = BenchReport()
          ..expectCase(_n1, metrics: [BenchMetric.keystroke]);
        final data = jsonDecode(jsonEncode(r.toData())) as Map<String, Object?>;
        final verdicts = data['verdicts'] as List;
        expect(verdicts, hasLength(1));
        expect((verdicts.single as Map)['verdict'], 'INCOMPLETE');
        expect(
          r.toMarkdown().trimRight().split('\n').last,
          '| 4 | $_n1 | keystroke | 16 | 0.0 | INCOMPLETE |',
        );
        // Nothing was recorded, so no stats exist for it.
        expect(r.stats(_n1, BenchMetric.keystroke), isNull);
        expect(data['cases'], isEmpty);
      },
    );
  });

  group('expected metrics', () {
    test('BenchMetric scroll is the four scroll metrics in order', () {
      expect(BenchMetric.scroll, [
        BenchMetric.flingBuild,
        BenchMetric.flingRaster,
        BenchMetric.jumpBuild,
        BenchMetric.jumpRaster,
      ]);
      expect(BenchMetric.all, containsAll(BenchMetric.scroll));
    });

    test('expectedMetrics of an N1 case is every metric', () {
      expect(expectedMetrics(_n1), BenchMetric.all);
    });

    test(
      'expectedMetrics of an N2 case is every metric but the resize pair',
      () {
        expect(expectedMetrics(_n2), [
          for (final m in BenchMetric.all)
            if (m != BenchMetric.resizeBuild && m != BenchMetric.resizeRaster)
              m,
        ]);
      },
    );

    test(
      'expectedMetrics of an N3 case is scroll open keystroke arrow resize and select all',
      () {
        expect(expectedMetrics(_n3), [
          ...BenchMetric.scroll,
          BenchMetric.openFirstScreen,
          BenchMetric.keystroke,
          BenchMetric.arrow,
          BenchMetric.resizeBuild,
          BenchMetric.resizeRaster,
          BenchMetric.selectAll,
          BenchMetric.clearSelection,
        ]);
      },
    );

    test('expectedMetrics of an N5 case is the scroll metrics only', () {
      expect(expectedMetrics(_n5), BenchMetric.scroll);
    });

    for (final (name, id, metrics) in [
      (
        'expectedMetrics of the source mode scenario is scroll and open',
        _source,
        [...BenchMetric.scroll, BenchMetric.openFirstScreen],
      ),
      (
        'expectedMetrics of the daily note scenario is scroll and open',
        _daily,
        [...BenchMetric.scroll, BenchMetric.openFirstScreen],
      ),
      (
        'expectedMetrics of the paste scenario is open',
        _paste,
        [BenchMetric.openFirstScreen],
      ),
      (
        'expectedMetrics of the reload scenario is open',
        'reload-n1-outside-edit',
        [BenchMetric.openFirstScreen],
      ),
      ('expectedMetrics of an unknown id is empty', 'no-such-case', <String>[]),
    ]) {
      test(name, () {
        expect(expectedMetrics(id), metrics);
      });
    }

    test(
      'every target is reachable by a case or scenario the benchmark declares',
      () {
        final ids = [
          for (final c in benchmarkMatrix()) c.id,
          for (final s in ExtraScenario.values) s.id,
        ];
        for (final t in benchTargets) {
          for (final cover in t.covers) {
            for (final m in t.metrics) {
              final reached = [
                for (final id in ids)
                  if (id.startsWith(cover) && targetFor(id, m) == t) id,
              ];
              expect(
                reached,
                isNotEmpty,
                reason:
                    'Requirement ${t.requirement} $cover $m is judged for no case',
              );
              // The declared metrics of that case include it, so the report
              // expects it.
              for (final id in reached) {
                expect(expectedMetrics(id), contains(m), reason: '$id $m');
              }
            }
          }
        }
      },
    );

    test(
      'every matrix case expects the scroll and every scenario a metric',
      () {
        for (final c in benchmarkMatrix()) {
          expect(
            expectedMetrics(c.id),
            containsAll(BenchMetric.scroll),
            reason: c.id,
          );
        }
        for (final s in ExtraScenario.values) {
          expect(expectedMetrics(s.id), isNotEmpty, reason: s.id);
        }
      },
    );
  });
}
