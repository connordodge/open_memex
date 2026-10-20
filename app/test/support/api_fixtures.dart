// Wire-contract fixture support, Dart half (WI #74, rulings D10, D10a).
//
// Loads the rows of `test/fixtures/api_v1/<domain>/index.json`, builds a
// [FakeVaultDb] holding the frozen seed vault and parses the shared
// `server/utc_offsets.json`. The Rust half is
// `crates/memex-mcp/tests/support/api_fixtures.rs`; both parse rows the same
// way. `flutter test` runs with the package root (`app/`) as cwd.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fake_vault_db.dart';

/// The fixture root, relative to `app/`.
const apiV1FixturesDir = 'test/fixtures/api_v1';

/// The frozen seed: data rows only, loaded on top of `vault_schema_v5.sql`.
const seedVaultSqlPath = '$apiV1FixturesDir/seed_vault.sql';

/// The frozen seed manifest (`vault_id`, `created_at`).
const seedManifestPath = '$apiV1FixturesDir/seed_manifest.json';

/// The vault name used in every row path (`/vaults/seed/api/v1/...`); the
/// same as `SEED_VAULT_NAME` on the Rust side.
const seedVaultName = 'seed';

/// One row of `<domain>/index.json`. `method`, `path`, `response` and
/// `status` are required; `request` names the request body file, `headers`
/// are request headers and a `dart_only` row runs only on the Dart side.
class FixtureRow {
  FixtureRow({
    required this.domainDir,
    required this.method,
    required this.path,
    required this.request,
    required this.response,
    required this.status,
    required this.headers,
    required this.dartOnly,
  });

  /// The domain folder the row came from.
  final String domainDir;
  final String method;
  final String path;
  final String? request;
  final String response;
  final int status;

  /// Request headers; empty when the row has none.
  final Map<String, String> headers;

  /// `dart_only`; false when absent.
  final bool dartOnly;

  /// The decoded JSON of `<domain dir>/<response>`.
  Object? readResponseJson() =>
      jsonDecode(File(p.join(domainDir, response)).readAsStringSync());

  /// The bytes of `<domain dir>/<request>`, or null when the row has none.
  List<int>? readRequestBytes() {
    final file = request;
    return file == null
        ? null
        : File(p.join(domainDir, file)).readAsBytesSync();
  }

  @override
  String toString() =>
      'FixtureRow($method $path -> $status $response'
      '${dartOnly ? ', dart_only' : ''})';
}

/// Parses `<domainDir>/index.json`. Throws a [FormatException] naming the
/// row as `<domain>[<zero-based index>]` and the field on a malformed row.
List<FixtureRow> loadFixtureRows(String domainDir) {
  final domain = p.basename(p.normalize(domainDir));
  final index = File(p.join(domainDir, 'index.json'));
  if (!index.existsSync()) {
    throw FormatException('$domain: no index.json at ${index.path}');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(index.readAsStringSync());
  } on FormatException catch (e) {
    throw FormatException('$domain: index.json is not JSON: ${e.message}');
  }
  if (decoded is! List) {
    throw FormatException('$domain: index.json must be a JSON array of rows');
  }
  return [
    for (var i = 0; i < decoded.length; i++)
      _parseRow(domainDir, '$domain[$i]', decoded[i]),
  ];
}

/// The only keys a row may have (the same set as `ROW_FIELDS` in Rust).
const _rowFields = {
  'method',
  'path',
  'request',
  'response',
  'status',
  'headers',
  'dart_only',
};

