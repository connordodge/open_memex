// WI #249 (A3): tagsAsyncProvider, notesForTagAsyncProvider, removeTagFromNote
// and the footerTags copy in rebaseEditorOnVersion (D23). FakeMemexCli and
// FakeVaultDb only: no real `memex`, no real vault, no wall-clock waits.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/tags_state.dart';
import 'package:open_memex_app/src/state/topic_actions.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/editor_access_doubles.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/fake_vault_server.dart';
import '../support/tags_seed.dart';

const _vaultA = LocalVaultRef('/tmp/om-249-vault-a');
const _vaultB = LocalVaultRef('/tmp/om-249-vault-b');
const _plan = '01J9V6000000000000000000A1';
const _other = '01J9V6000000000000000000B2';

// ---------- provider helpers ----------

/// Tags over canned rows, held behind [gate] while it is set.
class _RowsTags extends LocalTagsAccess {
  _RowsTags(String vaultPath, this.rows, this.notes)
    : super(vaultPath: vaultPath);

  List<TagRow> rows;
  Map<String, List<TagNoteRow>> notes;
  Completer<void>? gate;

  @override
  Future<List<TagRow>> allTags() async {
    await gate?.future;
    return rows;
  }

  @override
  Future<List<TagNoteRow>> notesForTag(String tag) async {
    await gate?.future;
    return notes[tag] ?? const [];
  }
}

TagRow _tag(String tag, {int count = 1}) =>
    TagRow(tag: tag, noteCount: count, system: false);

TagNoteRow _noteRow(String id) => TagNoteRow(
  noteId: id,
  title: 'Title $id',
  role: null,
  firstLine: null,
  updatedAt: 1000,
);

List<String> _tagNames(VaultScoped<List<TagRow>> s) => [
  for (final r in s.value) r.tag,
];

List<String> _noteIds(VaultScoped<List<TagNoteRow>> s) => [
  for (final r in s.value) r.noteId,
];

ProviderContainer _switching(Map<VaultRef, LocalTagsAccess> tags) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vaultA),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        final path = vault.localPath;
        if (path == null) return null;
        return LocalVaultAccess(vaultPath: path, tags: tags[vault]);
      }),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

