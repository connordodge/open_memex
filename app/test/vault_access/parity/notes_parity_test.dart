// WI #81 (V1), AC 4: every hosted notes read, driven through
// `fake_vault_server.dart` on the `api_v1/notes` fixture rows, returns models
// equal to the local reads (`LocalNotesAccess` over `seededFakeVaultDb()`).
// `Note.frontmatter` is compared as decoded JSON; `titlesForIds` leaves out
// an unknown id.
//
// API under test:
//   HostedNotesAccess({required HostedClient client, required String vaultName})
//     .listNotes / getNote / allTitles / linksOutFor / linksInFor /
//      titlesForIds / distinctLinkKinds
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/notes.dart';
import 'package:open_memex_app/src/vault_access/local/notes.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_vault_server.dart';
import '../../support/vault_access_shapes.dart';

const _wi81NotesDir = '$apiV1FixturesDir/notes';
const _wi81Unknown = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
const _wi81Broken = '01M5DQAYZ5RH88SRZGPY15XXVM';

class _Wi81Pair {
  _Wi81Pair(this.hosted, this.local, this.server);

  final HostedNotesAccess hosted;
  final LocalNotesAccess local;
  final FakeVaultServer server;
}

_Wi81Pair _pair() {
  final server = FakeVaultServer()..serveDomain('notes');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final db = seededFakeVaultDb();
  addTearDown(db.close);
  return _Wi81Pair(
    HostedNotesAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
    LocalNotesAccess(vaultPath: '/unused/wi81', db: db),
    server,
  );
}

/// A [Note] as plain values, with its frontmatter decoded (kept as text when
/// it is not JSON, like the seed's Broken Frontmatter note).
Object? _wi81NoteShape(Note? n) => n == null
    ? null
    : {
        'id': n.id,
        'title': n.title,
        'contentMd': n.contentMd,
        'frontmatter': _wi81Frontmatter(n.frontmatter),
        'role': n.role,
        'version': n.version,
        'createdAt': n.createdAt,
        'updatedAt': n.updatedAt,
        'tags': n.tags,
      };

Object? _wi81Frontmatter(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return {'not json': text};
  }
}

/// The read rows: every GET, plus `POST /titles/lookup`.
List<FixtureRow> _readRows() => [
  for (final row in loadFixtureRows(_wi81NotesDir))
    if (row.method == 'GET' ||
        (row.method == 'POST' && row.path.endsWith('/titles/lookup')))
      row,
];

/// The path below `/vaults/seed/api/v1`, split, and the query.
(List<String>, Map<String, String>) _route(FixtureRow row) {
  final uri = Uri.parse(row.path);
  expect(uri.pathSegments.take(4).toList(), [
    'vaults',
    seedVaultName,
    'api',
    'v1',
  ], reason: row.path);
  return (uri.pathSegments.sublist(4), uri.queryParameters);
}

