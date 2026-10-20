// WI #77 (H0) D5/D10a/req 59: `formatUtcOffset` writes exactly the `format`
// rows of #74's `api_v1/server/utc_offsets.json` (consumed unchanged), and
// the `utcOffsetProvider` seam reads `clockProvider` on every call.
//
// API under test:
//   String formatUtcOffset(Duration offset)
//   final utcOffsetProvider = Provider<Duration Function()>(…)
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/utc_offset.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';

/// A `DateTime` whose only meaningful member is [timeZoneOffset], so a test
/// can pick any offset whatever the machine's time zone.
class _Wi77OffsetDateTime implements DateTime {
  _Wi77OffsetDateTime(this.timeZoneOffset);

  @override
  final Duration timeZoneOffset;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A clock whose `now()` is whatever the test last set.
class _Wi77SettableClock extends FakeClock {
  DateTime current = DateTime.utc(2026, 3, 29, 0, 30);

  @override
  DateTime now() => current;
}

void main() {
  test('formatUtcOffset writes every format row of the shared fixture', () {
    final cases = loadUtcOffsetCases();
    expect(cases.format, isNotEmpty);
    for (final MapEntry(key: minutes, value: header) in cases.format.entries) {
      expect(
        formatUtcOffset(Duration(minutes: minutes)),
        header,
        reason: '$minutes minutes',
      );
    }
  });

  test(
    'formatUtcOffset covers the minus zero hours, plus 14 and minus 12 edges',
    () {
      final format = loadUtcOffsetCases().format;
      expect(format[-30], '-00:30');
      expect(format[840], '+14:00');
      expect(format[-720], '-12:00');
      expect(format[0], '+00:00');
      expect(formatUtcOffset(const Duration(minutes: -30)), '-00:30');
      expect(formatUtcOffset(const Duration(hours: 14)), '+14:00');
      expect(formatUtcOffset(const Duration(hours: -12)), '-12:00');
      expect(formatUtcOffset(Duration.zero), '+00:00');
    },
  );

  test(
    'formatUtcOffset output is a valid row for every valid fixture header',
    () {
      final cases = loadUtcOffsetCases();
      for (final MapEntry(key: header, value: minutes) in cases.valid.entries) {
        expect(formatUtcOffset(Duration(minutes: minutes)), header);
      }
    },
  );

  test('formatUtcOffset builds from run-time offsets', () {
    // Not const: the Duration is computed, so the formatter sees run-time
    // values rather than compile-time constants.
    final now = DateTime.utc(2026, 10, 20, 12);
    final kathmandu = now.add(const Duration(hours: 5, minutes: 45));
    expect(formatUtcOffset(kathmandu.difference(now)), '+05:45');
    final newfoundland = now.subtract(const Duration(hours: 2, minutes: 30));
    expect(formatUtcOffset(newfoundland.difference(now)), '-02:30');
  });

  test('utcOffsetProvider reads the clock offset on every call', () {
    final clock = _Wi77SettableClock();
    final container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(clock)],
    );
    addTearDown(container.dispose);

    final offset = container.read(utcOffsetProvider);
    expect(offset(), Duration.zero, reason: 'a UTC clock');

    clock.current = _Wi77OffsetDateTime(const Duration(hours: 1));
    expect(offset(), const Duration(hours: 1));
    clock.current = _Wi77OffsetDateTime(const Duration(hours: 2));
    expect(offset(), const Duration(hours: 2), reason: 'a DST switch');
    clock.current = _Wi77OffsetDateTime(const Duration(minutes: -30));
    expect(formatUtcOffset(offset()), '-00:30');
  });

  test('utcOffsetProvider defaults to the local offset of clockProvider', () {
    final start = DateTime(2026, 7, 1, 9);
    final container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(FakeClock(start))],
    );
    addTearDown(container.dispose);
    expect(container.read(utcOffsetProvider)(), start.timeZoneOffset);
  });
}
