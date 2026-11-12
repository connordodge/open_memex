// WI #452 (390-A1): formatAgentAge (#390 req 22). Floor rounding: under 60 s,
// or negative, is `now`; then `<n>m`, `<n>h`, `<n>d`.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/agents/agent_age.dart';

final _now = DateTime(2026, 11, 11, 14, 30, 15, 250);
final _nowMs = _now.millisecondsSinceEpoch;

const _s = 1000;
const _m = 60 * _s;
const _h = 60 * _m;
const _d = 24 * _h;

void main() {
  for (final (name, ageMs, expected) in <(String, int, String)>[
    ('formatAgentAge gives now at 0 s', 0, 'now'),
    ('formatAgentAge gives now at 59 s', 59 * _s, 'now'),
    ('formatAgentAge gives now at 59.999 s', 60 * _s - 1, 'now'),
    ('formatAgentAge gives now at -5 s', -5 * _s, 'now'),
    ('formatAgentAge gives now for an hour in the future', -_h, 'now'),
    ('formatAgentAge gives 1m at 60 s', 60 * _s, '1m'),
    ('formatAgentAge gives 1m at 61 s', 61 * _s, '1m'),
    ('formatAgentAge gives 1m at 119 s', 119 * _s, '1m'),
    ('formatAgentAge gives 2m at 120 s', 120 * _s, '2m'),
    ('formatAgentAge gives 59m at 59 min', 59 * _m, '59m'),
    ('formatAgentAge gives 59m just under an hour', _h - 1, '59m'),
    ('formatAgentAge gives 1h at 1 h', _h, '1h'),
    ('formatAgentAge gives 1h at 1 h 59 min', 2 * _h - 1, '1h'),
    ('formatAgentAge gives 23h just under a day', _d - 1, '23h'),
    ('formatAgentAge gives 1d at 1 day', _d, '1d'),
    ('formatAgentAge gives 1d just under two days', 2 * _d - 1, '1d'),
    ('formatAgentAge gives 400d at 400 days', 400 * _d, '400d'),
  ]) {
    test(name, () {
      expect(formatAgentAge(_nowMs - ageMs, now: _now), expected);
    });
  }

  test('formatAgentAge depends only on the instant of now', () {
    final utc = _now.toUtc();
    for (final ageMs in [0, 61 * _s, 3 * _h, 2 * _d]) {
      expect(
        formatAgentAge(_nowMs - ageMs, now: utc),
        formatAgentAge(_nowMs - ageMs, now: _now),
        reason: '$ageMs',
      );
    }
    expect(formatAgentAge(_nowMs - 3 * _h, now: utc), '3h');
  });

  test('formatAgentAge counts elapsed time across a DST change', () {
    // 2026-11-01 is a DST end in North America; elapsed time is absolute.
    final now = DateTime.utc(2026, 11, 1, 12);
    final then = now.subtract(const Duration(hours: 25));
    expect(formatAgentAge(then.millisecondsSinceEpoch, now: now), '1d');
    expect(
      formatAgentAge(
        now.subtract(const Duration(hours: 23)).millisecondsSinceEpoch,
        now: now.toLocal(),
      ),
      '23h',
    );
  });
}
