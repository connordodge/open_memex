// WI #452 (390-A1): deriveAgentActivityView and AgentActivityView (#390 req
// 14a, 20; D1; lead ruling A1). Expired iff now >= localMs(expiresAt);
// working iff lastToolAt != null and now - localMs(lastToolAt) < 10000;
// localMs(t) = t - clockOffsetMs.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';

import '../support/agents_fakes.dart';

final _now = DateTime(2026, 11, 11, 9, 0, 0);
final _nowMs = _now.millisecondsSinceEpoch;

AgentActivity _activity(
  List<AgentPresence> agents, {
  List<AgentActivityEntry> recent = const [],
  bool available = true,
  int? serverNow,
}) => AgentActivity(
  agents: agents,
  recent: recent,
  available: available,
  serverNow: serverNow,
);

/// `(sessionId, working)` of each connected agent, in order.
List<(String, bool)> _connected(AgentActivityView v) => [
  for (final c in v.connected) (c.presence.sessionId, c.working),
];

AgentPresence _p(
  String id, {
  int? lastRequestAt,
  int? lastToolAt,
  int? expiresAt,
}) => agentPresence(
  sessionId: id,
  lastRequestAt: lastRequestAt ?? _nowMs,
  lastSeenAt: _nowMs,
  lastToolAt: lastToolAt,
  expiresAt: expiresAt ?? _nowMs + 15000,
);

