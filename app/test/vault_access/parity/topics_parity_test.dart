// WI #83 (V3), AC 2 and AC 3: the topics reads on #74's frozen seed.
//
// AC 2: the local `smartFolders()` / `unsortedNotes()` (`LocalTopicsAccess`
// over `seededFakeVaultDb()`) equal the parsed `api_v1/topics` fixtures,
// compared as unordered collections (the local reads are unordered; the
// wire is sorted).
// AC 3: the hosted reads, driven through `fake_vault_server.dart` on the
// fixture rows, return models equal to the local reads. Local `getSetting`
// runs through `FolderCliFake` over the same seed database.
//
// API under test:
//   HostedTopicsAccess({required HostedClient client, required String vaultName})
//     .smartFolders / unsortedNotes / getSetting
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/settings_cli.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/topics.dart';
import 'package:open_memex_app/src/vault_access/local/topics.dart';

import '../../support/api_fixtures.dart';
import '../../support/fake_clock.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/folder_cli_fakes.dart';
import '../../support/vault_access_shapes.dart';

const _wi83TopicsDir = '$apiV1FixturesDir/topics';
const _wi83Loose = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const _wi83Broken = '01M5DQAYZ5RH88SRZGPY15XXVM';

class _Wi83Pair {
  _Wi83Pair(this.hosted, this.local, this.server);

  final HostedTopicsAccess hosted;
  final LocalTopicsAccess local;
  final FakeVaultServer server;
}

_Wi83Pair _pair() {
  final server = FakeVaultServer()..serveDomain('topics');
  final container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  final db = seededFakeVaultDb();
  addTearDown(db.close);
  final cli = FakeMemexCli();
  FolderCliFake(db).install(cli);
  return _Wi83Pair(
    HostedTopicsAccess(
      client: server.connect(container),
      vaultName: seedVaultName,
    ),
    LocalTopicsAccess(vaultPath: '/unused/wi83', db: db, cli: cli),
    server,
  );
}

/// The first row of `topics/index.json` for `GET <path>`, decoded.
Map<String, Object?> _fixture(String path) =>
    loadFixtureRows(_wi83TopicsDir)
            .firstWhere(
              (r) =>
                  r.method == 'GET' &&
                  r.path == '/vaults/$seedVaultName/api/v1$path',
            )
            .readResponseJson()!
        as Map<String, Object?>;

/// `smart_folders.json` parsed into today's models by hand (not through the
/// hosted codec).
SmartFolderData _fixtureSmartFolders() {
  final json = _fixture('/smart-folders');
  return SmartFolderData(
    folders: [
      for (final f in (json['folders']! as List).cast<Map<String, Object?>>())
        SmartFolderRow(
          id: f['id']! as String,
          name: f['name']! as String,
          parentId: f['parent_id'] as String?,
          pinned: f['pinned']! as bool,
        ),
    ],
    members: [
      for (final m in (json['members']! as List).cast<Map<String, Object?>>())
        SmartFolderMemberRow(
          folderId: m['folder_id']! as String,
          noteId: m['note_id']! as String,
          title: m['title']! as String,
          pinned: m['pinned']! as bool,
        ),
    ],
  );
}

List<UnsortedNoteRow> _fixtureUnsorted() => [
  for (final n
      in (_fixture('/unsorted')['notes']! as List).cast<Map<String, Object?>>())
    UnsortedNoteRow(
      noteId: n['note_id']! as String,
      title: n['title']! as String,
      role: n['role'] as String?,
    ),
];

/// Each row of [rows] as its shape, for an unordered comparison.
List<Object?> _shapes(Iterable<Object?> rows) => [
  for (final r in rows) vaultAccessShape(r),
];

void main() {
  test(
    'the local and hosted smartFolders on the seed equal the parsed fixture as unordered collections',
    () async {
      final p = _pair();
      final want = _fixtureSmartFolders();
      expect(want.folders, hasLength(3));
      expect(want.members, hasLength(3));
      expect(want.folders.where((f) => f.pinned).map((f) => f.name), [
        'Design',
      ], reason: 'the seed holds a pinned folder (D10)');
      expect(want.folders.where((f) => f.parentId != null).map((f) => f.name), [
        'Systems',
      ], reason: 'and a nested one');
      final local = await p.local.smartFolders();
      expect(_shapes(local.folders), unorderedEquals(_shapes(want.folders)));
      expect(_shapes(local.members), unorderedEquals(_shapes(want.members)));
      final hosted = await p.hosted.smartFolders();
      expect(_shapes(hosted.folders), unorderedEquals(_shapes(want.folders)));
      expect(_shapes(hosted.members), unorderedEquals(_shapes(want.members)));
    },
  );

  test(
    'the local and hosted unsortedNotes on the seed equal the parsed fixture as unordered collections',
    () async {
      final p = _pair();
      final want = _fixtureUnsorted();
      expect(_shapes(want), [
        {
          'UnsortedNoteRow': [_wi83Loose, 'Loose Thought', null],
        },
        {
          'UnsortedNoteRow': [_wi83Broken, 'Broken Frontmatter', null],
        },
      ], reason: 'both role-less seed notes, invalid frontmatter included');
      expect(
        _shapes(await p.local.unsortedNotes()),
        unorderedEquals(_shapes(want)),
      );
      expect(
        _shapes(await p.hosted.unsortedNotes()),
        unorderedEquals(_shapes(want)),
      );
    },
  );

  test(
    'hosted smartFolders equals the local smartFolders on the seed',
    () async {
      final p = _pair();
      final hosted = await p.hosted.smartFolders();
      final local = await p.local.smartFolders();
      expect(_shapes(hosted.folders), unorderedEquals(_shapes(local.folders)));
      expect(_shapes(hosted.members), unorderedEquals(_shapes(local.members)));
    },
  );

  test(
    'hosted unsortedNotes equals the local unsortedNotes on the seed',
    () async {
      final p = _pair();
      expect(
        _shapes(await p.hosted.unsortedNotes()),
        unorderedEquals(_shapes(await p.local.unsortedNotes())),
      );
    },
  );

  test('hosted getSetting equals the local getSetting on the seed', () async {
    final p = _pair();
    final local = await p.local.getSetting(smartFolderMaxDepthKey);
    expect(local, 2);
    expect(await p.hosted.getSetting(smartFolderMaxDepthKey), local);
  });

  test('every topics read row is answered by a hosted read', () async {
    final p = _pair();
    await p.hosted.smartFolders();
    await p.hosted.unsortedNotes();
    await p.hosted.getSetting(smartFolderMaxDepthKey);
    await p.hosted.reviewPrompt();
    final served = <String>{
      for (final r in p.server.requests) '${r.method} ${r.url}',
    };
    for (final want in [
      'GET $fakeServerUrl/vaults/seed/api/v1/smart-folders',
      'GET $fakeServerUrl/vaults/seed/api/v1/unsorted',
      'GET $fakeServerUrl/vaults/seed/api/v1/settings/smart_folder_max_depth',
      'GET $fakeServerUrl/vaults/seed/api/v1/prompts/review',
    ]) {
      expect(served, contains(want));
    }
  });
}
