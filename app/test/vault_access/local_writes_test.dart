// WI #70 (W0a) AC2, AC3: every local write sends today's argv and stdin and
// returns today's result; a failing write throws today's MemexException.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/folder_cli.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/notes_access.dart';
import 'package:open_memex_app/src/vault_access/topics_access.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_access_shapes.dart';
import '../support/vault_access_writes.dart';

const _vault = '/tmp/om-70-vault';

/// Runs [c] through today's wrapper and through a LocalVaultAccess, each on
/// its own sample CLI; returns both CLIs and both results (or exceptions).
Future<
  ({FakeMemexCli today, FakeMemexCli local, Object? todayOut, Object? localOut})
>
_runBoth(
  VaultAccessWriteCase c, {
  void Function(FakeMemexCli cli)? script,
}) async {
  final today = vaultAccessSampleCli();
  final local = vaultAccessSampleCli();
  script?.call(today);
  script?.call(local);
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  final access = LocalVaultAccess(vaultPath: _vault, db: db, cli: local);

  Future<Object?> capture(Future<Object?> Function() f) async {
    try {
      return await f();
    } catch (e) {
      // Exceptions and parse Errors (TypeError) alike: compare what escapes.
      return e;
    }
  }

  final todayOut = await capture(() => c.viaCli(today, _vault));
  final localOut = await capture(() => c.viaAccess(access));
  return (today: today, local: local, todayOut: todayOut, localOut: localOut);
}

void _expectSameCalls(FakeMemexCli today, FakeMemexCli local, String reason) {
  expect(today.calls, isNotEmpty, reason: '$reason: wrapper ran');
  expect(
    [for (final c in local.calls) c.args],
    equals([for (final c in today.calls) c.args]),
    reason: '$reason: argv',
  );
  expect(
    [for (final c in local.calls) c.stdinBody],
    equals([for (final c in today.calls) c.stdinBody]),
    reason: '$reason: stdin',
  );
}

/// A [NotesAccess] that relays each interface call, with every argument the
/// call carries, to a [LocalNotesAccess], the way a proxy or RPC client of
/// the interface would. It declares no defaults of its own: a Dart call takes
/// the implementation's defaults, so only a noSuchMethod forwarder (which
/// fills in the interface's) observes the defaults [NotesAccess] declares.
class _Wi70NotesInterfaceRelay implements NotesAccess {
  _Wi70NotesInterfaceRelay(this.local);

  final LocalNotesAccess local;
  final invocations = <Invocation>[];

