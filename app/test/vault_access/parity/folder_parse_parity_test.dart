// WI #83 (V3), verify mode: HostedTopicsAccess parses the folder results
// (`memex folder new|update|rm|add` objects) with the same public parsers
// the CLI wrappers use in app/lib/src/cli/folder_cli.dart
// (parseFolderResult, parseFolderDeleteResult,
// parseFolderMembershipResult). Kept as a regression guard against the two
// paths drifting apart again: for every 2xx folder row of
// api_v1/topics/index.json, and for run-time variants of each shape, the
// hosted call and the CLI wrapper on the same JSON give equal models, or
// both reject it with a null-code MemexException.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/folder_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi83pTopicsDir = '$apiV1FixturesDir/topics';
const _wi83pBase = '/vaults/seed/api/v1';
const _wi83pFolder = '01M5DQAYZHJTTW6PPF4P7GNCHN';
const _wi83pNote = '01M5DQAYZ4RYSGA8T0YEEF8QRS';

/// The four folder results: CLI subcommand, hosted route and both calls.
enum _Wi83pKind { create, update, delete, add }

String _wi83pSub(_Wi83pKind k) => switch (k) {
  _Wi83pKind.create => 'folder new',
  _Wi83pKind.update => 'folder update',
  _Wi83pKind.delete => 'folder rm',
  _Wi83pKind.add => 'folder add',
};

(String, String, int) _wi83pRoute(_Wi83pKind k) => switch (k) {
  _Wi83pKind.create => ('POST', '/smart-folders', 201),
  _Wi83pKind.update => ('PATCH', '/smart-folders/$_wi83pFolder', 200),
  _Wi83pKind.delete => ('DELETE', '/smart-folders/$_wi83pFolder', 200),
  _Wi83pKind.add => ('POST', '/smart-folders/$_wi83pFolder/members', 200),
};

Future<Object?> _wi83pCatch(Future<Object?> f) async {
  try {
    return await f;
  } catch (e) {
    return e;
  }
}

/// What a result or a rejection looks like, for comparing the two paths.
Object? _wi83pShape(Object? outcome) => switch (outcome) {
  MemexException(:final code) => {'MemexException': code},
  _ => vaultAccessShape(outcome),
};

/// The hosted result of [kind] for a 2xx response [body].
Future<Object?> _wi83pHosted(_Wi83pKind kind, String body) async {
  final server = FakeVaultServer();
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final (method, path, status) = _wi83pRoute(kind);
  server.route(method, '$_wi83pBase$path', status: status, body: body);
  final t = HostedTopicsAccess(
    client: server.connect(container),
    vaultName: seedVaultName,
  );
  return _wi83pCatch(switch (kind) {
    _Wi83pKind.create => t.createFolder(name: 'Mechanics'),
    _Wi83pKind.update => t.updateFolder(id: _wi83pFolder, name: 'Later'),
    _Wi83pKind.delete => t.deleteFolder(id: _wi83pFolder),
    _Wi83pKind.add => t.addToFolder(folderId: _wi83pFolder, noteId: _wi83pNote),
  });
}

/// The CLI wrapper's result of [kind] for stdout [body].
Future<Object?> _wi83pCli(_Wi83pKind kind, String body) {
  final cli = FakeMemexCli()..on(_wi83pSub(kind), (_) => FakeMemexCli.ok(body));
  return _wi83pCatch(switch (kind) {
    _Wi83pKind.create => cli.createFolder(vaultPath: '/v', name: 'Mechanics'),
    _Wi83pKind.update => cli.updateFolder(
      vaultPath: '/v',
      id: _wi83pFolder,
      name: 'Later',
    ),
    _Wi83pKind.delete => cli.deleteFolder(vaultPath: '/v', id: _wi83pFolder),
    _Wi83pKind.add => cli.addToFolder(
      vaultPath: '/v',
      folderId: _wi83pFolder,
      noteId: _wi83pNote,
    ),
  });
}

