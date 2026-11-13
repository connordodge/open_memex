// WI #13 (Spec #7 A1): the gate, reads and writes of agent note edits.
//
// D17 `agentEditsAvailableProvider`: hosted, the vault's `/info` reports
// `schema_version >= 8`; local, `vaultV8ReadyProvider` (the V8 column AND
// table). It re-reads on every `vaultRevisionProvider` bump; loading and
// errors read false (fail closed) and are never latched.
// `noteRevisionsProvider` follows the gate and calls no route while it is
// false (Req 36: an older server never sees the new routes).
//
// D18 `noteEditsActionsProvider`: a toggle is one access call and exactly
// one bump on success, none on failure, no optimistic state (the re-read
// note carries the flag). A restore flushes the edit waiting on the save
// debounce (`flushThenWrite`, no `holdSaves`), makes one restore call, then
// bumps exactly once.
//
// The editor never reloads its text when the vault revision moves but the
// open note's version is unchanged (a toggle on that note).
//
// Everything runs on FakeVaultDb (the V8 dump), FakeMemexCli and
// FakeVaultServer; time moves only through the FakeClock.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/note_edits_state.dart';
import 'package:open_memex_app/src/state/today_state.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/agent_edits_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/fake_vault_server.dart';
import '../support/today_cli_fakes.dart';

const _wi13Note = '01JNOTEEDITSSTATE000000013';
const _wi13Title = 'Pricing notes';
const _wi13Body = 'Pricing, as the agent left it.';
const _wi13Previous = 'Pricing, before the agent.';
const _wi13Typed = 'Pricing, as the agent left it. Plus my own line.';
const _wi13Start = 3;

const _wi13HostedVault = 'seed';
const _wi13HostedBase = '/vaults/seed/api/v1';
const _wi13HostedRef = HostedVaultRef(fakeServerId, _wi13HostedVault);

// ------------------------------------------------------------------ local

class _Wi13Local {
  _Wi13Local(this.c, this.db, this.cli, this.clock);
  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  /// `vaultRevisionProvider` changes since [startCounting].
  int bumps = 0;

  /// Every event in order: `bump` and the CLI subcommands as they run.
  final List<String> events = [];

  void startCounting() {
    c.listen<int>(vaultRevisionProvider, (_, _) {
      bumps++;
      events.add('bump');
    });
  }

  EditorController get editor => c.read(editorControllerProvider.notifier);
  EditorStateValue get state => c.read(editorControllerProvider);
  NoteEditsActions get actions => c.read(noteEditsActionsProvider);
  Note get stored => db.getNote(_wi13Note)!;
}

/// A local vault in a temp folder (removed after the test) over [db] (a
/// fresh V8 vault holding [_wi13Note] by default), a FakeMemexCli with the
/// agent-edit and `update` handlers, and a FakeClock.
_Wi13Local _wi13LocalEnv({FakeVaultDb? db, bool seed = true}) {
  final dir = Directory.systemTemp.createTempSync('om13_note_edits');
  final vault = db ?? FakeVaultDb.v5();
  if (seed) {
    vault.seedNote(
      id: _wi13Note,
      title: _wi13Title,
      content: _wi13Body,
      role: 'topic',
      version: _wi13Start,
    );
  }
  final cli = FakeMemexCli()
    ..onAgentEdits(vault)
    ..onUpdateWrites(vault);
  final clock = FakeClock();
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(vault),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
    ],
  );
  addTearDown(() {
    c.dispose();
    vault.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return _Wi13Local(c, vault, cli, clock);
}

// ----------------------------------------------------------------- hosted

class _Wi13Hosted {
  _Wi13Hosted(this.c, this.server);
  final ProviderContainer c;
  final FakeVaultServer server;

  int bumps = 0;

  void bump() => c.read(vaultRevisionProvider.notifier).state++;

  void info(int schemaVersion) => server.route(
    'GET',
    '$_wi13HostedBase/info',
    json: {
      'server_version': '0.4.0',
      'api_version': 1,
      'schema_version': schemaVersion,
    },
  );

  void infoFails() => server.route(
    'GET',
    '$_wi13HostedBase/info',
    status: 500,
    json: {
      'error': {'code': 'internal', 'message': 'disk on fire'},
    },
  );

  List<String> get paths => [for (final r in server.requests) r.url.path];

  int get infoReads => paths.where((p) => p == '$_wi13HostedBase/info').length;
}

/// A hosted vault `seed` on a FakeVaultServer: `vaultAccessProvider` is a
/// `HostedVaultAccess` over the fake's client. [schemaVersion] (when given)
/// is what `/info` reports.
_Wi13Hosted _wi13HostedEnv({int? schemaVersion}) {
  final server = FakeVaultServer();
  late final HostedClient client;
  final c = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(FakeClock()),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
      currentVaultProvider.overrideWith((_) => _wi13HostedRef),
      vaultAccessProvider.overrideWith(
        (ref) => HostedVaultAccess(client: client, vaultName: _wi13HostedVault),
      ),
    ],
  );
  client = server.connect(c);
  addTearDown(c.dispose);
  final env = _Wi13Hosted(c, server);
  if (schemaVersion != null) env.info(schemaVersion);
  c.listen<int>(vaultRevisionProvider, (_, _) => env.bumps++);
  return env;
}

