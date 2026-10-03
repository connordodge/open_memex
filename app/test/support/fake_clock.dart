import 'dart:async';

import 'package:open_memex_app/src/state/clock.dart';

/// Manual time for tests (D14). Override `clockProvider` with it; nothing runs
/// until [advance] moves time forward, and no real timer is ever created.
class FakeClock implements AppClock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime(2026, 10, 3, 9);

  DateTime _now;
  int _seq = 0;
  final List<_FakeTimer> _timers = [];

  @override
  DateTime now() => _now;

  @override
  Timer after(Duration delay, void Function() callback) {
    final t = _FakeTimer(
      this,
      due: _now.add(_nonNegative(delay)),
      seq: _seq++,
      interval: null,
      onFire: (_) => callback(),
    );
    _timers.add(t);
    return t;
  }

  @override
  Timer periodic(Duration interval, void Function(Timer timer) callback) {
    final step = _nonNegative(interval);
    late final _FakeTimer t;
    t = _FakeTimer(
      this,
      due: _now.add(step),
      seq: _seq++,
      interval: step,
      onFire: (_) => callback(t),
    );
    _timers.add(t);
    return t;
  }

  /// Active (not yet fired or cancelled) timers.
  int get pendingTimers => _timers.where((t) => t.isActive).length;

  /// Move time forward by [by], firing every timer that falls due on the way
  /// in due-time order (registration order breaks ties). `now()` inside a
  /// callback is that timer's due time; afterwards it is the start + [by].
  void advance(Duration by) {
    final target = _now.add(by);
    while (true) {
      final due = _timers.where((t) => t.isActive && !t.due.isAfter(target));
      if (due.isEmpty) break;
      final next = due.reduce((a, b) {
        final c = a.due.compareTo(b.due);
        if (c != 0) return c < 0 ? a : b;
        return a.seq <= b.seq ? a : b;
      });
      _now = next.due;
      next._fire();
    }
    _now = target;
  }

  /// Jump to [time] (must not be earlier than now), firing due timers.
  void advanceTo(DateTime time) => advance(time.difference(_now));

  static Duration _nonNegative(Duration d) => d.isNegative ? Duration.zero : d;
}

class _FakeTimer implements Timer {
  _FakeTimer(
    this._clock, {
    required this.due,
    required this.seq,
    required this.interval,
    required this.onFire,
  });

  final FakeClock _clock;
  DateTime due;
  int seq;
  final Duration? interval;
  final void Function(_FakeTimer) onFire;
  bool _active = true;
  int _tick = 0;

  void _fire() {
    _tick++;
    if (interval == null) {
      _active = false;
      _clock._timers.remove(this);
    } else {
      // A zero interval would loop forever; treat it as 1 microsecond.
      final step = interval == Duration.zero
          ? const Duration(microseconds: 1)
          : interval!;
      due = due.add(step);
      seq = _clock._seq++;
    }
    onFire(this);
  }

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}