  @override
  dynamic noSuchMethod(Invocation i) {
    invocations.add(i);
    final n = i.namedArguments;
    return switch (i.memberName) {
      #updateNote => local.updateNote(
        noteId: n[#noteId] as String,
        expectedVersion: n[#expectedVersion] as int,
        title: n[#title] as String?,
        contentMd: n[#contentMd] as String,
        noRenameLinks: n[#noRenameLinks] as bool,
      ),
      #updateLink => local.updateLink(
        linkId: n[#linkId] as String,
        kind: n[#kind] as String?,
        label: n[#label] as String?,
        clearLabel: n[#clearLabel] as bool,
      ),
      _ => super.noSuchMethod(i),
    };
  }
}

/// [_Wi70NotesInterfaceRelay] for [TopicsAccess].
class _Wi70TopicsInterfaceRelay implements TopicsAccess {
  _Wi70TopicsInterfaceRelay(this.local);

  final LocalTopicsAccess local;
  final invocations = <Invocation>[];

  @override
  dynamic noSuchMethod(Invocation i) {
    invocations.add(i);
    final n = i.namedArguments;
    return switch (i.memberName) {
      #updateFolder => local.updateFolder(
        id: n[#id] as String,
        name: n[#name] as String?,
        parentId: n[#parentId] as String?,
        toRoot: n[#toRoot] as bool,
        pinned: n[#pinned] as bool?,
      ),
      _ => super.noSuchMethod(i),
    };
  }
}

void main() {
  group('AC2 argv, stdin and result', () {
    test(
      'every local write sends the same argv and stdin as today and returns the same result',
      () async {
        for (final c in vaultAccessWriteCases) {
          final r = await _runBoth(c);
          _expectSameCalls(r.today, r.local, c.name);
          expect(
            r.todayOut,
            isNot(anyOf(isA<Exception>(), isA<Error>())),
            reason: c.name,
          );
          expect(
            vaultAccessShape(r.localOut),
            equals(vaultAccessShape(r.todayOut)),
            reason: '${c.name}: result',
          );
          expect(
            r.localOut.runtimeType,
            r.todayOut.runtimeType,
            reason: c.name,
          );
        }
      },
    );

    test('local addNote passes role and tags and the body on stdin', () async {
      final cli = vaultAccessSampleCli();
      final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

      final id = await access.notes.addNote(
        title: 'Player Loop',
        tags: const ['games', 'design'],
        contentMd: 'line one\nline two\n',
        role: 'topic',
      );

      expect(id, '01J9Z8Y7X6W5V4T3S2R1Q0AB70');
      final call = cli.callsFor('add').single;
      expect(call.args, [
        'add',
        '--vault',
        _vault,
        '--title',
        'Player Loop',
        '--tags',
        'games,design',
        '--role',
        'topic',
      ]);
      expect(call.stdinBody, 'line one\nline two\n');
    });

    test(
      'local updateNote passes expected version and no rename links',
      () async {
        final cli = vaultAccessSampleCli();
        final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

        final result = await access.notes.updateNote(
          noteId: 'n-70',
          expectedVersion: 7,
          title: 'Renamed',
          contentMd: 'new body',
          noRenameLinks: true,
        );

        expect(result.noteId, 'n-70');
        expect(result.version, 8);
        expect(result.updatedAt, 1759600000070);
        final call = cli.callsFor('update').single;
        expect(call.args, [
          'update',
          '--vault',
          _vault,
          '--note-id',
          'n-70',
          '--expected-version',
          '7',
          '--title',
          'Renamed',
          '--no-rename-links',
        ]);
        expect(call.stdinBody, 'new body');
      },
    );

    test(
      'topics reviewPrompt runs memex prompt review and returns the raw text',
      () async {
        final cli = vaultAccessSampleCli();
        final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

        final text = await access.topics.reviewPrompt();

        expect(text, 'Review the day.\n\nLine two, verbatim.  \n');
        expect(cli.calls.single.args, ['prompt', 'review']);
        expect(cli.calls.single.stdinBody, isNull);
      },
    );

    test('local writes never read the database', () async {
      // A write with no database handle still runs (DB-null setups).
      final cli = vaultAccessSampleCli();
      final access = LocalVaultAccess(vaultPath: _vault, cli: cli);
      for (final c in vaultAccessWriteCases) {
        await c.viaAccess(access);
      }
      expect(cli.calls, hasLength(vaultAccessWriteCases.length));
    });
  });

  group('AC2 interface defaults', () {
    test(
      'NotesAccess updateNote called without noRenameLinks sends no rename links flag',
      () async {
        final today = vaultAccessSampleCli();
        final cli = vaultAccessSampleCli();
        final relay = _Wi70NotesInterfaceRelay(
          LocalNotesAccess(vaultPath: _vault, cli: cli),
        );
        final NotesAccess notes = relay;

        final result = await notes.updateNote(
          noteId: 'n-70',
          expectedVersion: 7,
          title: 'Renamed',
          contentMd: 'new body',
        );
        final todayResult = await today.updateNote(
          vaultPath: _vault,
          noteId: 'n-70',
          expectedVersion: 7,
          title: 'Renamed',
          contentMd: 'new body',
        );

        expect(
          relay.invocations.single.namedArguments[#noRenameLinks],
          isFalse,
          reason: 'the interface default',
        );
        final call = cli.callsFor('update').single;
        expect(call.args, isNot(contains('--no-rename-links')));
        expect(call.args, today.callsFor('update').single.args);
        expect(call.stdinBody, 'new body');
        expect(vaultAccessShape(result), vaultAccessShape(todayResult));
      },
    );

    test(
      'NotesAccess updateLink called without clearLabel keeps the label',
      () async {
        final today = vaultAccessSampleCli();
        final cli = vaultAccessSampleCli();
        final relay = _Wi70NotesInterfaceRelay(
          LocalNotesAccess(vaultPath: _vault, cli: cli),
        );
        final NotesAccess notes = relay;

        final result = await notes.updateLink(linkId: 'l-70', label: 'why');
        final todayResult = await today.updateLink(
          vaultPath: _vault,
          linkId: 'l-70',
          label: 'why',
        );

        expect(
          relay.invocations.single.namedArguments[#clearLabel],
          isFalse,
          reason: 'the interface default',
        );
        final call = cli.callsFor('update-link').single;
        expect(call.args, isNot(contains('--clear-label')));
        expect(call.args, today.callsFor('update-link').single.args);
        expect(vaultAccessShape(result), vaultAccessShape(todayResult));
      },
    );

    test(
      'TopicsAccess updateFolder called without toRoot reparents and does not move to root',
      () async {
        final today = vaultAccessSampleCli();
        final cli = vaultAccessSampleCli();
        final relay = _Wi70TopicsInterfaceRelay(
          LocalTopicsAccess(vaultPath: _vault, cli: cli),
        );
        final TopicsAccess topics = relay;

        final result = await topics.updateFolder(id: 'f-70', parentId: 'p-70');
        final todayResult = await today.updateFolder(
          vaultPath: _vault,
          id: 'f-70',
          parentId: 'p-70',
        );

        expect(
          relay.invocations.single.namedArguments[#toRoot],
          isFalse,
          reason: 'the interface default',
        );
        final call = cli.callsFor('folder update').single;
        expect(call.args, isNot(contains('--to-root')));
        expect(call.args, containsAllInOrder(['--parent-id', 'p-70']));
        expect(call.args, today.callsFor('folder update').single.args);
        expect(vaultAccessShape(result), vaultAccessShape(todayResult));
      },
    );
  });

  group('AC3 failing writes', () {
    test(
      'every failing local write throws the same MemexException as today',
      () async {
        for (final c in vaultAccessWriteCases) {
          final r = await _runBoth(
            c,
            script: (cli) => cli.on(
              c.subcommand,
              (_) => FakeMemexCli.error('some_rule', 'rule broke: ${c.name}', {
                'field_a': 'x',
                'field_n': 3,
              }),
            ),
          );
          expect(r.todayOut, isA<MemexException>(), reason: c.name);
          expect(r.localOut, isA<MemexException>(), reason: c.name);
          expect(
            vaultAccessShape(r.localOut),
            equals(vaultAccessShape(r.todayOut)),
            reason: c.name,
          );
        }
      },
    );

    test(
      'every local write with unparseable output fails the same way as today',
      () async {
        // reviewPrompt returns raw stdout, so it has no parse failure.
        for (final c in vaultAccessWriteCases.where(
          (c) => c.subcommand != 'prompt review',
        )) {
          final r = await _runBoth(
            c,
            script: (cli) => cli.on(
              c.subcommand,
              (_) => FakeMemexCli.ok('{"unexpected":1}'),
            ),
          );
          expect(
            r.todayOut,
            anyOf(isA<Exception>(), isA<Error>()),
            reason: c.name,
          );
          expect(
            r.localOut.runtimeType,
            r.todayOut.runtimeType,
            reason: c.name,
          );
          if (r.todayOut is MemexException) {
            expect(
              vaultAccessShape(r.localOut),
              equals(vaultAccessShape(r.todayOut)),
              reason: c.name,
            );
          }
        }
      },
    );

    test(
      'local updateNote version conflict throws MemexErrorKind.versionConflict',
      () async {
        final cli = vaultAccessSampleCli()
          ..on(
            'update',
            (_) => FakeMemexCli.error(
              'version_conflict',
              'version conflict: expected 3, current 4',
              {'expected': 3, 'current': 4},
            ),
          );
        final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          access.notes.updateNote(
            noteId: 'n-70',
            expectedVersion: 3,
            contentMd: 'x',
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.kind, 'kind', MemexErrorKind.versionConflict)
                .having((e) => e.code, 'code', 'version_conflict')
                .having(
                  (e) => e.message,
                  'message',
                  'update failed: version conflict: expected 3, current 4',
                )
                .having((e) => e.fields, 'fields', {
                  'expected': 3,
                  'current': 4,
                }),
          ),
        );
      },
    );

    test('local addNote daily note exists carries existing_id', () async {
      const existing = '01J9Z8Y7X6W5V4T3S2R1Q0P9N8';
      final cli = vaultAccessSampleCli()
        ..on(
          'add',
          (_) => FakeMemexCli.error(
            'daily_note_exists',
            'a daily note for 2026-10-03 already exists: $existing',
            {'date': '2026-10-03', 'existing_id': existing},
          ),
        );
      final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

      await expectLater(
        access.notes.addNote(title: '2026-10-03', contentMd: '', role: 'daily'),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'daily_note_exists')
              .having((e) => e.kind, 'kind', MemexErrorKind.other)
              .having((e) => e.fields['existing_id'], 'existing_id', existing)
              .having(
                (e) => e.message,
                'message',
                'add failed: a daily note for 2026-10-03 already exists: '
                    '$existing',
              ),
        ),
      );
    });

    test('local createFolder depth exceeded carries required_depth', () async {
      final cli = vaultAccessSampleCli()
        ..on(
          'folder new',
          (_) => FakeMemexCli.error(
            'depth_exceeded',
            'folder would be 3 deep; max is 2',
            {'max_depth': 2, 'required_depth': 3},
          ),
        );
      final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

      await expectLater(
        access.topics.createFolder(name: 'Deep', parentId: 'p-70'),
        throwsA(
          isA<MemexException>()
              .having((e) => e.code, 'code', 'depth_exceeded')
              .having((e) => e.fields['required_depth'], 'required_depth', 3)
              .having((e) => e.fields['max_depth'], 'max_depth', 2)
              .having(
                (e) => e.message,
                'message',
                'folder new failed: folder would be 3 deep; max is 2',
              ),
        ),
      );
    });

    test(
      'local write with legacy stderr keeps the legacy conflict kind',
      () async {
        final cli = vaultAccessSampleCli()
          ..on(
            'update',
            (_) =>
                FakeMemexCli.failure('Error: VersionConflict { expected: 1 }'),
          );
        final access = LocalVaultAccess(vaultPath: _vault, cli: cli);

        await expectLater(
          access.notes.updateNote(
            noteId: 'n-70',
            expectedVersion: 1,
            contentMd: 'x',
          ),
          throwsA(
            isA<MemexException>()
                .having((e) => e.kind, 'kind', MemexErrorKind.versionConflict)
                .having((e) => e.code, 'code', isNull),
          ),
        );
      },
    );
  });
}