ProviderContainer _onDb(VaultDb db, {LocalTagsAccess? tags}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vaultA),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      if (tags != null)
        vaultAccessProvider.overrideWith(
          (ref) =>
              LocalVaultAccess(vaultPath: _vaultA.path, db: db, tags: tags),
        ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

// ---------- action helpers ----------

/// Records every note the editor is given: EditorStateValue keeps no tags, so
/// this is where a rebase's Note copy shows.
class _RecordingEditor extends EditorController {
  _RecordingEditor(super.ref);

  final loaded = <Note?>[];

  @override
  void loadNote(Note? note) {
    loaded.add(note);
    super.loadNote(note);
  }
}

class _Env {
  _Env(this.container, this.ref, this.clock, this.bumps);

  final ProviderContainer container;
  final WidgetRef ref;
  final FakeClock clock;

  /// One entry per `vaultRevisionProvider` bump: the editor's base version at
  /// that moment.
  final List<int?> bumps;

  _RecordingEditor get editor =>
      container.read(editorControllerProvider.notifier) as _RecordingEditor;

  EditorStateValue get state => container.read(editorControllerProvider);
}

Future<_Env> _open(
  WidgetTester tester, {
  required FakeVaultDb db,
  MemexCli? cli,
  VaultRef vault = _vaultA,
  VaultAccess? Function()? access,
}) async {
  final clock = FakeClock();
  final c = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(clock),
      utcOffsetProvider.overrideWithValue(() => Duration.zero),
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      editorControllerProvider.overrideWith(_RecordingEditor.new),
      if (access != null) vaultAccessProvider.overrideWith((_) => access()),
    ],
  );
  addTearDown(c.dispose);
  await c.read(vaultOpenProvider.future);
  late WidgetRef ref;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: Consumer(
        builder: (_, r, _) {
          ref = r;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  final bumps = <int?>[];
  final sub = c.listen<int>(
    vaultRevisionProvider,
    (_, _) => bumps.add(c.read(editorControllerProvider).lastSavedVersion),
  );
  addTearDown(sub.close);
  return _Env(c, ref, clock, bumps);
}

String _rmJson(String noteId, String tag, int version, {bool removed = true}) =>
    jsonEncode({
      'note_id': noteId,
      'tag': tag,
      'removed': removed,
      'correction_id': null,
      'version': version,
    });

/// What `memex tag rm` does to the vault: drops the row and moves the version.
MemexResult _applyRm(FakeVaultDb db, FakeCliCall call) {
  final id = call.flag('note-id')!;
  final tag = call.flag('tag')!;
  db.db.execute('DELETE FROM tags WHERE note_id = ? AND tag = ?', [id, tag]);
  db.db.execute('UPDATE notes SET version = version + 1 WHERE id = ?', [id]);
  return FakeMemexCli.ok('${_rmJson(id, tag, db.getNote(id)!.version)}\n');
}

/// A CLI whose `tag rm` and `update` act on [db].
FakeMemexCli _cli(FakeVaultDb db) => FakeMemexCli()
  ..on('tag rm', (call) => _applyRm(db, call))
  ..on('update', (call) {
    final id = call.flag('note-id')!;
    db.db.execute(
      'UPDATE notes SET version = version + 1, content_md = ? WHERE id = ?',
      [call.stdinBody, id],
    );
    return FakeMemexCli.ok(
      '${jsonEncode({'note_id': id, 'version': db.getNote(id)!.version, 'updated_at': 5000})}\n',
    );
  });

/// [_plan] at version 3 with footer tags `drop` and `keep`, and [_other] at
/// version 8.
FakeVaultDb _vault() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  db.seedNote(id: _plan, title: 'Plan', content: 'stored text', version: 3);
  db.seedTag(_plan, 'drop', origin: 'agent');
  db.seedTag(_plan, 'keep', origin: 'person');
  db.seedNote(id: _other, title: 'Other', content: 'other text', version: 8);
  return db;
}