/// Subscribes to [provider] (kept until the container is disposed), lets
/// queued async work finish, and returns its value.
Future<T> _wi13Settled<T>(ProviderContainer c, ProviderListenable<T> p) async {
  final sub = c.listen<T>(p, (_, _) {});
  await pumpEventQueue();
  return sub.read();
}

Future<Note?> _wi13EditorNote(ProviderContainer c) async {
  final v = await _wi13Settled<AsyncValue<VaultScoped<Note?>>>(
    c,
    editorNoteAsyncProvider,
  );
  return v.valueOrNull?.value;
}

/// [future]'s value or the error it threw.
Future<Object?> _wi13Outcome(Future<Object?> future) async {
  try {
    return await future;
  } catch (e) {
    return e;
  }
}

void main() {
  group('D17 gate: agentEditsAvailableProvider', () {
    test(
      'agentEditsAvailableProvider is true for a hosted vault whose info reports 8 or more and false for 7',
      () async {
        for (final (version, want) in [
          (6, false),
          (7, false),
          (8, true),
          (9, true),
        ]) {
          final env = _wi13HostedEnv(schemaVersion: version);
          expect(
            await _wi13Settled(env.c, agentEditsAvailableProvider),
            want,
            reason: 'schema_version $version',
          );
          expect(env.infoReads, 1, reason: 'schema_version $version');
        }
      },
    );

    test(
      'agentEditsAvailableProvider is false while hosted info loads and true once it reports 8',
      () async {
        final env = _wi13HostedEnv(schemaVersion: 8);
        env.server.hold();
        final sub = env.c.listen<bool>(agentEditsAvailableProvider, (_, _) {});
        expect(sub.read(), isFalse);
        await pumpEventQueue();
        expect(sub.read(), isFalse, reason: 'the info read is still held');
        env.server.release();
        await pumpEventQueue();
        expect(sub.read(), isTrue);
      },
    );

    test(
      'agentEditsAvailableProvider is false after a failed info read and reads again on the next bump',
      () async {
        final env = _wi13HostedEnv();
        env.infoFails();
        final sub = env.c.listen<bool>(agentEditsAvailableProvider, (_, _) {});
        await pumpEventQueue();
        expect(sub.read(), isFalse, reason: 'first read failed');

        env.info(8);
        env.bump();
        await pumpEventQueue();
        expect(sub.read(), isTrue, reason: 'not latched on the failure');

        // An error after a good reading hides the controls again.
        env.infoFails();
        env.bump();
        await pumpEventQueue();
        expect(sub.read(), isFalse, reason: 'error after success');

        env.info(8);
        env.bump();
        await pumpEventQueue();
        expect(sub.read(), isTrue);
        expect(env.infoReads, 4);
      },
    );

    test(
      'agentEditsAvailableProvider re-reads hosted info once per vault revision bump',
      () async {
        final env = _wi13HostedEnv(schemaVersion: 7);
        final sub = env.c.listen<bool>(agentEditsAvailableProvider, (_, _) {});
        await pumpEventQueue();
        expect(sub.read(), isFalse);
        expect(env.infoReads, 1);

        // The server is upgraded to V8 while the app stays connected.
        env.info(8);
        await pumpEventQueue();
        expect(sub.read(), isFalse, reason: 'no bump, no re-read');
        expect(env.infoReads, 1);

        env.bump();
        await pumpEventQueue();
        expect(sub.read(), isTrue);
        expect(env.infoReads, 2);
      },
    );

    test(
      'agentEditsAvailableProvider is true for a local vault at V8 and re-evaluates after a vault revision bump',
      () async {
        final v8 = _wi13LocalEnv();
        expect(await _wi13Settled(v8.c, agentEditsAvailableProvider), isTrue);

        final env = _wi13LocalEnv(db: agentEditsV7Vault());
        final sub = env.c.listen<bool>(agentEditsAvailableProvider, (_, _) {});
        await pumpEventQueue();
        expect(sub.read(), isFalse, reason: 'V7');

        // The bundled memex migrates the vault while the app's handle stays
        // open; the next bump re-probes.
        env.db.migrateAgentEditsToV8();
        env.c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();
        expect(sub.read(), isTrue, reason: 'V8 after the bump');
      },
    );

    test('agentEditsAvailableProvider is false with no vault open', () async {
      final c = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FakeClock()),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      expect(await _wi13Settled(c, agentEditsAvailableProvider), isFalse);
    });
  });

  group('vaultV8ReadyProvider', () {
    test(
      'vaultV8ReadyProvider needs both the agent_read_only column and note_revisions',
      () async {
        final v8 = _wi13LocalEnv();
        expect(await _wi13Settled(v8.c, vaultV8ReadyProvider), isTrue);

        final v7 = _wi13LocalEnv(db: agentEditsV7Vault());
        expect(await _wi13Settled(v7.c, vaultV8ReadyProvider), isFalse);

        // Column only.
        final columnOnly = agentEditsV7Vault();
        columnOnly.db.execute(
          'ALTER TABLE notes ADD COLUMN agent_read_only INTEGER NOT NULL '
          'DEFAULT 0',
        );
        final col = _wi13LocalEnv(db: columnOnly);
        expect(await _wi13Settled(col.c, vaultV8ReadyProvider), isFalse);

        // Table only.
        final tableOnly = agentEditsV7Vault()..migrateToV6();
        expect(tableOnly.hasTables(const ['note_revisions']), isTrue);
        expect(
          tableOnly.hasColumns('notes', const ['agent_read_only']),
          isFalse,
        );
        final tab = _wi13LocalEnv(db: tableOnly);
        expect(await _wi13Settled(tab.c, vaultV8ReadyProvider), isFalse);
      },
    );

    test(
      'vaultV8ReadyProvider is false with no database and for a hosted vault',
      () async {
        final dir = Directory.systemTemp.createTempSync('om13_v8_nodb');
        addTearDown(() => dir.deleteSync(recursive: true));
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            clockProvider.overrideWithValue(FakeClock()),
          ],
        );
        addTearDown(c.dispose);
        expect(await _wi13Settled(c, vaultV8ReadyProvider), isFalse);

        final hosted = _wi13HostedEnv(schemaVersion: 8);
        expect(await _wi13Settled(hosted.c, vaultV8ReadyProvider), isFalse);
      },
    );
  });

  group('noteRevisionsProvider', () {
    test(
      'noteRevisionsProvider lists a local note revisions newest first and re-reads on a bump',
      () async {
        final env = _wi13LocalEnv();
        env.db
          ..seedNoteRevision(
            id: 'rev-1',
            noteId: _wi13Note,
            agentChangeId: 'chg-1',
            newVersion: 2,
            createdAt: 1759500000000,
          )
          ..seedNoteRevision(
            id: 'rev-2',
            noteId: _wi13Note,
            agentChangeId: 'chg-2',
            previousVersion: 2,
            newVersion: 3,
            createdAt: 1759500100000,
          );
        final first = await _wi13Settled(
          env.c,
          noteRevisionsProvider(_wi13Note),
        );
        expect(first.value?.vault, env.c.read(currentVaultProvider));
        expect([for (final r in first.value!.value) r.id], ['rev-2', 'rev-1']);

        env.db.seedNoteRevision(
          id: 'rev-3',
          noteId: _wi13Note,
          previousVersion: 3,
          newVersion: 4,
          createdAt: 1759500200000,
        );
        env.c.read(vaultRevisionProvider.notifier).state++;
        final next = await _wi13Settled(
          env.c,
          noteRevisionsProvider(_wi13Note),
        );
        expect(
          [for (final r in next.value!.value) r.id],
          ['rev-3', 'rev-2', 'rev-1'],
        );
      },
    );

    test(
      'noteRevisionsProvider on a hosted vault reads the revisions route only at schema 8',
      () async {
        final old = _wi13HostedEnv(schemaVersion: 7);
        final none = await _wi13Settled(
          old.c,
          noteRevisionsProvider(_wi13Note),
        );
        expect(none.value?.value, isEmpty);
        expect(
          old.paths.where((p) => p.endsWith('/revisions')),
          isEmpty,
          reason: 'an older server never sees the new route',
        );

        final env = _wi13HostedEnv(schemaVersion: 8);
        env.server.route(
          'GET',
          '$_wi13HostedBase/notes/$_wi13Note/revisions',
          json: {
            'vault_id': '01HV0000000000000000000013',
            'revisions': [
              {'id': 'rev-h', 'agent_change_id': 'chg-h', 'created_at': 5},
            ],
          },
        );
        final rows = await _wi13Settled(
          env.c,
          noteRevisionsProvider(_wi13Note),
        );
        expect([for (final r in rows.value!.value) r.id], ['rev-h']);
        expect(rows.value!.vault, _wi13HostedRef);
      },
    );
  });

  group('D18 toggle', () {
    test(
      'a successful toggle bumps vaultRevisionProvider exactly once and the re-read note reports the new flag',
      () async {
        final env = _wi13LocalEnv();
        env.c.read(selectedNoteIdProvider.notifier).state = _wi13Note;
        expect((await _wi13EditorNote(env.c))!.agentReadOnly, isFalse);
        env.startCounting();

        await env.actions.setAgentReadOnly(_wi13Note, true);
        expect(env.bumps, 1);
        expect(env.cli.callsFor('read-only set'), hasLength(1));
        expect(
          env.cli.callsFor('read-only set').single.flag('note-id'),
          _wi13Note,
        );
        expect(env.cli.callsFor('read-only clear'), isEmpty);
        expect((await _wi13EditorNote(env.c))!.agentReadOnly, isTrue);

        await env.actions.setAgentReadOnly(_wi13Note, false);
        expect(env.bumps, 2);
        expect(env.cli.callsFor('read-only set'), hasLength(1));
        expect(env.cli.callsFor('read-only clear'), hasLength(1));
        expect((await _wi13EditorNote(env.c))!.agentReadOnly, isFalse);
      },
    );

    test(
      'a failed toggle bumps vaultRevisionProvider zero times and rethrows the MemexException',
      () async {
        final env = _wi13LocalEnv();
        env.cli.on(
          'read-only set',
          (_) => FakeMemexCli.error(
            'role_rule',
            'a daily note cannot be read-only for agents',
          ),
        );
        env.startCounting();
        final e = await _wi13Outcome(
          env.actions.setAgentReadOnly(_wi13Note, true),
        );
        expect(e, isA<MemexException>());
        expect((e as MemexException).code, 'role_rule');
        expect(
          e.message,
          contains('a daily note cannot be read-only for agents'),
        );
        expect(env.bumps, 0);
        expect(env.cli.callsFor('read-only set'), hasLength(1));
        expect(env.db.agentReadOnlyForTest(_wi13Note), isFalse);
      },
    );

    test('a toggle with no vault open throws and bumps nothing', () async {
      final c = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FakeClock()),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      var bumps = 0;
      c.listen<int>(vaultRevisionProvider, (_, _) => bumps++);
      final e = await _wi13Outcome(
        c.read(noteEditsActionsProvider).setAgentReadOnly(_wi13Note, true),
      );
      expect(e, isNotNull);
      expect(bumps, 0);
    });

    test(
      'a hosted toggle sends one PUT and bumps once and a refused one bumps nothing',
      () async {
        final env = _wi13HostedEnv(schemaVersion: 8);
        env.server.route(
          'PUT',
          '$_wi13HostedBase/notes/$_wi13Note/agent-read-only',
          json: {
            'vault_id': '01HV0000000000000000000013',
            'note_id': _wi13Note,
            'agent_read_only': true,
          },
        );
        await env.c
            .read(noteEditsActionsProvider)
            .setAgentReadOnly(_wi13Note, true);
        final puts = [
          for (final r in env.server.requests)
            if (r.method == 'PUT') r,
        ];
        expect(puts, hasLength(1));
        expect(jsonDecode(puts.single.body), {'agent_read_only': true});
        expect(env.bumps, 1);

        env.server.route(
          'PUT',
          '$_wi13HostedBase/notes/$_wi13Note/agent-read-only',
          status: 422,
          json: {
            'error': {'code': 'role_rule', 'message': 'daily note'},
          },
        );
        final e = await _wi13Outcome(
          env.c
              .read(noteEditsActionsProvider)
              .setAgentReadOnly(_wi13Note, true),
        );
        expect((e as MemexException).code, 'role_rule');
        expect(env.bumps, 1);
      },
    );
  });

  group('D18 restore', () {
    test(
      'a successful restore flushes pending saves first then bumps vaultRevisionProvider exactly once',
      () async {
        final env = _wi13LocalEnv();
        env.db.seedNoteRevision(
          id: 'rev-1',
          noteId: _wi13Note,
          agentChangeId: 'chg-1',
          previousMd: _wi13Previous,
          previousVersion: 2,
          newVersion: _wi13Start,
        );
        var bumpsAtRestore = -1;
        env.cli.on('revisions restore', (call) {
          env.events.add('revisions restore');
          bumpsAtRestore = env.bumps;
          final next = env.stored.version + 1;
          env.db.db.execute(
            'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
            [_wi13Previous, next, _wi13Note],
          );
          return FakeMemexCli.ok(
            jsonEncode({
              'vault_id': agentEditsVaultId,
              'note_id': _wi13Note,
              'version': next,
              'content_md': _wi13Previous,
            }),
          );
        });
        env.editor.loadNote(env.stored);
        env.editor.onContentChanged(_wi13Typed);
        env.startCounting();

        await env.actions.restoreNoteRevision(
          note: env.stored,
          revisionId: 'rev-1',
        );

        final subcommands = [for (final c in env.cli.calls) c.subcommand];
        expect(
          subcommands.where((s) => s == 'update' || s == 'revisions restore'),
          ['update', 'revisions restore'],
          reason: 'the pending edit is stored before the restore',
        );
        expect(env.cli.callsFor('update').single.stdinBody, _wi13Typed);
        expect(env.cli.callsFor('revisions restore'), hasLength(1));
        expect(
          env.cli.callsFor('revisions restore').single.flag('revision-id'),
          'rev-1',
        );
        expect(bumpsAtRestore, greaterThanOrEqualTo(0));
        expect(
          env.bumps - bumpsAtRestore,
          1,
          reason: 'one bump for the restore',
        );
        expect(env.stored.contentMd, _wi13Previous);
      },
    );

    test(
      'a restore of a clean open note makes one call and bumps vaultRevisionProvider exactly once',
      () async {
        final env = _wi13LocalEnv();
        env.db.seedNoteRevision(
          id: 'rev-1',
          noteId: _wi13Note,
          previousMd: _wi13Previous,
          previousVersion: 2,
          newVersion: _wi13Start,
        );
        env.editor.loadNote(env.stored);
        env.startCounting();

        await env.actions.restoreNoteRevision(
          note: env.stored,
          revisionId: 'rev-1',
        );

        expect(env.cli.callsFor('update'), isEmpty);
        expect(env.cli.callsFor('revisions restore'), hasLength(1));
        expect(env.bumps, 1);
        // flushThenWrite rebases the editor on the restored note.
        expect(env.state.contentMd, _wi13Previous);
        expect(env.state.lastSavedVersion, _wi13Start + 1);
      },
    );

    test('a restore whose flush fails restores nothing', () async {
      final env = _wi13LocalEnv();
      env.db.seedNoteRevision(id: 'rev-1', noteId: _wi13Note);
      env.cli.on('update', (_) => FakeMemexCli.error('internal', 'disk full'));
      env.editor.loadNote(env.stored);
      env.editor.onContentChanged(_wi13Typed);

      final e = await _wi13Outcome(
        env.actions.restoreNoteRevision(note: env.stored, revisionId: 'rev-1'),
      );
      expect(e, isA<SaveFirstFailedException>());
      expect(env.cli.callsFor('revisions restore'), isEmpty);
      expect(env.stored.contentMd, _wi13Body);
    });
  });

  group('editor reload', () {
    test(
      'a toggle on the open note keeps the editor text and base version while the vault revision moves',
      () async {
        final env = _wi13LocalEnv();
        env.c.read(selectedNoteIdProvider.notifier).state = _wi13Note;
        final opened = (await _wi13EditorNote(env.c))!;
        env.editor.loadNote(opened);
        env.editor.onContentChanged(_wi13Typed);
        env.startCounting();

        await env.actions.setAgentReadOnly(_wi13Note, true);
        expect(env.bumps, 1);

        // The re-read note carries the flag on the same version.
        final reread = (await _wi13EditorNote(env.c))!;
        expect(reread.agentReadOnly, isTrue);
        expect(reread.version, _wi13Start);

        // The revision poller's path: an unchanged version is no server
        // change, so the typed text stays.
        expect(await env.editor.serverChanged(_wi13Note), isFalse);
        expect(env.state.contentMd, _wi13Typed);
        expect(env.state.lastSavedVersion, _wi13Start);
        expect(env.state.status, SaveStatus.dirty);
        expect(env.cli.callsFor('update'), isEmpty);
      },
    );
  });
}