/// [json] with the placeholders `normalize_volatile()` left in the fixture
/// (`"<timestamp>"`, `"<id:N>"`) replaced by concrete values, as the CLI
/// and the server print them.
Object? _wi83pMaterialize(Object? json) => switch (json) {
  '<timestamp>' => 1792539488433,
  String() when json.startsWith('<id:') && json.endsWith('>') =>
    '01M5DTVW3W6AMFEGYRFVZKVP${json.substring(4, json.length - 1).padLeft(2, '0')}',
  Map() => {
    for (final e in json.entries) e.key as String: _wi83pMaterialize(e.value),
  },
  List() => [for (final v in json) _wi83pMaterialize(v)],
  _ => json,
};

/// The [kind] of a 2xx folder row of topics/index.json, or null.
_Wi83pKind? _wi83pKindOf(FixtureRow r) {
  if (r.status < 200 || r.status >= 300) return null;
  final members = r.path.endsWith('/members');
  return switch (r.method) {
    'POST' when members => _Wi83pKind.add,
    'POST' => _Wi83pKind.create,
    'PATCH' => _Wi83pKind.update,
    'DELETE' => _Wi83pKind.delete,
    _ => null,
  };
}

/// Run-time variants of [base]: each key dropped, each key set to a value
/// of another type, each key null, and one unknown key added.
List<Map<String, Object?>> _wi83pVariants(Map<String, Object?> base) => [
  for (final k in base.keys) {...base}..remove(k),
  for (final k in base.keys)
    {
      ...base,
      k: switch (base[k]) {
        String() => 7,
        bool() => 'true',
        int() => '${base[k]}',
        _ => 7,
      },
    },
  for (final k in base.keys) {...base, k: null},
  for (final k in base.keys)
    if (base[k] is int) {...base, k: (base[k]! as int) + 0.5},
  {...base, 'unknown_key': 1},
];

void main() {
  test(
    'hosted and CLI folder parsers give equal models for every folder fixture row',
    () async {
      final rows = [
        for (final r in loadFixtureRows(_wi83pTopicsDir))
          if (_wi83pKindOf(r) != null) r,
      ];
      expect(
        {for (final r in rows) _wi83pKindOf(r)},
        _Wi83pKind.values.toSet(),
        reason: 'every folder result kind has a fixture row',
      );
      for (final r in rows) {
        final kind = _wi83pKindOf(r)!;
        final body = jsonEncode(_wi83pMaterialize(r.readResponseJson()));
        final hosted = await _wi83pHosted(kind, body);
        final cli = await _wi83pCli(kind, body);
        expect(hosted, isNot(isA<Exception>()), reason: r.response);
        expect(_wi83pShape(hosted), _wi83pShape(cli), reason: r.response);
      }
    },
  );

  test(
    'hosted and CLI folder parsers accept and reject the same variants of every folder shape',
    () async {
      var accepted = 0;
      var rejected = 0;
      for (final r in loadFixtureRows(_wi83pTopicsDir)) {
        final kind = _wi83pKindOf(r);
        if (kind == null) continue;
        final base =
            _wi83pMaterialize(r.readResponseJson())! as Map<String, Object?>;
        for (final variant in _wi83pVariants(base)) {
          final body = jsonEncode(variant);
          final hosted = await _wi83pHosted(kind, body);
          final cli = await _wi83pCli(kind, body);
          final why = '${r.response}: $body';
          expect(_wi83pShape(hosted), _wi83pShape(cli), reason: why);
          if (hosted is MemexException) {
            rejected++;
            expect(hosted.code, isNull, reason: why);
            expect(hosted.message, startsWith(_wi83pSub(kind)), reason: why);
          } else {
            accepted++;
          }
        }
      }
      // Not vacuous: both outcomes occur (an unknown key and a null
      // parent_id are accepted; a dropped key is rejected).
      expect(accepted, greaterThan(0));
      expect(rejected, greaterThan(0));
    },
  );
}