void main() {
  group('tagsAsyncProvider', () {
    test(
      'tagsAsyncProvider reads the open vault through VaultAccess stamped with it and is empty with none open',
      () async {
        final db = _vault();
        final c = _onDb(db);

        final scoped = await c.read(tagsAsyncProvider.future);

        expect(scoped.vault, _vaultA);
        expect(_tagNames(scoped), ['drop', 'keep']);

        c.read(currentVaultProvider.notifier).state = null;
        final none = await c.read(tagsAsyncProvider.future);
        expect(none.vault, isNull);
        expect(none.value, isEmpty);
      },
    );

    test(
      'tagsAsyncProvider re-reads on a vaultRevisionProvider bump',
      () async {
        final tags = _RowsTags(_vaultA.path, [_tag('first')], const {});
        final c = _switching({_vaultA: tags});
        final sub = c.listen(tagsAsyncProvider, (_, _) {});
        addTearDown(sub.close);
        expect(_tagNames(await c.read(tagsAsyncProvider.future)), ['first']);

        tags.rows = [_tag('second')];
        c.read(vaultRevisionProvider.notifier).state++;

        expect(_tagNames(await c.read(tagsAsyncProvider.future)), ['second']);
      },
    );

    test(
      'tagsAsyncProvider on a vault switch never shows the previous vault rows',
      () async {
        final b = _RowsTags(_vaultB.path, [_tag('from-b')], const {})
          ..gate = Completer<void>();
        final c = _switching({
          _vaultA: _RowsTags(_vaultA.path, [_tag('from-a')], const {}),
          _vaultB: b,
        });
        final sub = c.listen(tagsAsyncProvider, (_, _) {});
        addTearDown(sub.close);
        expect(_tagNames(await c.read(tagsAsyncProvider.future)), ['from-a']);

        c.read(currentVaultProvider.notifier).state = _vaultB;
        await pumpEventQueue();
        expect(currentVaultData(c.read(tagsAsyncProvider), _vaultB), isNull);

        b.gate!.complete();
        final scoped = await c.read(tagsAsyncProvider.future);
        expect(scoped.vault, _vaultB);
        expect(_tagNames(scoped), ['from-b']);
      },
    );

    test(
      'tagsAsyncProvider is empty on a local vault below V6 and reads once it migrates',
      () async {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        db.seedNote(id: _plan, title: 'Plan', tags: ['work']);
        final c = _onDb(db);
        final sub = c.listen(tagsAsyncProvider, (_, _) {});
        addTearDown(sub.close);

        final below = await c.read(tagsAsyncProvider.future);
        expect(below.vault, _vaultA);
        expect(below.value, isEmpty);

        db.migrateToV6();
        c.read(vaultRevisionProvider.notifier).state++;
        expect(_tagNames(await c.read(tagsAsyncProvider.future)), ['work']);
      },
    );

    test(
      'tagsAsyncProvider asks no access for tags on a local vault below V6',
      () async {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        final c = _onDb(
          db,
          tags: _RowsTags(
            _vaultA.path,
            [_tag('from-double')],
            {
              'work': [_noteRow(_plan)],
            },
          ),
        );
        final sub = c.listen(tagsAsyncProvider, (_, _) {});
        addTearDown(sub.close);

        expect((await c.read(tagsAsyncProvider.future)).value, isEmpty);
        expect(
          (await c.read(notesForTagAsyncProvider('work').future)).value,
          isEmpty,
        );

        db.migrateToV6();
        c.read(vaultRevisionProvider.notifier).state++;
        expect(_tagNames(await c.read(tagsAsyncProvider.future)), [
          'from-double',
        ]);
        expect(
          _noteIds(await c.read(notesForTagAsyncProvider('work').future)),
          [_plan],
        );
      },
    );

    test(
      'tag providers read a hosted vault that has no local database',
      () async {
        final server = FakeVaultServer()
          ..route(
            'GET',
            '/vaults/seed/api/v1/tags',
            json: {
              'tags': [
                {'tag': 'work', 'note_count': 1, 'system': false},
              ],
            },
          )
          ..route(
            'GET',
            '/vaults/seed/api/v1/tags/work/notes',
            json: {
              'notes': [
                {
                  'note_id': _plan,
                  'title': 'Plan',
                  'role': null,
                  'first_line': null,
                  'updated_at': 1000,
                },
              ],
            },
          );
        final clients = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(clients.dispose);
        const ref = HostedVaultRef(fakeServerId, 'seed');
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => ref),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            vaultAccessProvider.overrideWith(
              (_) => HostedVaultAccess(
                client: server.connect(clients),
                vaultName: 'seed',
              ),
            ),
          ],
        );
        addTearDown(c.dispose);

        final tags = await c.read(tagsAsyncProvider.future);
        expect(tags.vault, ref);
        expect(_tagNames(tags), ['work']);
        final notes = await c.read(notesForTagAsyncProvider('work').future);
        expect(notes.vault, ref);
        expect(_noteIds(notes), [_plan]);
      },
    );
  });

  group('notesForTagAsyncProvider', () {
    test(
      'notesForTagAsyncProvider reads the notes of its tag stamped with the vault and re-reads on a bump',
      () async {
        final tags = _RowsTags(_vaultA.path, const [], {
          'work': [_noteRow('w1')],
          'home': [_noteRow('h1')],
        });
        final c = _switching({_vaultA: tags});
        final sub = c.listen(notesForTagAsyncProvider('work'), (_, _) {});
        addTearDown(sub.close);

        final work = await c.read(notesForTagAsyncProvider('work').future);
        expect(work.vault, _vaultA);
        expect(_noteIds(work), ['w1']);
        expect(
          _noteIds(await c.read(notesForTagAsyncProvider('home').future)),
          ['h1'],
        );

        tags.notes = {
          'work': [_noteRow('w2')],
        };
        c.read(vaultRevisionProvider.notifier).state++;
        expect(
          _noteIds(await c.read(notesForTagAsyncProvider('work').future)),
          ['w2'],
        );
      },
    );

    test(
      'notesForTagAsyncProvider on a vault switch never shows the previous vault rows',
      () async {
        final b = _RowsTags(_vaultB.path, const [], {
          'work': [_noteRow('from-b')],
        })..gate = Completer<void>();
        final c = _switching({
          _vaultA: _RowsTags(_vaultA.path, const [], {
            'work': [_noteRow('from-a')],
          }),
          _vaultB: b,
        });
        final sub = c.listen(notesForTagAsyncProvider('work'), (_, _) {});
        addTearDown(sub.close);
        expect(
          _noteIds(await c.read(notesForTagAsyncProvider('work').future)),
          ['from-a'],
        );

        c.read(currentVaultProvider.notifier).state = _vaultB;
        await pumpEventQueue();
        expect(
          currentVaultData(c.read(notesForTagAsyncProvider('work')), _vaultB),
          isNull,
        );

        b.gate!.complete();
        final scoped = await c.read(notesForTagAsyncProvider('work').future);
        expect(scoped.vault, _vaultB);
        expect(_noteIds(scoped), ['from-b']);
      },
    );
  });

  group('removeTagFromNote', () {
    testWidgets(
      'removeTagFromNote on the open note rebases on the returned version with a pending edit kept then bumps vaultRevisionProvider once',
      (tester) async {
        final db = _vault();
        final cli = _cli(db);
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_plan));
        env.editor.onTitleChanged('Edited title');
        env.editor.onContentChanged('pending text');
        final note = db.getNote(_plan)!;

        await removeTagFromNote(env.ref, note: note, tag: 'drop');

        expect(cli.callsFor('tag rm'), hasLength(1));
        final call = cli.callsFor('tag rm').single;
        expect(call.flag('vault'), _vaultA.path);
        expect(call.flag('note-id'), _plan);
        expect(call.flag('tag'), 'drop');
        expect(env.state.lastSavedVersion, 4);
        expect(env.state.contentMd, 'pending text');
        expect(env.state.title, 'Edited title');
        expect(env.state.status, SaveStatus.dirty);
        expect(env.bumps, [
          4,
        ], reason: 'one bump, after the editor moved to the returned version');
        expect(
          cli.callsFor('update'),
          isEmpty,
          reason: 'the debounce holds it',
        );

        // The kept edit goes out once on the rebased version: no conflict.
        env.clock.advance(saveDebounce);
        await tester.pump();
        expect(cli.callsFor('update'), hasLength(1));
        final update = cli.callsFor('update').single;
        expect(update.flag('expected-version'), '4');
        expect(update.stdinBody, 'pending text');
      },
    );

    testWidgets(
      'removeTagFromNote on a note that is not open leaves the editor alone and bumps once',
      (tester) async {
        final db = _vault();
        final cli = _cli(db);
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_other));
        env.editor.onContentChanged('other pending');
        final loadsBefore = env.editor.loaded.length;

        await removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop');

        expect(cli.callsFor('tag rm'), hasLength(1));
        expect(cli.callsFor('tag rm').single.flag('note-id'), _plan);
        expect(env.editor.loaded, hasLength(loadsBefore));
        expect(env.editor.activeNoteId, _other);
        expect(env.state.lastSavedVersion, 8);
        expect(env.state.contentMd, 'other pending');
        expect(env.bumps, hasLength(1));
      },
    );

    testWidgets(
      'removeTagFromNote with no note open writes and bumps once without loading anything',
      (tester) async {
        final db = _vault();
        final cli = _cli(db);
        final env = await _open(tester, db: db, cli: cli);

        await removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop');

        expect(cli.callsFor('tag rm'), hasLength(1));
        expect(env.editor.activeNoteId, isNull);
        expect(env.editor.loaded, isEmpty);
        expect(env.bumps, hasLength(1));
      },
    );

    testWidgets(
      'removeTagFromNote checks the open note after the write so a note opened during it rebases',
      (tester) async {
        final db = _vault();
        final release = Completer<void>();
        final cli = _cli(db)
          ..on('tag rm', (call) async {
            await release.future;
            return _applyRm(db, call);
          });
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_other));
        final note = db.getNote(_plan)!;

        final removal = removeTagFromNote(env.ref, note: note, tag: 'drop');
        await tester.pump();
        env.editor.loadNote(db.getNote(_plan)); // still version 3
        release.complete();
        await removal;

        expect(env.editor.activeNoteId, _plan);
        expect(env.state.lastSavedVersion, 4);
        expect(env.bumps, [4]);
      },
    );

    testWidgets(
      'removeTagFromNote does not rebase when the editor left the note during the write',
      (tester) async {
        final db = _vault();
        final release = Completer<void>();
        final cli = _cli(db)
          ..on('tag rm', (call) async {
            await release.future;
            return _applyRm(db, call);
          });
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_plan));
        env.editor.onContentChanged('plan pending');
        final note = db.getNote(_plan)!;

        final removal = removeTagFromNote(env.ref, note: note, tag: 'drop');
        await tester.pump();
        env.editor.loadNote(db.getNote(_other));
        final loadsBefore = env.editor.loaded.length;
        release.complete();
        await removal;

        expect(env.editor.activeNoteId, _other);
        expect(env.editor.loaded, hasLength(loadsBefore));
        expect(env.state.contentMd, 'other text');
        expect(env.state.lastSavedVersion, 8);
        expect(env.bumps, hasLength(1));
      },
    );

    testWidgets(
      'removeTagFromNote counts an already gone tag as a success and rebases on its version',
      (tester) async {
        final db = _vault();
        final cli = _cli(db)
          ..on('tag rm', (call) {
            db.db.execute('UPDATE notes SET version = 6 WHERE id = ?', [_plan]);
            return FakeMemexCli.ok(
              '${_rmJson(_plan, 'gone', 6, removed: false)}\n',
            );
          });
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_plan));
        env.editor.onContentChanged('pending text');

        await removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'gone');

        expect(env.state.lastSavedVersion, 6);
        expect(env.state.contentMd, 'pending text');
        expect(env.bumps, [6]);
      },
    );

    testWidgets(
      'a rejected removeTagFromNote write propagates with no rebase and no bump',
      (tester) async {
        final db = _vault();
        final cli = _cli(db)
          ..on(
            'tag rm',
            (_) => FakeMemexCli.error('invalid_argument', 'delete the text'),
          );
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_plan));
        env.editor.onContentChanged('pending text');
        final loadsBefore = env.editor.loaded.length;

        await expectLater(
          removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop'),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'invalid_argument',
            ),
          ),
        );

        expect(env.editor.loaded, hasLength(loadsBefore));
        expect(env.state.lastSavedVersion, 3);
        expect(env.state.contentMd, 'pending text');
        expect(env.bumps, isEmpty);
      },
    );

    testWidgets(
      'an unreachable hosted server propagates from removeTagFromNote with no bump',
      (tester) async {
        final db = _vault();
        final env = await _open(
          tester,
          db: db,
          access: () => LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            tags: _UnreachableTags(),
          ),
        );
        env.editor.loadNote(db.getNote(_plan));

        await expectLater(
          removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop'),
          throwsA(isA<VaultUnreachableException>()),
        );

        expect(env.state.lastSavedVersion, 3);
        expect(env.bumps, isEmpty);
      },
    );

    testWidgets(
      'removeTagFromNote with no CLI throws StateError with no bump',
      (tester) async {
        final db = _vault();
        final env = await _open(tester, db: db);
        env.editor.loadNote(db.getNote(_plan));

        await expectLater(
          removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop'),
          throwsStateError,
        );

        expect(db.getNote(_plan)!.tags, contains('drop'));
        expect(env.bumps, isEmpty);
      },
    );

    testWidgets(
      'removeTagFromNote on a hosted vault deletes through the server and rebases on its version',
      (tester) async {
        final db = _vault();
        const base = '/vaults/seed/api/v1';
        final server = FakeVaultServer()
          ..route(
            'DELETE',
            '$base/notes/$_plan/tags/caf%C3%A9',
            json: {
              'note_id': _plan,
              'tag': 'café',
              'removed': true,
              'correction_id': 2,
              'version': 11,
            },
          )
          ..route(
            'GET',
            '$base/notes/$_plan',
            json: {
              'note_id': _plan,
              'title': 'Plan',
              'content_md': 'server text',
              'frontmatter': <String, Object?>{},
              'version': 11,
              'created_at': 1000,
              'updated_at': 2000,
              'tags': ['keep'],
              'footer_tags': ['keep'],
            },
          );
        final clients = ProviderContainer(
          overrides: [
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
          ],
        );
        addTearDown(clients.dispose);
        final env = await _open(
          tester,
          db: db,
          vault: const HostedVaultRef(fakeServerId, 'seed'),
          access: () => HostedVaultAccess(
            client: server.connect(clients),
            vaultName: 'seed',
          ),
        );
        env.editor.loadNote(db.getNote(_plan));
        env.editor.onContentChanged('pending text');

        await removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'café');

        expect(
          server.requests.where((r) => r.method == 'DELETE'),
          hasLength(1),
        );
        expect(env.state.lastSavedVersion, 11);
        expect(env.state.contentMd, 'pending text');
        expect(env.editor.loaded.last!.footerTags, ['keep']);
        expect(env.bumps, [11]);
      },
    );
  });

  group('removeTagFromNote edges', () {
    testWidgets(
      'removeTagFromNote on a clean editor takes the stored body and stays clean without a second write',
      (tester) async {
        final db = _vault();
        final cli = _cli(db)
          ..on('tag rm', (call) {
            final id = call.flag('note-id')!;
            // The server drops the footer line of the removed tag (R12).
            db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
              'rewritten body',
              id,
            ]);
            return _applyRm(db, call);
          });
        final env = await _open(tester, db: db, cli: cli);
        env.editor.loadNote(db.getNote(_plan));
        expect(env.state.status, SaveStatus.clean);

        await removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop');

        expect(env.state.contentMd, 'rewritten body');
        expect(env.state.status, SaveStatus.clean);
        expect(env.state.lastSavedVersion, 4);
        env.clock.advance(saveDebounce);
        await tester.pump();
        expect(cli.callsFor('update'), isEmpty);
        expect(env.bumps, [4]);
      },
    );

    testWidgets(
      'removeTagFromNote keeps what was typed while it read the stored body',
      (tester) async {
        final db = _vault();
        final cli = _cli(db);
        final notes = _GatedNotes(db);
        final env = await _open(
          tester,
          db: db,
          cli: cli,
          access: () => LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            cli: cli,
            notes: notes,
          ),
        );
        env.editor.loadNote(db.getNote(_plan));
        final gate = Completer<void>();
        notes.gateNext = gate;

        final removal = removeTagFromNote(
          env.ref,
          note: db.getNote(_plan)!,
          tag: 'drop',
        );
        await tester.pump();
        await tester.pump();
        env.editor.onContentChanged('typed during the read');
        gate.complete();
        await removal;

        expect(env.state.contentMd, 'typed during the read');
        expect(env.state.status, SaveStatus.dirty);
        expect(env.state.lastSavedVersion, 4);
        expect(env.bumps, [4]);
      },
    );

    testWidgets(
      'removeTagFromNote keeps the editor text when the note was deleted during the rebase',
      (tester) async {
        final db = _vault();
        final cli = _cli(db);
        final env = await _open(
          tester,
          db: db,
          cli: cli,
          access: () => LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            cli: cli,
            notes: _MissingNotes(),
          ),
        );
        final open = db.getNote(_plan)!;
        env.editor.loadNote(open);

        await removeTagFromNote(env.ref, note: open, tag: 'drop');

        expect(env.state.contentMd, 'stored text');
        expect(env.state.lastSavedVersion, 4);
        expect(env.editor.activeNoteId, _plan);
        expect(env.bumps, [4]);
      },
    );

    testWidgets(
      'removeTagFromNote bumps once and propagates when the rebase read fails after the write',
      (tester) async {
        final db = _vault();
        final cli = _cli(db);
        final env = await _open(
          tester,
          db: db,
          cli: cli,
          access: () => LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            cli: cli,
            notes: _FailingNotes(),
          ),
        );
        env.editor.loadNote(db.getNote(_plan));
        env.editor.onContentChanged('pending text');

        await expectLater(
          removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop'),
          throwsA(isA<VaultUnreachableException>()),
        );

        expect(cli.callsFor('tag rm'), hasLength(1));
        expect(env.bumps, hasLength(1));
        expect(env.state.contentMd, 'pending text');
      },
    );

    testWidgets('removeTagFromNote with no vault access throws StateError', (
      tester,
    ) async {
      final db = _vault();
      final cli = _cli(db);
      final env = await _open(tester, db: db, cli: cli, access: () => null);

      await expectLater(
        removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop'),
        throwsStateError,
      );

      expect(cli.callsFor('tag rm'), isEmpty);
      expect(env.bumps, isEmpty);
    });
  });

  group('rebaseEditorOnVersion keeps footerTags (D23)', () {
    testWidgets(
      'after a rebase footerTags reflects the removal rather than emptying',
      (tester) async {
        final db = _vault();
        final env = await _open(tester, db: db, cli: _cli(db));
        env.editor.loadNote(db.getNote(_plan));
        expect(env.editor.loaded.last!.footerTags, ['drop', 'keep']);
        env.editor.onContentChanged('pending text');

        await removeTagFromNote(env.ref, note: db.getNote(_plan)!, tag: 'drop');

        final rebased = env.editor.loaded.last!;
        expect(rebased.id, _plan);
        expect(rebased.version, 4);
        expect(rebased.tags, ['keep']);
        expect(rebased.footerTags, ['keep']);
      },
    );

    testWidgets(
      'rebaseEditorOnVersion copies the stored footerTags onto the note it loads',
      (tester) async {
        final db = _vault();
        final stored = Note(
          id: _plan,
          title: 'Plan',
          contentMd: 'stored text',
          frontmatter: '{}',
          version: 5,
          createdAt: 1000,
          updatedAt: 2000,
          tags: const ['a', 'b'],
          footerTags: const ['a', 'b'],
        );
        final env = await _open(
          tester,
          db: db,
          access: () => LocalVaultAccess(
            vaultPath: _vaultA.path,
            db: db,
            notes: _StoredNotes(stored),
          ),
        );
        env.editor.loadNote(db.getNote(_plan));

        await rebaseEditorOnVersion(
          env.ref,
          fallback: db.getNote(_plan)!,
          version: 5,
          content: 'stored text',
        );

        expect(env.editor.loaded.last!.footerTags, ['a', 'b']);
      },
    );
  });
}

