// WI #13 (Spec #7 A1, D16): the local data seam of agent note edits.
//
// Reads go to SQLite (`VaultDb`, through `LocalNotesAccess`) and are tested
// against the regenerated V8 dump (`FakeVaultDb.v5()`, W0's
// `vault_schema_v5.sql`) and against a pre-V8 schema: a missing
// `notes.agent_read_only` reads as false, a missing `note_revisions` as an
// empty list, never a throw, and both are probed on every read (the CLI may
// migrate while the app's handle stays open).
//
// Writes go through `AgentEditsCli` (`memex read-only set|clear`, `memex
// revisions restore`) on a `FakeMemexCli`: one call each, with the exact
// argv; a CLI failure is a `MemexException` with its C1 code and message.
// Never a real `memex`.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/cli/note_edits_cli.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/vault_access/local/notes.dart';

import '../support/agent_edits_fakes.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

const _wi13Flagged = '01JAGENTEDITSFLAGGED000013';
const _wi13Plain = '01JAGENTEDITSPLAIN00000013';
const _wi13Other = '01JAGENTEDITSOTHER00000013';
const _wi13Unknown = '01JAGENTEDITSUNKNOWN000013';

/// Seeds [_wi13Flagged] (flag on when the column exists), [_wi13Plain] and
/// [_wi13Other] into [db].
FakeVaultDb _wi13Seeded(FakeVaultDb db) {
  db
    ..seedNote(id: _wi13Flagged, title: 'Pricing notes', content: 'Pricing.')
    ..seedNote(id: _wi13Plain, title: 'Reading list', content: 'Books.')
    ..seedNote(id: _wi13Other, title: 'Status', content: 'Green.');
  if (db.agentReadOnlyForTest(_wi13Flagged) != null) {
    db.setAgentReadOnlyForTest(_wi13Flagged, true);
  }
  return db;
}

LocalNotesAccess _wi13Access(FakeVaultDb db, {FakeMemexCli? cli}) =>
    LocalNotesAccess(vaultPath: agentEditsVaultPath, db: db, cli: cli);

/// [future]'s value or the error it threw.
Future<Object?> _wi13Outcome(Future<Object?> future) async {
  try {
    return await future;
  } catch (e) {
    return e;
  }
}

