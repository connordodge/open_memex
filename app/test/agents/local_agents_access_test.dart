// WI #453 (390-A2): LocalAgentsAccess.activity (presence records through the
// PresenceReader seam, the agent_activity log from the read-only memex.db) and
// FilePresenceReader on temp vaults. Never reads a real vault (lesson): every
// vault here is a temp dir or a fake reader.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/fake_vault_db.dart';

/// Base time, ms epoch (2026-11-11).
const _t0 = 1762880000000;

/// A [PresenceReader] holding scripted raw texts; [records] can be replaced
/// between reads, and every read answers the current (last pushed) list.
class _A2FakePresenceReader implements PresenceReader {
  _A2FakePresenceReader([List<String> records = const []])
    : records = List.of(records);

  List<String> records;
  int reads = 0;

  @override
  List<String> readAll() {
    reads++;
    return List.of(records);
  }
}

/// One presence record's JSON text with the req 3 snake_case keys.
String _record(
  String sessionId, {
  required int lastRequestAt,
  int? expiresAt,
  String clientName = 'claude-code',
  String? clientVersion = '1.2.3',
  String transport = 'stdio',
  int? lastToolAt,
  bool embeddings = false,
  Map<String, Object?> extra = const {},
}) => jsonEncode({
  'session_id': sessionId,
  'client_name': clientName,
  'client_version': clientVersion,
  'transport': transport,
  'started_at': lastRequestAt - 60000,
  'last_seen_at': lastRequestAt,
  'last_request_at': lastRequestAt,
  'last_tool_at': lastToolAt,
  'expires_at': expiresAt ?? lastRequestAt + 15000,
  'embeddings': embeddings,
  ...extra,
});

List<String> _sessions(AgentActivity a) => [
  for (final r in a.agents) r.sessionId,
];

List<String> _entryIds(AgentActivity a) => [for (final e in a.recent) e.id];

/// A fresh temp dir standing in for a vault; deleted after the test.
Directory _tempVault() {
  final dir = Directory.systemTemp.createTempSync('om-453-vault-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

Directory _agentsDir(Directory vault) =>
    Directory(p.join(vault.path, '.memex', 'agents'))
      ..createSync(recursive: true);

void _writeFile(Directory dir, String name, String text) =>
    File(p.join(dir.path, name)).writeAsStringSync(text);

FakeVaultDb _track(FakeVaultDb db) {
  addTearDown(db.close);
  return db;
}

/// Insert one `agent_activity` row with every column given at run time.
void _seedEntry(
  Database db, {
  required String id,
  required int createdAt,
  String? sessionId,
  String? clientName,
  String? tool,
  String? summary,
  String? noteId,
}) {
  db.execute(
    'INSERT INTO agent_activity (id, session_id, client_name, tool, summary, '
    'note_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [
      id,
      sessionId ?? 'session-$id',
      clientName ?? 'client-$id',
      tool ?? 'tool-$id',
      summary ?? 'summary of $id',
      noteId,
      createdAt,
    ],
  );
}

/// Builds `<vault>/memex.db` from the app schema fixture (V7) on disk, so the
/// app can open it read-only like a real vault.
void _writeVaultDb(Directory vault, {void Function(Database db)? seed}) {
  final db = sqlite3.open(p.join(vault.path, 'memex.db'));
  try {
    db.execute(File(vaultSchemaV5FixturePath).readAsStringSync());
    seed?.call(db);
  } finally {
    db.dispose();
  }
}

/// Every entity under [root]: path → type, size, mtime and content.
Map<String, String> _snapshot(Directory root) {
  final out = <String, String>{};
  final rootStat = root.statSync();
  out['.'] = '${rootStat.type} ${rootStat.modified.microsecondsSinceEpoch}';
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: root.path);
    final s = FileStat.statSync(e.path);
    final content = e is File ? base64Encode(e.readAsBytesSync()) : '';
    out[rel] =
        '${s.type} ${s.size} ${s.modified.microsecondsSinceEpoch} $content';
  }
  return out;
}

