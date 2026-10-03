import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';

import '../support/fake_clock.dart';

/// Runs [body] in a zone that counts real timers created inside it.
int _realTimersCreatedBy(void Function() body) {
  var count = 0;
  runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, d, f) {
        count++;
        return parent.createTimer(zone, d, f);
      },
      createPeriodicTimer: (self, parent, zone, d, f) {
        count++;
        return parent.createPeriodicTimer(zone, d, f);
      },
    ),
  );
  return count;
}

void main() {
  group('FakeClock through clockProvider (AC11)', () {
    test(
      'FakeClock.advance fires after and periodic callbacks registered through clockProvider in time order',
      () {
        final start = DateTime(2026, 10, 3, 23, 59, 50);
        final fake = FakeClock(start);
        final container = ProviderContainer(
          overrides: [clockProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);
        final clock = container.read(clockProvider);
        final log = <String>[];
        String at() => clock.now().difference(start).inSeconds.toString();

        final realTimers = _realTimersCreatedBy(() {
          clock.after(const Duration(seconds: 10), () => log.add('A@${at()}'));
          clock.periodic(
            const Duration(seconds: 3),
            (t) => log.add('P${t.tick}@${at()}'),
          );
          clock.after(const Duration(seconds: 5), () => log.add('C@${at()}'));
          final cancelled = clock.after(
            const Duration(seconds: 1),
            () => log.add('X'),
          );
          cancelled.cancel();
          expect(cancelled.isActive, isFalse);

          expect(log, isEmpty, reason: 'nothing fires before advance');
          fake.advance(const Duration(seconds: 10));
        });

        expect(log, ['P1@3', 'C@5', 'P2@6', 'P3@9', 'A@10']);
        expect(clock.now(), DateTime(2026, 10, 4));
        expect(realTimers, 0, reason: 'no real timers run');
      },
    );

    test(
      'FakeClock now() reflects advance and stops a cancelled periodic timer',
      () {
        final fake = FakeClock(DateTime(2026, 10, 3, 9));
        final container = ProviderContainer(
          overrides: [clockProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);
        final clock = container.read(clockProvider);

        var ticks = 0;
        final poll = clock.periodic(const Duration(seconds: 2), (_) => ticks++);
        fake.advance(const Duration(seconds: 5));
        expect(ticks, 2);
        expect(clock.now(), DateTime(2026, 10, 3, 9, 0, 5));

        poll.cancel();
        fake.advance(const Duration(minutes: 1));
        expect(ticks, 2);
        expect(clock.now(), DateTime(2026, 10, 3, 9, 1, 5));
        expect(fake.pendingTimers, 0);
      },
    );
  });

  group('default clockProvider is the system clock', () {
    test('the default clockProvider now() is the wall clock', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final before = DateTime.now();
      final now = container.read(clockProvider).now();
      final after = DateTime.now();
      expect(now.isBefore(before), isFalse);
      expect(now.isAfter(after), isFalse);
      expect(now.isUtc, isFalse, reason: 'local time (Req 3)');
    });

    testWidgets(
      'the default clockProvider schedules real after and periodic timers',
      (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final clock = container.read(clockProvider);

        var fired = 0;
        var ticks = 0;
        clock.after(const Duration(seconds: 1), () => fired++);
        final p = clock.periodic(
          const Duration(milliseconds: 400),
          (_) => ticks++,
        );

        await tester.pump(const Duration(milliseconds: 999));
        expect(fired, 0);
        await tester.pump(const Duration(milliseconds: 1));
        expect(fired, 1);
        expect(ticks, 2);
        p.cancel();
        await tester.pump(const Duration(seconds: 2));
        expect(ticks, 2);
      },
    );
  });
}
