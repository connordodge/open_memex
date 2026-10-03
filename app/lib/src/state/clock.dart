import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Injected time source (D14). New logic reads the current time and schedules
/// timers through [clockProvider], never through `DateTime.now()` or `Timer`
/// directly, so tests can drive time with a fake.
abstract class AppClock {
  DateTime now();
  Timer periodic(Duration interval, void Function(Timer timer) callback);
  Timer after(Duration delay, void Function() callback);
}

/// The real clock: wall time and real timers.
class SystemClock implements AppClock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Timer periodic(Duration interval, void Function(Timer timer) callback) =>
      Timer.periodic(interval, callback);

  @override
  Timer after(Duration delay, void Function() callback) =>
      Timer(delay, callback);
}

/// The app's time source. Tests override it with a `FakeClock`.
final clockProvider = Provider<AppClock>((ref) => const SystemClock());