/// `getNote` answers from [db]; the first call after [gateNext] is set waits
/// for it.
class _GatedNotes extends LocalNotesAccess {
  _GatedNotes(FakeVaultDb db) : super(vaultPath: _vaultA.path, db: db);

  Completer<void>? gateNext;

  @override
  Future<Note?> getNote(String id) async {
    final gate = gateNext;
    if (gate != null) {
      gateNext = null;
      await gate.future;
    }
    return super.getNote(id);
  }
}

/// The note is gone: `getNote` answers null.
class _MissingNotes extends LocalNotesAccess {
  _MissingNotes() : super(vaultPath: _vaultA.path);

  @override
  Future<Note?> getNote(String id) async => null;
}

/// Reading the note fails as an unreachable hosted server does (L17).
class _FailingNotes extends LocalNotesAccess {
  _FailingNotes() : super(vaultPath: _vaultA.path);

  @override
  Future<Note?> getNote(String id) async => throw unreachableNas;
}

/// Every removal fails as an unreachable hosted server does (L17).
class _UnreachableTags extends LocalTagsAccess {
  _UnreachableTags() : super(vaultPath: _vaultA.path);

  @override
  Future<TagRmResult> removeTag(String noteId, String tag) async =>
      throw unreachableNas;
}

/// `getNote` answers [stored], whatever the id.
class _StoredNotes extends LocalNotesAccess {
  _StoredNotes(this.stored) : super(vaultPath: _vaultA.path);

  final Note stored;

  @override
  Future<Note?> getNote(String id) async => stored;
}