void main() {
  group('note read: Agent read-only flag', () {
    test(
      'V8 local note read reports agentReadOnly true for a flagged note and false otherwise',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5());
        addTearDown(db.close);
        expect(db.getNote(_wi13Flagged)!.agentReadOnly, isTrue);
        expect(db.getNote(_wi13Plain)!.agentReadOnly, isFalse);

        final access = _wi13Access(db);
        expect((await access.getNote(_wi13Flagged))!.agentReadOnly, isTrue);
        expect((await access.getNote(_wi13Plain))!.agentReadOnly, isFalse);

        // Built from run-time values: the flag follows the stored column.
        db.setAgentReadOnlyForTest(_wi13Plain, true);
        db.setAgentReadOnlyForTest(_wi13Flagged, false);
        expect((await access.getNote(_wi13Plain))!.agentReadOnly, isTrue);
        expect((await access.getNote(_wi13Flagged))!.agentReadOnly, isFalse);
      },
    );

    test(
      'note read on a vault without agent_read_only reports false and re-probes after migration',
      () async {
        final db = _wi13Seeded(agentEditsV7Vault());
        addTearDown(db.close);
        expect(db.hasColumns('notes', VaultDb.v8NoteColumns), isFalse);
        final access = _wi13Access(db);

        final before = await access.getNote(_wi13Flagged);
        expect(before, isNotNull);
        expect(before!.agentReadOnly, isFalse);
        expect(before.title, 'Pricing notes');

        // The CLI migrates the vault while this handle stays open: the next
        // read must see the new column (no cached negative).
        db.migrateAgentEditsToV8();
        db.setAgentReadOnlyForTest(_wi13Flagged, true);
        expect((await access.getNote(_wi13Flagged))!.agentReadOnly, isTrue);
        expect((await access.getNote(_wi13Plain))!.agentReadOnly, isFalse);
      },
    );

    test('note read on a V6 vault reports agentReadOnly false', () async {
      final db = FakeVaultDb.v6Only()
        ..seedNote(id: _wi13Plain, title: 'Reading list');
      addTearDown(db.close);
      expect(
        (await _wi13Access(db).getNote(_wi13Plain))!.agentReadOnly,
        isFalse,
      );
    });

    test('the Note constructor defaults agentReadOnly to false', () {
      final title = ['Reading', 'list'].join(' ');
      final note = Note(
        id: _wi13Plain,
        title: title,
        contentMd: '',
        frontmatter: '{}',
        version: DateTime(2026).year,
        createdAt: 0,
        updatedAt: 0,
        tags: const [],
      );
      expect(note.agentReadOnly, isFalse);
      final flagged = Note(
        id: _wi13Flagged,
        title: title,
        contentMd: '',
        frontmatter: '{}',
        version: 1,
        createdAt: 0,
        updatedAt: 0,
        tags: const [],
        agentReadOnly: title.isNotEmpty,
      );
      expect(flagged.agentReadOnly, isTrue);
    });
  });

  group('noteRevisions: SQLite read', () {
    test(
      'V8 local noteRevisions lists the note revisions newest first with id agentChangeId and createdAt',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5())
          ..seedNoteRevision(
            id: 'rev-a1',
            noteId: _wi13Plain,
            agentChangeId: 'chg-a1',
            previousVersion: 1,
            newVersion: 2,
            createdAt: 1759500000000,
          )
          ..seedNoteRevision(
            id: 'rev-a3',
            noteId: _wi13Plain,
            agentChangeId: null,
            previousVersion: 3,
            newVersion: 4,
            createdAt: 1759500300000,
          )
          ..seedNoteRevision(
            id: 'rev-a2',
            noteId: _wi13Plain,
            agentChangeId: 'chg-a2',
            previousVersion: 2,
            newVersion: 3,
            createdAt: 1759500200000,
          )
          ..seedNoteRevision(
            id: 'rev-b1',
            noteId: _wi13Other,
            agentChangeId: 'chg-b1',
            createdAt: 1759500400000,
          );
        addTearDown(db.close);

        for (final rows in [
          db.noteRevisions(_wi13Plain),
          await _wi13Access(db).noteRevisions(_wi13Plain),
        ]) {
          expect([for (final r in rows) r.id], ['rev-a3', 'rev-a2', 'rev-a1']);
          expect(
            [for (final r in rows) r.agentChangeId],
            [null, 'chg-a2', 'chg-a1'],
          );
          expect(
            [for (final r in rows) r.createdAt],
            [1759500300000, 1759500200000, 1759500000000],
          );
        }
        expect(
          [for (final r in db.noteRevisions(_wi13Other)) r.id],
          ['rev-b1'],
        );
        expect(db.noteRevisions(_wi13Flagged), isEmpty);
        expect(await _wi13Access(db).noteRevisions(_wi13Unknown), isEmpty);
      },
    );

    test(
      'noteRevisions orders by the revision version when created_at went backward',
      () async {
        // A wall-clock jump back (NTP, a manual change) between two agent
        // edits: the newer revision has the older stamp. Newest first follows
        // the edit order (new_version), as core and `memex revisions list` do.
        final db = _wi13Seeded(FakeVaultDb.v5())
          ..seedNoteRevision(
            id: 'rev-early',
            noteId: _wi13Plain,
            previousVersion: 1,
            newVersion: 2,
            createdAt: 1759500900000,
          )
          ..seedNoteRevision(
            id: 'rev-late',
            noteId: _wi13Plain,
            previousVersion: 2,
            newVersion: 3,
            createdAt: 1759500100000,
          );
        addTearDown(db.close);
        expect(
          [for (final r in db.noteRevisions(_wi13Plain)) r.id],
          ['rev-late', 'rev-early'],
        );
      },
    );

    test(
      'noteRevisions on a vault without note_revisions is empty and re-probes after migration',
      () async {
        final db = _wi13Seeded(agentEditsV7Vault());
        addTearDown(db.close);
        expect(db.hasTables(VaultDb.v8TableNames), isFalse);
        final access = _wi13Access(db);
        expect(db.noteRevisions(_wi13Plain), isEmpty);
        expect(await access.noteRevisions(_wi13Plain), isEmpty);

        db.migrateAgentEditsToV8();
        db.seedNoteRevision(id: 'rev-after', noteId: _wi13Plain);
        expect(
          [for (final r in await access.noteRevisions(_wi13Plain)) r.id],
          ['rev-after'],
        );
      },
    );

    test('noteRevisions with no database handle is empty', () async {
      final access = LocalNotesAccess(vaultPath: agentEditsVaultPath);
      expect(await access.noteRevisions(_wi13Plain), isEmpty);
    });
  });

  group('writes through AgentEditsCli', () {
    test(
      'local setAgentReadOnly runs memex read-only set or clear once with the vault and note id',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5());
        addTearDown(db.close);
        final cli = FakeMemexCli()..onAgentEdits(db);
        final access = _wi13Access(db, cli: cli);

        final set = await access.setAgentReadOnly(_wi13Plain, true);
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'read-only',
          'set',
          '--vault',
          agentEditsVaultPath,
          '--note-id',
          _wi13Plain,
        ]);
        expect(set.vaultId, agentEditsVaultId);
        expect(set.noteId, _wi13Plain);
        expect(set.agentReadOnly, isTrue);
        expect(db.agentReadOnlyForTest(_wi13Plain), isTrue);

        final clear = await access.setAgentReadOnly(_wi13Plain, false);
        expect(cli.calls, hasLength(2));
        expect(cli.calls.last.args, [
          'read-only',
          'clear',
          '--vault',
          agentEditsVaultPath,
          '--note-id',
          _wi13Plain,
        ]);
        expect(clear.noteId, _wi13Plain);
        expect(clear.agentReadOnly, isFalse);
        expect(db.agentReadOnlyForTest(_wi13Plain), isFalse);
      },
    );

    test(
      'local restoreNoteRevision runs memex revisions restore once with the revision id',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5())
          ..seedNoteRevision(
            id: 'rev-restore',
            noteId: _wi13Plain,
            previousMd: 'Books I mean to read.',
          );
        addTearDown(db.close);
        final cli = FakeMemexCli()..onAgentEdits(db);
        final access = _wi13Access(db, cli: cli);

        final out = await access.restoreNoteRevision(
          noteId: _wi13Plain,
          revisionId: 'rev-restore',
        );
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'revisions',
          'restore',
          '--vault',
          agentEditsVaultPath,
          '--revision-id',
          'rev-restore',
        ]);
        expect(out.vaultId, agentEditsVaultId);
        expect(out.noteId, _wi13Plain);
        expect(out.version, 2);
        expect(out.contentMd, 'Books I mean to read.');
      },
    );

    test(
      'local agent edit writes surface CLI errors as MemexException with code and message',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5());
        addTearDown(db.close);
        final cases =
            <
              ({
                String name,
                String subcommand,
                String code,
                String message,
                Future<Object?> Function(LocalNotesAccess a) call,
              })
            >[
              (
                name: 'set',
                subcommand: 'read-only set',
                code: 'role_rule',
                message: 'daily notes cannot be read-only for agents',
                call: (a) => a.setAgentReadOnly(_wi13Plain, true),
              ),
              (
                name: 'clear',
                subcommand: 'read-only clear',
                code: 'not_found',
                message: 'note not found',
                call: (a) => a.setAgentReadOnly(_wi13Unknown, false),
              ),
              (
                name: 'restore',
                subcommand: 'revisions restore',
                code: 'not_found',
                message: 'revision not found',
                call: (a) => a.restoreNoteRevision(
                  noteId: _wi13Plain,
                  revisionId: 'gone',
                ),
              ),
            ];
        for (final c in cases) {
          final cli = FakeMemexCli()
            ..on(c.subcommand, (_) => FakeMemexCli.error(c.code, c.message));
          final e = await _wi13Outcome(c.call(_wi13Access(db, cli: cli)));
          expect(e, isA<MemexException>(), reason: c.name);
          e as MemexException;
          expect(e.code, c.code, reason: c.name);
          expect(e.message, '${c.subcommand} failed: ${c.message}');
          expect(cli.calls, hasLength(1), reason: '${c.name}: one call');
        }
        expect(db.agentReadOnlyForTest(_wi13Plain), isFalse);
      },
    );

    test(
      'local agent edit writes with no CLI throw StateError and run nothing',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5());
        addTearDown(db.close);
        final access = _wi13Access(db);
        expect(
          await _wi13Outcome(access.setAgentReadOnly(_wi13Plain, true)),
          isA<StateError>(),
        );
        expect(
          await _wi13Outcome(
            access.restoreNoteRevision(noteId: _wi13Plain, revisionId: 'r'),
          ),
          isA<StateError>(),
        );
        expect(db.agentReadOnlyForTest(_wi13Plain), isFalse);
      },
    );
  });

  group('AgentEditsCli wrappers', () {
    test(
      'AgentEditsCli noteRevisions runs memex revisions list once with the note id',
      () async {
        final db = _wi13Seeded(FakeVaultDb.v5())
          ..seedNoteRevision(
            id: 'rev-1',
            noteId: _wi13Plain,
            agentChangeId: 'chg-1',
            newVersion: 2,
            createdAt: 1759500000000,
          )
          ..seedNoteRevision(
            id: 'rev-2',
            noteId: _wi13Plain,
            newVersion: 3,
            createdAt: 1759500100000,
          );
        addTearDown(db.close);
        final cli = FakeMemexCli()..onAgentEdits(db);
        final rows = await cli.noteRevisions(
          vaultPath: agentEditsVaultPath,
          noteId: _wi13Plain,
        );
        expect(cli.calls, hasLength(1));
        expect(cli.calls.single.args, [
          'revisions',
          'list',
          '--vault',
          agentEditsVaultPath,
          '--note-id',
          _wi13Plain,
        ]);
        expect([for (final r in rows) r.id], ['rev-2', 'rev-1']);
        expect([for (final r in rows) r.agentChangeId], [null, 'chg-1']);
        expect(
          [for (final r in rows) r.createdAt],
          [1759500100000, 1759500000000],
        );

        final e = await _wi13Outcome(
          cli.noteRevisions(
            vaultPath: agentEditsVaultPath,
            noteId: _wi13Unknown,
          ),
        );
        expect(e, isA<MemexException>());
        expect((e as MemexException).code, 'not_found');
        expect(e.message, startsWith('revisions list failed: '));
      },
    );

    test(
      'AgentEditsCli wrappers reject stdout that is not the D14 shape with a null code',
      () async {
        final bad = <String>[
          'not json',
          '[]',
          '{"vault_id":"v"}',
          '{"vault_id":"v","note_id":"n","agent_read_only":"yes"}',
          '{"vault_id":"v","revisions":[{"id":"r","agent_change_id":7,"created_at":1}]}',
          '{"vault_id":"v","revisions":[{"id":"r","created_at":"soon"}]}',
          '{"vault_id":"v","note_id":"n","version":"2","content_md":"x"}',
        ];
        for (final stdout in bad) {
          final cli = FakeMemexCli()
            ..on('read-only set', (_) => FakeMemexCli.ok(stdout))
            ..on('revisions list', (_) => FakeMemexCli.ok(stdout))
            ..on('revisions restore', (_) => FakeMemexCli.ok(stdout));
          final calls = <Future<Object?>>[
            cli.setAgentReadOnly(
              vaultPath: agentEditsVaultPath,
              noteId: _wi13Plain,
              on: true,
            ),
            cli.noteRevisions(
              vaultPath: agentEditsVaultPath,
              noteId: _wi13Plain,
            ),
            cli.restoreNoteRevision(
              vaultPath: agentEditsVaultPath,
              revisionId: 'r',
            ),
          ];
          final ops = ['read-only set', 'revisions list', 'revisions restore'];
          for (var i = 0; i < calls.length; i++) {
            final e = await _wi13Outcome(calls[i]);
            // None of [bad] is the D14 shape of any of the three outputs.
            expect(e, isA<MemexException>(), reason: '${ops[i]}: $stdout');
            expect((e as MemexException).code, isNull, reason: stdout);
            expect(e.message, startsWith('${ops[i]}: could not parse output'));
          }
        }
      },
    );
  });
}
