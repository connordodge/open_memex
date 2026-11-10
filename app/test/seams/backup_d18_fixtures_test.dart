// WI #316 (R0, ruling D18): the shared backup fixtures parse from
// `test/fixtures` on the Dart side, with the rows A1 and A3 read. The Rust
// half is crates/memex-core/tests/backup_fixtures.rs.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/api_fixtures.dart';

const _backupDir = 'test/fixtures/backup';
const _backupPath = '/vaults/seed/api/v1/backup';
const _getKeys = [
  'enabled',
  'keep',
  'in_progress',
  'last_attempt_at',
  'last_success_at',
  'last_result',
  'last_error',
  'last_file',
  'last_file_created_at',
  'last_bytes',
];
const _stateKeys = [
  'last_attempt_at',
  'last_success_at',
  'last_result',
  'last_error',
  'last_file',
  'last_file_created_at',
  'last_bytes',
  'last_fingerprint',
];

Object? _json(String path) => jsonDecode(File(path).readAsStringSync());

void main() {
  test('every D18 backup fixture parses from test/fixtures with its rows', () {
    // backup_state.json: exactly the req 10a shape, five destinations.
    final state =
        _json('$_backupDir/backup_state.json')! as Map<String, Object?>;
    expect(state.keys, ['format', 'destinations']);
    expect(state['format'], 1);
    final destinations = state['destinations']! as Map<String, Object?>;
    expect(destinations, hasLength(5));
    final results = <String>[];
    for (final MapEntry(:key, :value) in destinations.entries) {
      expect(key, startsWith('/'), reason: 'absolute destination');
      final d = value! as Map<String, Object?>;
      expect(d.keys.toList(), _stateKeys, reason: key);
      results.add(d['last_result']! as String);
    }
    expect(results, [
      'created',
      'unchanged',
      'backup_failed',
      'backup_destination_unavailable',
      'backup_destination_unavailable',
    ]);
    final never =
        destinations['/Volumes/backups/memex']! as Map<String, Object?>;
    expect(
      [for (final k in _stateKeys.skip(4)) never[k]],
      [null, null, null, null],
    );
    expect(never['last_success_at'], isNull);

    // due_cases.json: the backward jump and both sides of 24 h are there.
    final due = _json('$_backupDir/due_cases.json')! as Map<String, Object?>;
    expect(due['due_after_ms'], 86400000);
    final cases = (due['cases']! as List).cast<Map<String, Object?>>();
    expect(
      cases.any(
        (c) =>
            c['last_success_at'] != null &&
            (c['last_success_at']! as int) > (c['now']! as int) &&
            c['due'] == true,
      ),
      isTrue,
      reason: 'backward clock jump',
    );
    expect(
      cases.any(
        (c) =>
            c['last_success_at'] != null &&
            (c['now']! as int) - (c['last_success_at']! as int) == 86400000,
      ),
      isTrue,
    );

    // file_names.json: every section A1 reads.
    final names = _json('$_backupDir/file_names.json')! as Map<String, Object?>;
    for (final k in [
      'valid',
      'look_alikes',
      'partials',
      'file_names',
      'labels',
    ]) {
      expect(names[k], isA<List<Object?>>(), reason: k);
      expect(names[k]! as List, isNotEmpty, reason: k);
    }

    // cli/*.json: req 17 and 34 shapes; the too-new error carries fields.
    final created = _json('$_backupDir/cli/backup_created.json')! as Map;
    expect(created['result'], 'created');
    expect(created['removed'], isA<List<Object?>>());
    final unchanged = _json('$_backupDir/cli/backup_unchanged.json')! as Map;
    expect(unchanged['last_file'], isA<String>());
    final never2 = _json('$_backupDir/cli/backup_unchanged_never.json')! as Map;
    expect(
      never2.containsKey('last_file') && never2['last_file'] == null,
      isTrue,
    );
    final restored = _json('$_backupDir/cli/restore_ok.json')! as Map;
    expect(restored.keys.toSet(), {'vault_id', 'path', 'created_at'});
    final tooNew =
        (_json('$_backupDir/cli/errors/backup_too_new.json')! as Map)['error']!
            as Map;
    expect(tooNew['code'], 'backup_too_new');
    expect(tooNew['schema_version'], isA<int>());
    expect(tooNew['supported_schema_version'], isA<int>());

    // api_v1/backup and api_v1/backup_off through the shared row loader.
    final rows = loadFixtureRows('$apiV1FixturesDir/backup');
    expect(
      [for (final r in rows) (r.method, r.status, r.dartOnly)],
      [
        ('GET', 200, false),
        ('POST', 202, false),
        ('GET', 200, true),
        ('GET', 200, true),
        ('GET', 200, true),
        ('POST', 409, true),
      ],
    );
    for (final r in rows) {
      expect(r.path, _backupPath);
      final body = r.readResponseJson()! as Map<String, Object?>;
      if (r.status == 409) {
        expect((body['error']! as Map)['code'], 'backup_in_progress');
      } else {
        expect(body.keys.toSet(), _getKeys.toSet(), reason: r.response);
      }
    }
    final off = loadFixtureRows('$apiV1FixturesDir/backup_off');
    expect(
      [for (final r in off) (r.method, r.status, r.dartOnly)],
      [('GET', 200, false), ('POST', 409, false)],
    );
    expect((off[0].readResponseJson()! as Map)['enabled'], false);
    expect(
      ((off[1].readResponseJson()! as Map)['error']! as Map)['code'],
      'backups_not_configured',
    );

    // compat: the old-server row.
    final old = loadFixtureRows(
      '$apiV1FixturesDir/compat',
    ).where((r) => r.path == _backupPath).toList();
    expect(old, hasLength(1));
    expect(
      (old.single.method, old.single.status, old.single.dartOnly),
      ('GET', 404, true),
    );
    expect(
      ((old.single.readResponseJson()! as Map)['error']! as Map)['code'],
      'not_found',
    );
  });
}