void main() {
  group('expiry', () {
    test(
      'deriveAgentActivityView leaves out a record at now == expiresAt and keeps it at expiresAt - 1 ms',
      () {
        final v = deriveAgentActivityView(
          _activity([
            _p('at-expiry', expiresAt: _nowMs),
            _p('one-ms-left', expiresAt: _nowMs + 1),
          ]),
          now: _now,
          clockOffsetMs: 0,
        );
        expect(_connected(v), [('one-ms-left', false)]);
      },
    );

    test(
      'deriveAgentActivityView leaves out a record that expired long ago',
      () {
        final v = deriveAgentActivityView(
          _activity([
            _p('gone', expiresAt: _nowMs - 60000, lastRequestAt: _nowMs + 5),
            _p('live'),
          ]),
          now: _now,
          clockOffsetMs: 0,
        );
        expect(_connected(v), [('live', false)]);
      },
    );

    test(
      'deriveAgentActivityView with every record expired has none connected',
      () {
        final v = deriveAgentActivityView(
          _activity(
            [_p('a', expiresAt: _nowMs), _p('b', expiresAt: _nowMs - 1)],
            recent: [agentEntry()],
          ),
          now: _now,
          clockOffsetMs: 0,
        );
        expect(v.connected, isEmpty);
        expect(v.recent, hasLength(1));
        expect(v.available, isTrue);
      },
    );

    test('deriveAgentActivityView keeps the presence record it was given', () {
      final kept = _p('kept');
      final v = deriveAgentActivityView(
        _activity([kept]),
        now: _now,
        clockOffsetMs: 0,
      );
      expect(v.connected, hasLength(1));
      expect(v.connected.single.presence, same(kept));
    });
  });

  test('connected is sorted by lastRequestAt descending', () {
    final v = deriveAgentActivityView(
      _activity([
        _p('middle', lastRequestAt: _nowMs - 2000),
        _p('oldest', lastRequestAt: _nowMs - 9000),
        _p('newest', lastRequestAt: _nowMs - 100),
        _p('expired-newest', lastRequestAt: _nowMs, expiresAt: _nowMs),
      ]),
      now: _now,
      clockOffsetMs: 0,
    );
    expect(
      [for (final c in v.connected) c.presence.sessionId],
      ['newest', 'middle', 'oldest'],
    );
  });

  group('working', () {
    test(
      'an agent is working at lastToolAt 9999 ms ago and not at 10000 ms',
      () {
        final v = deriveAgentActivityView(
          _activity([
            _p('busy', lastRequestAt: _nowMs - 1, lastToolAt: _nowMs - 9999),
            _p('idle', lastRequestAt: _nowMs - 2, lastToolAt: _nowMs - 10000),
          ]),
          now: _now,
          clockOffsetMs: 0,
        );
        expect(_connected(v), [('busy', true), ('idle', false)]);
      },
    );

    test(
      'an agent with a null lastToolAt is not working even with lastRequestAt 1 s ago',
      () {
        final v = deriveAgentActivityView(
          _activity([_p('pinging', lastRequestAt: _nowMs - 1000)]),
          now: _now,
          clockOffsetMs: 0,
        );
        expect(_connected(v), [('pinging', false)]);
      },
    );

    test('an agent whose last tool call was just now is working', () {
      final v = deriveAgentActivityView(
        _activity([_p('now', lastToolAt: _nowMs)]),
        now: _now,
        clockOffsetMs: 0,
      );
      expect(_connected(v), [('now', true)]);
    });

    test('a lastToolAt ahead of the local clock counts as working', () {
      // now - localMs(lastToolAt) is negative, so below 10 s (backward jump).
      final v = deriveAgentActivityView(
        _activity([_p('ahead', lastToolAt: _nowMs + 30000)]),
        now: _now,
        clockOffsetMs: 0,
      );
      expect(_connected(v), [('ahead', true)]);
    });

    test('a recent lastRequestAt never makes an old tool call working', () {
      final v = deriveAgentActivityView(
        _activity([
          _p('old-tool', lastRequestAt: _nowMs, lastToolAt: _nowMs - 60000),
        ]),
        now: _now,
        clockOffsetMs: 0,
      );
      expect(_connected(v), [('old-tool', false)]);
    });
  });

  group('clock offset', () {
    test('with clockOffsetMs 5000 expiry and working use the server clock', () {
      final v = deriveAgentActivityView(
        _activity([
          // 1 s before server now: expired.
          _p('expired', expiresAt: _nowMs + 4000, lastRequestAt: _nowMs + 9),
          // 1 s after server now: kept.
          _p('kept', expiresAt: _nowMs + 6000, lastRequestAt: _nowMs + 2),
          // 2 s ago in server time: working.
          _p(
            'working',
            expiresAt: _nowMs + 15000,
            lastRequestAt: _nowMs + 3,
            lastToolAt: _nowMs + 3000,
          ),
        ], serverNow: _nowMs + 5000),
        now: _now,
        clockOffsetMs: 5000,
      );
      expect(_connected(v), [('working', true), ('kept', false)]);
      expect(v.clockOffsetMs, 5000);
    });

    test('with clockOffsetMs 5000 the expiry boundary moves by 5 s', () {
      final v = deriveAgentActivityView(
        _activity([
          _p(
            'at-server-now',
            expiresAt: _nowMs + 5000,
            lastRequestAt: _nowMs + 1,
          ),
          _p('one-ms-left', expiresAt: _nowMs + 5001, lastRequestAt: _nowMs),
        ]),
        now: _now,
        clockOffsetMs: 5000,
      );
      expect(_connected(v), [('one-ms-left', false)]);
    });

    test('with clockOffsetMs 5000 the 10 s working window moves by 5 s', () {
      final v = deriveAgentActivityView(
        _activity([
          _p('busy', lastRequestAt: _nowMs + 1, lastToolAt: _nowMs - 4999),
          _p('idle', lastRequestAt: _nowMs, lastToolAt: _nowMs - 5000),
        ]),
        now: _now,
        clockOffsetMs: 5000,
      );
      expect(_connected(v), [('busy', true), ('idle', false)]);
    });

    test('with clockOffsetMs -5000 the server clock is behind', () {
      final v = deriveAgentActivityView(
        _activity([
          // localMs = now + 1 s: kept, though its server stamp is in the past.
          _p('kept', expiresAt: _nowMs - 4000, lastRequestAt: _nowMs - 1),
          // localMs = now: expired.
          _p('expired', expiresAt: _nowMs - 5000, lastRequestAt: _nowMs),
          // localMs(lastToolAt) = now - 7 s: working.
          _p(
            'working',
            expiresAt: _nowMs + 15000,
            lastRequestAt: _nowMs - 2,
            lastToolAt: _nowMs - 12000,
          ),
          // localMs(lastToolAt) = now - 10 s: idle.
          _p(
            'idle',
            expiresAt: _nowMs + 15000,
            lastRequestAt: _nowMs - 3,
            lastToolAt: _nowMs - 15000,
          ),
        ]),
        now: _now,
        clockOffsetMs: -5000,
      );
      expect(_connected(v), [
        ('kept', false),
        ('working', true),
        ('idle', false),
      ]);
      expect(v.clockOffsetMs, -5000);
    });

    test(
      'deriveAgentActivityView takes the offset it is given, not serverNow',
      () {
        final v = deriveAgentActivityView(
          _activity([
            _p('kept', expiresAt: _nowMs + 1),
          ], serverNow: _nowMs + 60000),
          now: _now,
          clockOffsetMs: 0,
        );
        expect(_connected(v), [('kept', false)]);
        expect(v.clockOffsetMs, 0);
      },
    );

    test('AgentActivityView.localMs subtracts the clock offset', () {
      const ahead = AgentActivityView(
        connected: [],
        recent: [],
        available: true,
        clockOffsetMs: 5000,
      );
      const behind = AgentActivityView(
        connected: [],
        recent: [],
        available: true,
        clockOffsetMs: -5000,
      );
      expect(ahead.localMs(10000), 5000);
      expect(behind.localMs(10000), 15000);
      expect(AgentActivityView.empty.localMs(10000), 10000);
    });
  });

  group('pass-through', () {
    test('recent and available pass through unchanged', () {
      // Deliberately not newest first: the view keeps the order as read.
      final recent = [
        agentEntry(id: 'e2', createdAt: _nowMs - 1000),
        agentEntry(id: 'e3', createdAt: _nowMs - 500, sessionId: 'gone'),
        agentEntry(id: 'e1', createdAt: _nowMs - 2000, noteId: 'n1'),
      ];
      for (final available in [true, false]) {
        final v = deriveAgentActivityView(
          _activity([_p('a')], recent: recent, available: available),
          now: _now,
          clockOffsetMs: 0,
        );
        expect([for (final e in v.recent) e.id], ['e2', 'e3', 'e1']);
        expect(v.recent[0], same(recent[0]));
        expect(v.recent[2].noteId, 'n1');
        expect(v.available, available, reason: '$available');
        expect(_connected(v), [('a', false)], reason: '$available');
      }
    });

    test('an unavailable read with no agents derives an unavailable view', () {
      final v = deriveAgentActivityView(
        _activity(const [], available: false),
        now: _now,
        clockOffsetMs: 1234,
      );
      expect(v.available, isFalse);
      expect(v.connected, isEmpty);
      expect(v.recent, isEmpty);
      expect(v.clockOffsetMs, 1234);
    });
  });

  test(
    'AgentActivityView.empty has no agents, no entries, is available and has offset 0',
    () {
      expect(AgentActivityView.empty.connected, isEmpty);
      expect(AgentActivityView.empty.recent, isEmpty);
      expect(AgentActivityView.empty.available, isTrue);
      expect(AgentActivityView.empty.clockOffsetMs, 0);
    },
  );

  test('ConnectedAgent holds its presence and working flag', () {
    final p = _p('x', lastToolAt: _nowMs);
    for (final working in [true, false]) {
      final c = ConnectedAgent(presence: p, working: working);
      expect(c.presence, same(p));
      expect(c.working, working);
    }
  });
}
