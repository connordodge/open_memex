// WI #452 (390-A1): the frozen AgentsAccess models and their one parser
// (D14). JSON keys are the snake_case keys of #390 req 3 (presence) and req 9
// (activity entries); AgentActivity.fromJson is the hosted wire (req 16).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';

/// A full presence record as a presence file or the wire carries it.
Map<String, Object?> _presenceJson() =>
    (jsonDecode('''
{
  "session_id": "01JC0000000000000000000S01",
  "client_name": "claude-desktop",
  "client_version": "0.9.3",
  "transport": "bridge",
  "started_at": 1762850000000,
  "last_seen_at": 1762850005000,
  "last_request_at": 1762850004000,
  "last_tool_at": 1762850003000,
  "expires_at": 1762850020000,
  "embeddings": true
}
''')
            as Map)
        .cast<String, Object?>();

/// A full activity entry as `agent_activity` or the wire carries it.
Map<String, Object?> _entryJson() =>
    (jsonDecode('''
{
  "id": "01JC0000000000000000000E01",
  "session_id": "01JC0000000000000000000S01",
  "client_name": "claude-desktop",
  "tool": "add_excerpt",
  "summary": "filed 4 blocks → Rest & Recharge",
  "note_id": "01JC0000000000000000000N01",
  "created_at": 1762850003500
}
''')
            as Map)
        .cast<String, Object?>();

/// Every field of [p], in declaration order.
List<Object?> _presence(AgentPresence p) => [
  p.sessionId,
  p.clientName,
  p.clientVersion,
  p.transport,
  p.startedAt,
  p.lastSeenAt,
  p.lastRequestAt,
  p.lastToolAt,
  p.expiresAt,
  p.embeddings,
];

/// Every field of [e], in declaration order.
List<Object?> _entry(AgentActivityEntry e) => [
  e.id,
  e.sessionId,
  e.clientName,
  e.tool,
  e.summary,
  e.noteId,
  e.createdAt,
];