/// [file] when it is a bare file name in the domain folder: not empty, not
/// `.` or `..`, and with no `/` or `\` (so never absolute and never outside
/// the folder).
String _bareFileName(String name, String field, String file) {
  if (file.isEmpty ||
      file == '.' ||
      file == '..' ||
      file.contains('/') ||
      file.contains(r'\')) {
    throw FormatException(
      '$name: field "$field" must be a bare file name in the domain folder, '
      'got ${jsonEncode(file)}',
    );
  }
  return file;
}

FixtureRow _parseRow(String domainDir, String name, Object? row) {
  if (row is! Map<String, Object?>) {
    throw FormatException('$name: a row must be a JSON object');
  }
  for (final key in row.keys) {
    if (!_rowFields.contains(key)) {
      throw FormatException(
        '$name: unknown field "$key" (a row has only ${_rowFields.join(', ')})',
      );
    }
  }
  String requiredString(String field) {
    final v = row[field];
    if (v == null) {
      throw FormatException('$name: missing required field "$field"');
    }
    if (v is! String) {
      throw FormatException('$name: field "$field" must be a string');
    }
    return v;
  }

  final method = requiredString('method');
  final path = requiredString('path');
  final response = _bareFileName(name, 'response', requiredString('response'));

  final status = row['status'];
  if (status == null) {
    throw FormatException('$name: missing required field "status"');
  }
  if (status is! int) {
    throw FormatException(
      '$name: field "status" must be an integer, got ${jsonEncode(status)}',
    );
  }
  if (status < 100 || status > 599) {
    throw FormatException(
      '$name: field "status" must be an HTTP status, got $status',
    );
  }

  final request = row['request'];
  if (request != null && request is! String) {
    throw FormatException('$name: field "request" must be a string');
  }
  if (request is String) _bareFileName(name, 'request', request);

  final headers = <String, String>{};
  final rawHeaders = row['headers'];
  if (rawHeaders != null) {
    if (rawHeaders is! Map<String, Object?>) {
      throw FormatException('$name: field "headers" must be an object');
    }
    rawHeaders.forEach((k, v) {
      if (v is! String) {
        throw FormatException(
          '$name: field "headers" value for "$k" must be a string',
        );
      }
      headers[k] = v;
    });
  }

  final dartOnly = row['dart_only'];
  if (dartOnly != null && dartOnly is! bool) {
    throw FormatException('$name: field "dart_only" must be a boolean');
  }

  return FixtureRow(
    domainDir: domainDir,
    method: method,
    path: path,
    request: request as String?,
    response: response,
    status: status,
    headers: headers,
    dartOnly: (dartOnly as bool?) ?? false,
  );
}

/// Every `api_v1/<domain>/` folder that holds an `index.json`, sorted by
/// folder name (one level deep; `api_v1` itself is not a domain). The same
/// set as `all_domain_dirs()` in Rust.
List<String> allDomainDirs() => [
  for (final e in Directory(apiV1FixturesDir).listSync())
    if (e is Directory && File(p.join(e.path, 'index.json')).existsSync())
      e.path,
]..sort();

/// Loads `<domainDir>/index.json` and checks that every `request` and
/// `response` file its rows name exists in the folder. Throws a
/// [FormatException] listing every missing file as
/// `<domain>[<i>]: <field> file <name> is missing`.
void checkDomainFiles(String domainDir) {
  final domain = p.basename(p.normalize(domainDir));
  final rows = loadFixtureRows(domainDir);
  final missing = <String>[];
  for (var i = 0; i < rows.length; i++) {
    final files = {'request': rows[i].request, 'response': rows[i].response};
    files.forEach((field, file) {
      if (file != null && !File(p.join(domainDir, file)).existsSync()) {
        missing.add('$domain[$i]: $field file $file is missing');
      }
    });
  }
  if (missing.isNotEmpty) throw FormatException(missing.join('\n'));
}

/// The row text both the Rust and the Dart row-loader tests parse (AC5). It
/// sits outside `api_v1/`, so it is never a domain and names no real files.
const parityIndexJsonPath = 'test/fixtures/api_fixtures_parity/index.json';

/// The committed seed manifest.
Map<String, Object?> seedManifest() =>
    jsonDecode(File(seedManifestPath).readAsStringSync())
        as Map<String, Object?>;

/// The frozen seed `vault_id`.
String seedVaultId() => seedManifest()['vault_id']! as String;

/// A fresh [FakeVaultDb] (the V5 schema fixture) with every row of the
/// frozen seed loaded; each call returns its own database.
FakeVaultDb seededFakeVaultDb() {
  final db = FakeVaultDb.v5();
  db.db.execute(File(seedVaultSqlPath).readAsStringSync());
  return db;
}

/// The `X-Memex-UTC-Offset` cases of `server/utc_offsets.json` (D10a):
/// [valid] header to signed minutes, [invalid] headers, and [format] signed
/// minutes to header.
class UtcOffsetCases {
  const UtcOffsetCases({
    required this.valid,
    required this.invalid,
    required this.format,
  });

  final Map<String, int> valid;
  final List<String> invalid;
  final Map<int, String> format;
}

/// Parses `server/utc_offsets.json`:
/// `{"valid": [{"header", "minutes"}], "invalid": [header],
///   "format": [{"minutes", "header"}]}`.
UtcOffsetCases loadUtcOffsetCases() {
  final json =
      jsonDecode(
            File(
              '$apiV1FixturesDir/server/utc_offsets.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  List<(String, int)> pairs(String set) => [
    for (final row in json[set]! as List<Object?>)
      (
        (row! as Map<String, Object?>)['header']! as String,
        (row as Map<String, Object?>)['minutes']! as int,
      ),
  ];
  return UtcOffsetCases(
    valid: {for (final (h, m) in pairs('valid')) h: m},
    invalid: [for (final h in json['invalid']! as List<Object?>) h! as String],
    format: {for (final (h, m) in pairs('format')) m: h},
  );
}