void main() {
  test(
    'hosted listNotes equals the local listNotes on every list row',
    () async {
      final p = _pair();
      var rows = 0;
      for (final row in _readRows()) {
        final (seg, q) = _route(row);
        if (seg.length != 1 || seg.first != 'notes') continue;
        rows++;
        final limit = int.parse(q['limit']!);
        expect(
          vaultAccessShape(await p.hosted.listNotes(limit: limit)),
          vaultAccessShape(await p.local.listNotes(limit: limit)),
          reason: row.path,
        );
      }
      expect(rows, 2);
    },
  );

  test('hosted getNote equals the local getNote on every get row', () async {
    final p = _pair();
    var rows = 0;
    for (final row in _readRows()) {
      final (seg, _) = _route(row);
      if (seg.length != 2 || seg.first != 'notes') continue;
      rows++;
      final id = seg[1];
      final hosted = await p.hosted.getNote(id);
      expect(
        _wi81NoteShape(hosted),
        _wi81NoteShape(await p.local.getNote(id)),
        reason: row.path,
      );
      expect(hosted == null, row.status == 404, reason: row.path);
    }
    // Every seed note (Broken Frontmatter included, ruling D11b), plus the
    // unknown id.
    expect(rows, 11);
  });

  test(
    'hosted getNote of the Broken Frontmatter note keeps the stored text',
    () async {
      final p = _pair();
      final hosted = (await p.hosted.getNote(_wi81Broken))!;
      final local = (await p.local.getNote(_wi81Broken))!;
      expect(hosted.frontmatter, local.frontmatter);
      expect(hosted.frontmatter, '{"role": "topic"');
      expect(hosted.role, isNull);
      expect(_wi81NoteShape(hosted), _wi81NoteShape(local));
    },
  );

  test(
    'the Broken Frontmatter get fixture holds the local getNote fields',
    () async {
      // The D11b row was blessed from the server read; it must be exactly
      // what VaultDb.getNote returns on the seed, field by field.
      final db = seededFakeVaultDb();
      addTearDown(db.close);
      final local = db.getNote(_wi81Broken)!;
      final row = loadFixtureRows(
        _wi81NotesDir,
      ).singleWhere((r) => r.response == 'get_note_broken_frontmatter.json');
      expect(row.method, 'GET');
      expect(row.path, '/vaults/seed/api/v1/notes/$_wi81Broken');
      expect(row.status, 200);
      expect(row.readResponseJson(), {
        'note_id': local.id,
        'title': local.title,
        'content_md': local.contentMd,
        'frontmatter': local.frontmatter,
        'version': local.version,
        'created_at': local.createdAt,
        'updated_at': local.updatedAt,
        'tags': local.tags,
        // WI #242: the hosted read's field; this note has no footer tag.
        'footer_tags': const <String>[],
      });
    },
  );

  test('hosted getNote of an unknown id is null like the local read', () async {
    final p = _pair();
    expect(await p.local.getNote(_wi81Unknown), isNull);
    expect(await p.hosted.getNote(_wi81Unknown), isNull);
  });

  test(
    'hosted allTitles equals the local allTitles on every titles row',
    () async {
      final p = _pair();
      for (final limit in [1000, 3]) {
        expect(
          vaultAccessShape(await p.hosted.allTitles(limit: limit)),
          vaultAccessShape(await p.local.allTitles(limit: limit)),
          reason: 'limit $limit',
        );
      }
    },
  );

  test(
    'hosted linksOutFor equals the local linksOutFor for every note',
    () async {
      final p = _pair();
      var rows = 0;
      for (final row in _readRows()) {
        final (seg, _) = _route(row);
        if (seg.length != 4 || seg[2] != 'links' || seg[3] != 'out') continue;
        rows++;
        expect(
          vaultAccessShape(await p.hosted.linksOutFor(seg[1])),
          vaultAccessShape(await p.local.linksOutFor(seg[1])),
          reason: row.path,
        );
      }
      expect(rows, 11, reason: 'every seed note and an unknown id');
    },
  );

  test(
    'hosted linksInFor equals the local linksInFor with and without kind',
    () async {
      final p = _pair();
      var withKind = 0;
      var withoutKind = 0;
      for (final row in _readRows()) {
        final (seg, q) = _route(row);
        if (seg.length != 4 || seg[2] != 'links' || seg[3] != 'in') continue;
        final kind = q['kind'];
        kind == null ? withoutKind++ : withKind++;
        expect(
          vaultAccessShape(await p.hosted.linksInFor(seg[1], kind: kind)),
          vaultAccessShape(await p.local.linksInFor(seg[1], kind: kind)),
          reason: row.path,
        );
      }
      expect(withoutKind, 11);
      expect(withKind, 4);
    },
  );

  test(
    'hosted titlesForIds equals the local read and leaves out an unknown id',
    () async {
      final p = _pair();
      const ids = [
        '01M5DQAYZ3WP7H0NXZZV9M2315',
        '01M5DQAYZ4RYSGA8T0YEEF8QRS',
        _wi81Unknown,
      ];
      final hosted = await p.hosted.titlesForIds(ids);
      expect(hosted, await p.local.titlesForIds(ids));
      expect(hosted.containsKey(_wi81Unknown), isFalse);
      expect(hosted, {
        '01M5DQAYZ3WP7H0NXZZV9M2315': 'Player Loop',
        '01M5DQAYZ4RYSGA8T0YEEF8QRS': 'Loose Thought',
      });
      expect(await p.hosted.titlesForIds(const []), isEmpty);
    },
  );

  test('hosted distinctLinkKinds equals the local distinctLinkKinds', () async {
    final p = _pair();
    final hosted = await p.hosted.distinctLinkKinds();
    expect(hosted, await p.local.distinctLinkKinds());
    expect(hosted, ['about', 'extends', 'from-day', 'references']);
  });

  test(
    'the Broken Frontmatter note lists and titles like the local reads',
    () async {
      final p = _pair();
      final hosted = await p.hosted.listNotes(limit: 200);
      expect(hosted.map((n) => n.id), contains(_wi81Broken));
      final titles = await p.hosted.allTitles(limit: 1000);
      expect(titles.map((t) => t.id), contains(_wi81Broken));
    },
  );

  test('every notes read row is answered by a hosted read', () async {
    final p = _pair();
    // Drive every read once; each request must be answered by a fixture row
    // (the fake answers anything else with not_found).
    await p.hosted.listNotes(limit: 200);
    await p.hosted.listNotes(limit: 3);
    await p.hosted.allTitles(limit: 1000);
    await p.hosted.allTitles(limit: 3);
    await p.hosted.distinctLinkKinds();
    await p.hosted.titlesForIds(const [
      '01M5DQAYZ3WP7H0NXZZV9M2315',
      '01M5DQAYZ4RYSGA8T0YEEF8QRS',
      _wi81Unknown,
    ]);
    final served = <String>{
      for (final r in p.server.requests) '${r.method} ${r.url}',
    };
    for (final want in [
      'GET $fakeServerUrl/vaults/seed/api/v1/notes?limit=200',
      'GET $fakeServerUrl/vaults/seed/api/v1/notes?limit=3',
      'GET $fakeServerUrl/vaults/seed/api/v1/titles?limit=1000',
      'GET $fakeServerUrl/vaults/seed/api/v1/titles?limit=3',
      'GET $fakeServerUrl/vaults/seed/api/v1/link-kinds',
      'POST $fakeServerUrl/vaults/seed/api/v1/titles/lookup',
    ]) {
      expect(served, contains(want));
    }
  });
}