void main() {
  group('AgentPresence.fromJson', () {
    test('AgentPresence.fromJson parses every presence record key', () {
      final p = AgentPresence.fromJson(_presenceJson());
      expect(_presence(p), [
        '01JC0000000000000000000S01',
        'claude-desktop',
        '0.9.3',
        'bridge',
        1762850000000,
        1762850005000,
        1762850004000,
        1762850003000,
        1762850020000,
        true,
      ]);
    });

    test(
      'AgentPresence.fromJson reads a null client_version and last_tool_at as null',
      () {
        final json = _presenceJson()
          ..['client_version'] = null
          ..['last_tool_at'] = null
          ..['embeddings'] = false
          ..['transport'] = 'stdio';
        final p = AgentPresence.fromJson(json);
        expect(_presence(p), [
          '01JC0000000000000000000S01',
          'claude-desktop',
          null,
          'stdio',
          1762850000000,
          1762850005000,
          1762850004000,
          null,
          1762850020000,
          false,
        ]);
      },
    );

    test('AgentPresence.fromJson keeps each transport value as-is', () {
      for (final transport in ['stdio', 'bridge', 'http', 'websocket-v2', '']) {
        final p = AgentPresence.fromJson(
          _presenceJson()..['transport'] = transport,
        );
        expect(p.transport, transport, reason: transport);
        expect(p.sessionId, '01JC0000000000000000000S01', reason: transport);
      }
    });

    test('AgentPresence.fromJson ignores unknown keys', () {
      final p = AgentPresence.fromJson(
        _presenceJson()
          ..['future_field'] = {'nested': 1}
          ..['token'] = 'never-read',
      );
      expect(_presence(p), _presence(AgentPresence.fromJson(_presenceJson())));
      expect(p.sessionId, '01JC0000000000000000000S01');
      expect(p.expiresAt, 1762850020000);
    });

    test(
      'AgentPresence.fromJson throws FormatException when session_id is missing',
      () {
        expect(
          () => AgentPresence.fromJson(_presenceJson()..remove('session_id')),
          throwsFormatException,
        );
      },
    );

    test(
      'AgentPresence.fromJson throws FormatException when expires_at is a string',
      () {
        expect(
          () => AgentPresence.fromJson(
            _presenceJson()..['expires_at'] = '1762850020000',
          ),
          throwsFormatException,
        );
      },
    );

    // Every other required key, missing or of the wrong type.
    for (final (name, key, value) in <(String, String, Object?)>[
      (
        'AgentPresence.fromJson rejects a missing client_name',
        'client_name',
        #missing,
      ),
      (
        'AgentPresence.fromJson rejects a missing transport',
        'transport',
        #missing,
      ),
      (
        'AgentPresence.fromJson rejects a missing started_at',
        'started_at',
        #missing,
      ),
      (
        'AgentPresence.fromJson rejects a missing last_seen_at',
        'last_seen_at',
        #missing,
      ),
      (
        'AgentPresence.fromJson rejects a missing last_request_at',
        'last_request_at',
        #missing,
      ),
      (
        'AgentPresence.fromJson rejects a missing expires_at',
        'expires_at',
        #missing,
      ),
      (
        'AgentPresence.fromJson rejects a missing embeddings',
        'embeddings',
        #missing,
      ),
      ('AgentPresence.fromJson rejects a null session_id', 'session_id', null),
      ('AgentPresence.fromJson rejects a null expires_at', 'expires_at', null),
      ('AgentPresence.fromJson rejects a numeric session_id', 'session_id', 7),
      (
        'AgentPresence.fromJson rejects a numeric client_name',
        'client_name',
        7,
      ),
      (
        'AgentPresence.fromJson rejects a numeric client_version',
        'client_version',
        7,
      ),
      ('AgentPresence.fromJson rejects a numeric transport', 'transport', 1),
      ('AgentPresence.fromJson rejects a string started_at', 'started_at', '1'),
      (
        'AgentPresence.fromJson rejects a string last_seen_at',
        'last_seen_at',
        '1',
      ),
      (
        'AgentPresence.fromJson rejects a string last_request_at',
        'last_request_at',
        '1',
      ),
      (
        'AgentPresence.fromJson rejects a string last_tool_at',
        'last_tool_at',
        '1',
      ),
      (
        'AgentPresence.fromJson rejects a string embeddings',
        'embeddings',
        'true',
      ),
      ('AgentPresence.fromJson rejects a numeric embeddings', 'embeddings', 1),
    ]) {
      test(name, () {
        final json = _presenceJson();
        if (value == #missing) {
          json.remove(key);
        } else {
          json[key] = value;
        }
        expect(() => AgentPresence.fromJson(json), throwsFormatException);
      });
    }
  });

  group('AgentActivityEntry.fromJson', () {
    test('AgentActivityEntry.fromJson parses every activity entry key', () {
      final e = AgentActivityEntry.fromJson(_entryJson());
      expect(_entry(e), [
        '01JC0000000000000000000E01',
        '01JC0000000000000000000S01',
        'claude-desktop',
        'add_excerpt',
        'filed 4 blocks → Rest & Recharge',
        '01JC0000000000000000000N01',
        1762850003500,
      ]);
    });

    test('AgentActivityEntry.fromJson reads a null note_id as null', () {
      final e = AgentActivityEntry.fromJson(
        _entryJson()
          ..['note_id'] = null
          ..['tool'] = 'mark_day_reviewed'
          ..['summary'] = 'marked 2026-11-09 reviewed',
      );
      expect(_entry(e), [
        '01JC0000000000000000000E01',
        '01JC0000000000000000000S01',
        'claude-desktop',
        'mark_day_reviewed',
        'marked 2026-11-09 reviewed',
        null,
        1762850003500,
      ]);
    });

    test('AgentActivityEntry.fromJson ignores unknown keys', () {
      final e = AgentActivityEntry.fromJson(_entryJson()..['extra'] = [1, 2]);
      expect(_entry(e), _entry(AgentActivityEntry.fromJson(_entryJson())));
      expect(e.id, '01JC0000000000000000000E01');
    });

    for (final (name, key, value) in <(String, String, Object?)>[
      ('AgentActivityEntry.fromJson rejects a missing id', 'id', #missing),
      (
        'AgentActivityEntry.fromJson rejects a missing session_id',
        'session_id',
        #missing,
      ),
      (
        'AgentActivityEntry.fromJson rejects a missing client_name',
        'client_name',
        #missing,
      ),
      ('AgentActivityEntry.fromJson rejects a missing tool', 'tool', #missing),
      (
        'AgentActivityEntry.fromJson rejects a missing summary',
        'summary',
        #missing,
      ),
      (
        'AgentActivityEntry.fromJson rejects a missing created_at',
        'created_at',
        #missing,
      ),
      (
        'AgentActivityEntry.fromJson rejects a string created_at',
        'created_at',
        '1',
      ),
      ('AgentActivityEntry.fromJson rejects a numeric note_id', 'note_id', 3),
      ('AgentActivityEntry.fromJson rejects a numeric summary', 'summary', 3),
      ('AgentActivityEntry.fromJson rejects a null tool', 'tool', null),
    ]) {
      test(name, () {
        final json = _entryJson();
        if (value == #missing) {
          json.remove(key);
        } else {
          json[key] = value;
        }
        expect(() => AgentActivityEntry.fromJson(json), throwsFormatException);
      });
    }
  });

  group('AgentActivity.fromJson', () {
    Map<String, Object?> wire() =>
        (jsonDecode(
                  jsonEncode({
                    'agents': [
                      _presenceJson(),
                      _presenceJson()
                        ..['session_id'] = '01JC0000000000000000000S02'
                        ..['client_name'] = 'claude-code'
                        ..['transport'] = 'http'
                        ..['client_version'] = null
                        ..['last_tool_at'] = null
                        ..['last_request_at'] = 1762850001000,
                    ],
                    'recent': [
                      _entryJson(),
                      _entryJson()
                        ..['id'] = '01JC0000000000000000000E00'
                        ..['note_id'] = null
                        ..['created_at'] = 1762850000500,
                    ],
                    'available': true,
                    'server_now': 1762850006000,
                  }),
                )
                as Map)
            .cast<String, Object?>();

    test(
      'AgentActivity.fromJson parses the hosted wire shape with server_now as serverNow',
      () {
        final a = AgentActivity.fromJson(wire());
        expect(a.serverNow, 1762850006000);
        expect(a.available, isTrue);
        expect(
          [for (final p in a.agents) _presence(p)],
          [
            _presence(AgentPresence.fromJson(_presenceJson())),
            [
              '01JC0000000000000000000S02',
              'claude-code',
              null,
              'http',
              1762850000000,
              1762850005000,
              1762850001000,
              null,
              1762850020000,
              true,
            ],
          ],
        );
        expect(
          [for (final e in a.recent) _entry(e)],
          [
            _entry(AgentActivityEntry.fromJson(_entryJson())),
            [
              '01JC0000000000000000000E00',
              '01JC0000000000000000000S01',
              'claude-desktop',
              'add_excerpt',
              'filed 4 blocks → Rest & Recharge',
              null,
              1762850000500,
            ],
          ],
        );
      },
    );

    test(
      'AgentActivity.fromJson reads available false with no agents and no entries',
      () {
        final a = AgentActivity.fromJson({
          'agents': <Object?>[],
          'recent': <Object?>[],
          'available': false,
          'server_now': 42,
          'unknown': 'ignored',
        });
        expect(a.agents, isEmpty);
        expect(a.recent, isEmpty);
        expect(a.available, isFalse);
        expect(a.serverNow, 42);
      },
    );

    for (final (name, mutate)
        in <(String, void Function(Map<String, Object?>))>[
          (
            'AgentActivity.fromJson rejects a missing agents',
            (j) => j.remove('agents'),
          ),
          (
            'AgentActivity.fromJson rejects a missing recent',
            (j) => j.remove('recent'),
          ),
          (
            'AgentActivity.fromJson rejects a missing available',
            (j) => j.remove('available'),
          ),
          (
            'AgentActivity.fromJson rejects agents that is not a list',
            (j) => j['agents'] = {'a': 1},
          ),
          (
            'AgentActivity.fromJson rejects recent that is not a list',
            (j) => j['recent'] = 'x',
          ),
          (
            'AgentActivity.fromJson rejects a string available',
            (j) => j['available'] = 'true',
          ),
          (
            'AgentActivity.fromJson rejects a string server_now',
            (j) => j['server_now'] = '1',
          ),
          (
            'AgentActivity.fromJson rejects an agent that is not an object',
            (j) => j['agents'] = [1],
          ),
          (
            'AgentActivity.fromJson rejects an agent missing session_id',
            (j) =>
                (((j['agents']! as List).first as Map)..remove('session_id')),
          ),
          (
            'AgentActivity.fromJson rejects an entry missing created_at',
            (j) =>
                (((j['recent']! as List).first as Map)..remove('created_at')),
          ),
        ]) {
      test(name, () {
        final json = wire();
        mutate(json);
        expect(() => AgentActivity.fromJson(json), throwsFormatException);
      });
    }
  });

  group('AgentActivity.fromJson list elements', () {
    test('AgentActivity.fromJson parses elements that are untyped maps', () {
      // A Map<dynamic, dynamic> (not a Map<String, Object?>) is still a JSON
      // object when every key is a String.
      final Map<dynamic, dynamic> presence = {..._presenceJson()};
      final Map<dynamic, dynamic> entry = {..._entryJson()};
      final a = AgentActivity.fromJson({
        'agents': [presence],
        'recent': [entry],
        'available': true,
      });
      expect(a.agents.single.sessionId, '01JC0000000000000000000S01');
      expect(a.recent.single.id, '01JC0000000000000000000E01');
    });

    test('AgentActivity.fromJson rejects an element with a non-String key', () {
      final Map<dynamic, dynamic> presence = {..._presenceJson(), 7: 'x'};
      expect(
        () => AgentActivity.fromJson({
          'agents': [presence],
          'recent': const <Object?>[],
          'available': true,
        }),
        throwsFormatException,
      );
    });
  });

  test('AgentActivity keeps serverNow null when built for a local vault', () {
    final recent = [AgentActivityEntry.fromJson(_entryJson())];
    final a = AgentActivity(agents: const [], recent: recent, available: true);
    expect(a.serverNow, isNull);
    expect(a.recent, same(recent));
  });
}
