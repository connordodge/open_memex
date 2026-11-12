// WI #401 (C0, ruling D21/D21a): the old-server compat fixtures for the new
// hosted routes of this run. A hosted server older than the app answers an
// unknown route with main's `not_found` handler body:
//
//   404 {"error":{"code":"not_found","message":"not found: no route for this path"}}
//
// (`MemexError::NotFound` Display adds `not found: `). The files live in
// `test/fixtures/api_v1/compat/`, are `dart_only` like `backup_not_found.json`,
// and are served by `FakeVaultServer.serveDomain('compat')`. The Rust half,
// which pins that main's handler answers exactly this body, is
// crates/memex-mcp/tests/api_compat_not_found.rs.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../support/api_fixtures.dart';
import '../../support/fake_vault_server.dart';

const _compatDir = '$apiV1FixturesDir/compat';
const _base = '/vaults/seed/api/v1';
const _noRouteMessage = 'not found: no route for this path';

/// A seed note id (Player Loop).
const _seedNote = '01M5DQAYZ3WP7H0NXZZV9M2315';

/// (test name, method, path with query, response file) for each new row, in
/// the order they are appended to `compat/index.json`.
const _newRows = <(String, String, String, String)>[
  (
    'compat GET agents answers 404 not_found with the main message',
    'GET',
    '$_base/agents',
    'agents_not_found.json',
  ),
  (
    'compat GET note echoes answers 404 not_found with the main message',
    'GET',
    '$_base/notes/$_seedNote/echoes?limit=8',
    'echoes_not_found.json',
  ),
  (
    'compat GET words answers 404 not_found with the main message',
    'GET',
    '$_base/words',
    'words_not_found.json',
  ),
  (
    'compat POST words answers 404 not_found with the main message',
    'POST',
    '$_base/words',
    'words_not_found.json',
  ),
  (
    'compat DELETE word answers 404 not_found with the main message',
    'DELETE',
    '$_base/words/serendipity',
    'words_not_found.json',
  ),
  (
    'compat GET tools answers 404 not_found with the main message',
    'GET',
    '$_base/tools',
    'tools_not_found.json',
  ),
  (
    'compat GET embeddings answers 404 not_found with the main message',
    'GET',
    '$_base/embeddings',
    'embeddings_not_found.json',
  ),
];

const _files = [
  'agents_not_found.json',
  'echoes_not_found.json',
  'words_not_found.json',
  'tools_not_found.json',
  'embeddings_not_found.json',
];

Future<http.Response> _send(
  FakeVaultServer server,
  String method,
  String pathAndQuery, {
  String? body,
}) {
  final request = http.Request(method, Uri.parse('$fakeServerUrl$pathAndQuery'))
    ..headers['authorization'] = 'Bearer ${server.token}';
  if (body != null) {
    request.headers['content-type'] = 'application/json';
    request.body = body;
  }
  return server.client.send(request).then(http.Response.fromStream);
}

void main() {
  test('compat index keeps its two existing rows and appends seven new rows '
      'in order', () {
    final rows = loadFixtureRows(_compatDir);
    expect(
      [for (final r in rows) (r.method, r.path, r.response, r.status)],
      [
        ('GET', '/api/v1/info', 'info_unknown_key.json', 200),
        ('GET', '$_base/backup', 'backup_not_found.json', 404),
        for (final (_, method, path, file) in _newRows)
          (method, path, file, 404),
      ],
    );
    expect(
      rows.every((r) => r.dartOnly),
      isTrue,
      reason: 'every compat row is dart_only',
    );
    expect(rows, hasLength(9));
  });

  test('compat index rows are one line per row in the existing style', () {
    final lines = File(p.join(_compatDir, 'index.json')).readAsLinesSync();
    expect(lines.first, '[');
    expect(lines.last, ']');
    final rowLines = lines.sublist(1, lines.length - 1);
    expect(rowLines, hasLength(9));
    for (var i = 0; i < rowLines.length; i++) {
      final line = rowLines[i];
      expect(line, startsWith('  {"method": "'), reason: line);
      expect(line, contains('"dart_only": true}'), reason: line);
      expect(line.endsWith(i == rowLines.length - 1 ? '}' : '},'), isTrue);
    }
  });

  test('each not found fixture file is the exact main unknown route body', () {
    final reference = File(
      p.join(_compatDir, 'backup_not_found.json'),
    ).readAsStringSync();
    for (final name in _files) {
      final text = File(p.join(_compatDir, name)).readAsStringSync();
      expect(text, reference, reason: '$name is byte-shaped like backup');
      expect(jsonDecode(text), {
        'error': {'code': 'not_found', 'message': _noRouteMessage},
      }, reason: name);
    }
  });

  for (final (name, method, path, file) in _newRows) {
    test(name, () async {
      final server = FakeVaultServer()..serveDomain('compat');
      final response = await _send(
        server,
        method,
        path,
        body: method == 'POST' ? jsonEncode({'word': 'serendipity'}) : null,
      );
      expect(response.statusCode, 404);
      final error = (jsonDecode(response.body) as Map)['error']! as Map;
      expect(error['code'], 'not_found');
      expect(error['message'], _noRouteMessage);
      expect(
        response.body,
        File(p.join(_compatDir, file)).readAsStringSync(),
        reason: 'served from $file',
      );
    });
  }

  test('compat rows are read back through readResponseJson with dartOnly', () {
    final rows = loadFixtureRows(
      _compatDir,
    ).where((r) => _newRows.any((n) => n.$3 == r.path && n.$2 == r.method));
    expect(rows, hasLength(_newRows.length));
    for (final r in rows) {
      expect(r.dartOnly, isTrue, reason: '$r');
      expect(r.status, 404, reason: '$r');
      final error = (r.readResponseJson()! as Map)['error']! as Map;
      expect(error['code'], 'not_found', reason: '$r');
      expect(error['message'], _noRouteMessage, reason: '$r');
    }
  });

  test('the echoes row is served only for its own limit query', () async {
    final server = FakeVaultServer()..serveDomain('compat');
    final row = loadFixtureRows(
      _compatDir,
    ).singleWhere((r) => r.response == 'echoes_not_found.json');
    expect(Uri.parse(row.path).queryParameters, {'limit': '8'});
    expect(
      Uri.parse(row.path).path,
      startsWith('$_base/notes/'),
      reason: 'a seed note id, never a placeholder',
    );
    final hit = await _send(server, 'GET', row.path);
    expect(
      ((jsonDecode(hit.body) as Map)['error']! as Map)['code'],
      'not_found',
    );
    final miss = await _send(
      server,
      'GET',
      '${Uri.parse(row.path).path}?limit=9',
    );
    expect(
      ((jsonDecode(miss.body) as Map)['error']! as Map)['code'],
      isNot('not_found'),
      reason: 'the fake compares the query: no row answers limit=9',
    );
  });

  test('the POST words row answers whatever JSON body the app sends', () async {
    final server = FakeVaultServer()..serveDomain('compat');
    for (final body in [
      jsonEncode({'word': 'serendipity'}),
      jsonEncode({'word': 'naive'}),
      '{}',
    ]) {
      final response = await _send(server, 'POST', '$_base/words', body: body);
      expect(response.statusCode, 404, reason: body);
      expect(
        ((jsonDecode(response.body) as Map)['error']! as Map)['message'],
        _noRouteMessage,
        reason: body,
      );
    }
  });
}