void main() {
  group('activity agents', () {
    test(
      'activity with two valid records and one malformed one returns the two valid records by lastRequestAt descending',
      () async {
        final reader = _A2FakePresenceReader([
          _record('older', lastRequestAt: _t0 - 5000),
          '{"session_id": "broken", "client_name": 42}',
          _record('newer', lastRequestAt: _t0),
        ]);
        final access = LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          presence: reader,
        );

        final a = await access.activity();

        expect(_sessions(a), ['newer', 'older']);
        expect(reader.reads, 1);
      },
    );

    test('activity parses every presence field from the record text', () async {
      final started = DateTime.utc(2026, 11, 11, 9).millisecondsSinceEpoch;
      final text = jsonEncode({
        'session_id': '01JAGENTSESSION0000000000Q',
        'client_name': 'claude-desktop',
        'client_version': '0.9.1',
        'transport': 'bridge',
        'started_at': started,
        'last_seen_at': started + 5000,
        'last_request_at': started + 4000,
        'last_tool_at': started + 3000,
        'expires_at': started + 20000,
        'embeddings': true,
        'some_future_key': 'ignored',
      });
      final a = await LocalAgentsAccess(
        vaultPath: '/fake/om-453-vault',
        presence: _A2FakePresenceReader([text]),
      ).activity();

      expect(a.agents, hasLength(1));
      final r = a.agents.single;
      expect(r.sessionId, '01JAGENTSESSION0000000000Q');
      expect(r.clientName, 'claude-desktop');
      expect(r.clientVersion, '0.9.1');
      expect(r.transport, 'bridge');
      expect(r.startedAt, started);
      expect(r.lastSeenAt, started + 5000);
      expect(r.lastRequestAt, started + 4000);
      expect(r.lastToolAt, started + 3000);
      expect(r.expiresAt, started + 20000);
      expect(r.embeddings, isTrue);
    });

    test(
      'activity skips every kind of unreadable record and keeps the rest',
      () async {
        final reader = _A2FakePresenceReader([
          '',
          'not json at all',
          '{"session_id": "half-writ',
          'null',
          '[1, 2, 3]',
          '"a string"',
          '42',
          jsonEncode({'session_id': 'missing-everything'}),
          _record('ok-1', lastRequestAt: _t0 - 1),
          _record(
            'wrong-type',
            lastRequestAt: _t0,
            extra: {'embeddings': 'yes'},
          ),
          _record('ok-2', lastRequestAt: _t0 - 2),
        ]);

        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          presence: reader,
        ).activity();

        expect(_sessions(a), ['ok-1', 'ok-2']);
        expect(a.available, isTrue);
      },
    );

    test(
      'activity sorts several records by lastRequestAt descending whatever the read order',
      () async {
        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          presence: _A2FakePresenceReader([
            _record('b', lastRequestAt: 9),
            _record('d', lastRequestAt: 1000),
            _record('a', lastRequestAt: 10),
            _record('c', lastRequestAt: 999),
          ]),
        ).activity();

        expect(_sessions(a), ['d', 'c', 'a', 'b']);
      },
    );

    test(
      'activity returns expired records too, expired or not, sorted by lastRequestAt',
      () async {
        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          presence: _A2FakePresenceReader([
            _record('live', lastRequestAt: _t0, expiresAt: _t0 + 15000),
            _record('long-gone', lastRequestAt: 1000, expiresAt: 16000),
            _record(
              'http-expired',
              lastRequestAt: _t0 - 120000,
              expiresAt: _t0 - 60000,
              transport: 'http',
            ),
          ]),
        ).activity();

        expect(_sessions(a), ['live', 'http-expired', 'long-gone']);
        expect(a.agents.last.expiresAt, 16000);
      },
    );

    test('activity reads the presence records again on every call', () async {
      final reader = _A2FakePresenceReader([
        _record('first', lastRequestAt: _t0),
      ]);
      final access = LocalAgentsAccess(
        vaultPath: '/fake/om-453-vault',
        presence: reader,
      );

      expect(_sessions(await access.activity()), ['first']);
      reader.records = [_record('second', lastRequestAt: _t0 + 1)];
      expect(_sessions(await access.activity()), ['second']);
      reader.records = [];
      expect(_sessions(await access.activity()), isEmpty);
      expect(reader.reads, 3);
    });

    test(
      'activity without a presence argument reads the presence files of vaultPath',
      () async {
        final vault = _tempVault();
        _writeFile(
          _agentsDir(vault),
          'default-reader.json',
          _record('default-reader', lastRequestAt: _t0),
        );

        final a = await LocalAgentsAccess(vaultPath: vault.path).activity();

        expect(_sessions(a), ['default-reader']);
      },
    );

    test(
      'LocalVaultAccess agents reads the presence files and memex.db of its vault',
      () async {
        final vault = _tempVault();
        _writeFile(
          _agentsDir(vault),
          's1.json',
          _record('s1', lastRequestAt: _t0),
        );
        final db = _track(FakeVaultDb());
        _seedEntry(db.db, id: 'E1', createdAt: _t0);

        final a = await LocalVaultAccess(
          vaultPath: vault.path,
          db: db,
        ).agents.activity();

        expect(_sessions(a), ['s1']);
        expect(_entryIds(a), ['E1']);
      },
    );

    testWidgets(
      'activity on a temp vault completes inside testWidgets without runAsync',
      (tester) async {
        final vault = _tempVault();
        _writeFile(
          _agentsDir(vault),
          'sync.json',
          _record('sync', lastRequestAt: _t0),
        );
        final db = _track(FakeVaultDb());
        _seedEntry(db.db, id: 'S1', createdAt: _t0);
        final access = LocalAgentsAccess(vaultPath: vault.path, db: db);

        AgentActivity? got;
        // ignore: unawaited_futures
        access.activity().then((a) => got = a);
        await tester.pump();

        expect(got, isNotNull, reason: 'activity() must need no real IO');
        expect(_sessions(got!), ['sync']);
        expect(_entryIds(got!), ['S1']);
      },
    );
  });

  group('FilePresenceReader', () {
    test(
      'FilePresenceReader returns the text of each json file in .memex/agents and ignores x.json.tmp and notes.txt',
      () {
        final vault = _tempVault();
        final dir = _agentsDir(vault);
        final a = _record('a', lastRequestAt: _t0);
        final b = _record('b', lastRequestAt: _t0 + 1);
        _writeFile(dir, 'a.json', a);
        _writeFile(dir, 'b.json', b);
        _writeFile(dir, 'x.json.tmp', _record('x', lastRequestAt: _t0 + 2));
        _writeFile(dir, 'notes.txt', 'not a record');

        expect(
          FilePresenceReader(vault.path).readAll(),
          unorderedEquals([a, b]),
        );
      },
    );

    test(
      'FilePresenceReader returns an empty list when .memex/agents does not exist and reads it once it does',
      () {
        final vault = _tempVault();
        final reader = FilePresenceReader(vault.path);
        expect(reader.readAll(), isEmpty);

        Directory(p.join(vault.path, '.memex')).createSync();
        expect(FilePresenceReader(vault.path).readAll(), isEmpty);

        final gone = p.join(vault.path, 'no-such-vault');
        expect(FilePresenceReader(gone).readAll(), isEmpty);
        expect(
          Directory(p.join(vault.path, '.memex', 'agents')).existsSync(),
          isFalse,
        );
        expect(Directory(gone).existsSync(), isFalse);

        // The same reader sees the directory once a server creates it.
        final later = _record('later', lastRequestAt: _t0);
        _writeFile(_agentsDir(vault), 'later.json', later);
        expect(reader.readAll(), [later]);
      },
    );

    test(
      'FilePresenceReader returns an empty list when .memex/agents cannot be listed',
      () {
        final vault = _tempVault();
        final dir = _agentsDir(vault);
        final a = _record('a', lastRequestAt: _t0);
        _writeFile(dir, 'a.json', a);
        // Positive control: the record is read while the directory is open,
        // so the empty list below comes from the denial, not from the reader.
        expect(FilePresenceReader(vault.path).readAll(), [a]);
        Process.runSync('chmod', ['000', dir.path]);
        addTearDown(() => Process.runSync('chmod', ['755', dir.path]));

        expect(FilePresenceReader(vault.path).readAll(), isEmpty);
      },
    );

    test(
      'FilePresenceReader returns the texts in file path order whatever the listing order',
      () {
        final vault = _tempVault();
        final dir = _agentsDir(vault);
        // Written in reverse so a listing in creation or hash order differs
        // from path order; two of the records tie on lastRequestAt.
        final names = ['f', 'e', 'd', 'c', 'b', 'a'];
        final texts = {
          for (final n in names) n: _record(n, lastRequestAt: _t0),
        };
        for (final n in names) {
          _writeFile(dir, '$n.json', texts[n]!);
        }

        expect(FilePresenceReader(vault.path).readAll(), [
          for (final n in names.reversed) texts[n]!,
        ]);
      },
    );

    test(
      'FilePresenceReader returns the text of a malformed json file unparsed',
      () {
        final vault = _tempVault();
        final dir = _agentsDir(vault);
        _writeFile(dir, 'broken.json', '{"session_id": "half-writ');
        final ok = _record('ok', lastRequestAt: _t0);
        _writeFile(dir, 'ok.json', ok);

        expect(
          FilePresenceReader(vault.path).readAll(),
          unorderedEquals(['{"session_id": "half-writ', ok]),
        );
      },
    );

    test(
      'FilePresenceReader skips a json entry it cannot read and returns the others',
      () {
        final vault = _tempVault();
        final dir = _agentsDir(vault);
        final ok = _record('ok', lastRequestAt: _t0);
        _writeFile(dir, 'ok.json', ok);
        // A directory named like a record.
        Directory(p.join(dir.path, 'subdir.json')).createSync();
        // A record deleted between the listing and the read (a dangling link).
        Link(
          p.join(dir.path, 'gone.json'),
        ).createSync(p.join(dir.path, 'deleted-target.json'));
        // Bytes that are not UTF-8.
        File(
          p.join(dir.path, 'binary.json'),
        ).writeAsBytesSync([0xff, 0xfe, 0xc3, 0x28]);
        // A file without read permission.
        final locked = File(p.join(dir.path, 'locked.json'))
          ..writeAsStringSync(_record('locked', lastRequestAt: _t0));
        Process.runSync('chmod', ['000', locked.path]);
        addTearDown(() => Process.runSync('chmod', ['644', locked.path]));

        expect(FilePresenceReader(vault.path).readAll(), [ok]);
      },
    );

    test(
      'FilePresenceReader on a vault of presence files feeds activity with tmp and txt files ignored',
      () async {
        final vault = _tempVault();
        final dir = _agentsDir(vault);
        _writeFile(dir, 'old.json', _record('old', lastRequestAt: _t0 - 9000));
        _writeFile(dir, 'new.json', _record('new', lastRequestAt: _t0));
        _writeFile(
          dir,
          'pending.json.tmp',
          _record('pending', lastRequestAt: _t0 + 9000),
        );
        _writeFile(dir, 'notes.txt', _record('txt', lastRequestAt: _t0 + 8000));
        _writeFile(dir, 'bad.json', '{"session_id": 7}');

        final a = await LocalAgentsAccess(
          vaultPath: vault.path,
          presence: FilePresenceReader(vault.path),
        ).activity();

        expect(_sessions(a), ['new', 'old']);
      },
    );
  });

  group('activity recent', () {
    test(
      'activity on the V7 fixture with 25 agent_activity rows returns the newest 20 newest first with every field mapped',
      () async {
        final db = _track(FakeVaultDb());
        // Scrambled insert order; row i has created_at _t0 + i s.
        for (var k = 0; k < 25; k++) {
          final i = (k * 11) % 25;
          final id = 'E${i.toString().padLeft(2, '0')}';
          _seedEntry(
            db.db,
            id: id,
            createdAt: _t0 + i * 1000,
            sessionId: 'session-${i % 3}',
            clientName: i.isEven ? 'claude-code' : 'claude-desktop',
            tool: 'tool_$i',
            summary: 'summary $i',
            // Odd rows have no note.
            noteId: i.isEven ? 'note-$i' : null,
          );
        }

        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          db: db,
          presence: _A2FakePresenceReader(),
        ).activity();

        expect(_entryIds(a), [
          for (var i = 24; i >= 5; i--) 'E${i.toString().padLeft(2, '0')}',
        ]);
        for (final e in a.recent) {
          final i = int.parse(e.id.substring(1));
          expect(e.sessionId, 'session-${i % 3}');
          expect(e.clientName, i.isEven ? 'claude-code' : 'claude-desktop');
          expect(e.tool, 'tool_$i');
          expect(e.summary, 'summary $i');
          expect(e.noteId, i.isEven ? 'note-$i' : isNull);
          expect(e.createdAt, _t0 + i * 1000);
        }
        expect(a.available, isTrue);
        expect(a.serverNow, isNull);
      },
    );

    test(
      'activity orders recent by created_at descending then id descending',
      () async {
        final db = _track(FakeVaultDb());
        _seedEntry(db.db, id: '01JB', createdAt: _t0);
        _seedEntry(db.db, id: '01JC', createdAt: _t0);
        _seedEntry(db.db, id: '01JZ', createdAt: _t0 - 1);
        _seedEntry(db.db, id: '01JA', createdAt: _t0);

        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          db: db,
          presence: _A2FakePresenceReader(),
        ).activity();

        expect(_entryIds(a), ['01JC', '01JB', '01JA', '01JZ']);
      },
    );

    test(
      'activity on a V6 vault without agent_activity returns an empty recent and available true',
      () async {
        final db = _track(FakeVaultDb.v6Only());
        expect(db.hasTables(const ['agent_activity']), isFalse);

        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          db: db,
          presence: _A2FakePresenceReader([
            _record('v6-agent', lastRequestAt: _t0),
          ]),
        ).activity();

        expect(a.recent, isEmpty);
        expect(a.available, isTrue);
        expect(a.serverNow, isNull);
        expect(_sessions(a), ['v6-agent']);
      },
    );

    test(
      'activity on a V5 or V4 vault returns an empty recent and the presence records',
      () async {
        for (final db in [FakeVaultDb.v5Only(), FakeVaultDb.v4()]) {
          _track(db);
          final a = await LocalAgentsAccess(
            vaultPath: '/fake/om-453-vault',
            db: db,
            presence: _A2FakePresenceReader([
              _record('old-vault-agent', lastRequestAt: _t0),
            ]),
          ).activity();

          expect(a.recent, isEmpty);
          expect(a.available, isTrue);
          expect(_sessions(a), ['old-vault-agent']);
        }
      },
    );

    test(
      'activity sees agent_activity rows once the CLI migrates the open V6 handle to V7',
      () async {
        final db = _track(FakeVaultDb.v6Only());
        final access = LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          db: db,
          presence: _A2FakePresenceReader(),
        );
        expect((await access.activity()).recent, isEmpty);

        db.migrateToV6(); // replays the V7 fixture on the same handle
        _seedEntry(db.db, id: 'AFTER', createdAt: _t0);

        expect(_entryIds(await access.activity()), ['AFTER']);
      },
    );

    test(
      'activity with no db returns an empty recent and available true',
      () async {
        final a = await LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          presence: _A2FakePresenceReader([
            _record('no-db-agent', lastRequestAt: _t0),
          ]),
        ).activity();

        expect(a.recent, isEmpty);
        expect(a.available, isTrue);
        expect(a.serverNow, isNull);
        expect(_sessions(a), ['no-db-agent']);
      },
    );

    test(
      'activity throws when the agent_activity read fails on a locked database',
      () async {
        final vault = _tempVault();
        _writeVaultDb(
          vault,
          seed: (db) => _seedEntry(db, id: 'L1', createdAt: _t0),
        );
        final reader = VaultDb.open(vault.path);
        addTearDown(reader.close);
        // Another connection (the server) holds an exclusive lock.
        final writer = sqlite3.open(p.join(vault.path, 'memex.db'));
        writer.execute('BEGIN EXCLUSIVE');
        addTearDown(() {
          writer.execute('ROLLBACK');
          writer.dispose();
        });

        final access = LocalAgentsAccess(
          vaultPath: vault.path,
          db: reader,
          presence: _A2FakePresenceReader([
            _record('still-here', lastRequestAt: _t0),
          ]),
        );

        await expectLater(access.activity(), throwsA(isA<SqliteException>()));
      },
    );

    test(
      'activity throws when agent_activity exists but cannot be read',
      () async {
        final db = _track(FakeVaultDb());
        db.db.execute('DROP TABLE agent_activity');
        db.db.execute(
          'CREATE TABLE agent_activity (id TEXT PRIMARY KEY, created_at INTEGER)',
        );
        db.db.execute(
          "INSERT INTO agent_activity (id, created_at) VALUES ('R1', 1)",
        );

        final access = LocalAgentsAccess(
          vaultPath: '/fake/om-453-vault',
          db: db,
          presence: _A2FakePresenceReader([
            _record('still-here', lastRequestAt: _t0),
          ]),
        );

        await expectLater(access.activity(), throwsA(anything));
      },
    );
  });

  group('read-only', () {
    test(
      'activity creates modifies and deletes no file under the vault',
      () async {
        final vault = _tempVault();
        _writeVaultDb(
          vault,
          seed: (db) {
            for (var i = 0; i < 3; i++) {
              _seedEntry(db, id: 'W$i', createdAt: _t0 + i);
            }
          },
        );
        final dir = _agentsDir(vault);
        _writeFile(dir, 'live.json', _record('live', lastRequestAt: _t0));
        _writeFile(
          dir,
          'expired.json',
          _record('expired', lastRequestAt: 1000, expiresAt: 16000),
        );
        _writeFile(dir, 'bad.json', '{"session_id": ');
        _writeFile(
          dir,
          'pending.json.tmp',
          _record('pending', lastRequestAt: _t0),
        );
        _writeFile(dir, 'notes.txt', 'hello');
        final db = VaultDb.open(vault.path);
        addTearDown(db.close);
        final access = LocalAgentsAccess(vaultPath: vault.path, db: db);
        final before = _snapshot(vault);

        final first = await access.activity();
        final second = await access.activity();

        expect(_sessions(first), ['live', 'expired']);
        expect(_entryIds(first), ['W2', 'W1', 'W0']);
        expect(_sessions(second), ['live', 'expired']);
        expect(_snapshot(vault), before);
      },
    );

    test(
      'activity on a vault without .memex creates no presence directory',
      () async {
        final vault = _tempVault();
        _writeVaultDb(vault);
        final db = VaultDb.open(vault.path);
        addTearDown(db.close);
        final before = _snapshot(vault);

        final a = await LocalAgentsAccess(
          vaultPath: vault.path,
          db: db,
        ).activity();

        expect(a.agents, isEmpty);
        expect(a.recent, isEmpty);
        expect(a.available, isTrue);
        expect(Directory(p.join(vault.path, '.memex')).existsSync(), isFalse);
        expect(_snapshot(vault), before);
      },
    );
  });
}
