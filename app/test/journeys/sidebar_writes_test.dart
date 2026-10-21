// WI #86 (W1): the sidebar writes ("new note", "new canvas") go through
// VaultAccess wrapped in guardVaultWrite (D14, D14a, Req 33, Req 50), keeping
// their revision bumps and today's local error snackbars; and a note deleted
// from the note menu leaves the migrated notes list.
//
// Journeys over the whole workspace (#18 harness): FakeVaultDb, FakeMemexCli
// and FakeClock seams. The vault access is the real LocalVaultAccess with
// recording notes/canvas domains that extend the local classes (D21) and
// forward to them, so each write reaches the FakeMemexCli as today. Never
// pumpAndSettle the workspace.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/note_cli_fakes.dart';
import '../support/vault_scoped_reads.dart';

const _newNoteId = '01J9Z8Y7X6W5V4T3S2R1Q0P86A';
const _newCanvasId = 'c-86-new';
const _alphaId = '01J9Z8Y7X6W5V4T3S2R1Q0P86B';
const _betaId = '01J9Z8Y7X6W5V4T3S2R1Q0P86C';

const _canvasConfirm = Key('new-canvas-confirm');

/// What the recording domains saw, shared by every `LocalVaultAccess` the
/// overridden `vaultAccessProvider` builds.
class _Wi86Writes {
  _Wi86Writes({this.unreachable});

  /// When set, `addNote` / `createCanvas` throw it instead of writing.
  final VaultUnreachableException? unreachable;

  final noteAdds = <({String? title, String contentMd})>[];
  final canvasCreates = <String>[];

  Override get override => vaultAccessProvider.overrideWith((ref) {
    final path = ref.watch(currentVaultProvider).localPath;
    if (path == null) return null;
    final db = ref.watch(vaultDbProvider);
    final cli = ref.watch(memexCliProvider);
    return LocalVaultAccess(
      vaultPath: path,
      db: db,
      cli: cli,
      notes: _Wi86Notes(this, vaultPath: path, db: db, cli: cli),
      canvas: _Wi86Canvas(this, vaultPath: path, db: db, cli: cli),
    );
  });
}

class _Wi86Notes extends LocalNotesAccess {
  _Wi86Notes(this.writes, {required super.vaultPath, super.db, super.cli});

  final _Wi86Writes writes;

  @override
  Future<String> addNote({
    String? title,
    List<String> tags = const [],
    required String contentMd,
    String? role,
  }) async {
    writes.noteAdds.add((title: title, contentMd: contentMd));
    final unreachable = writes.unreachable;
    if (unreachable != null) throw unreachable;
    return super.addNote(
      title: title,
      tags: tags,
      contentMd: contentMd,
      role: role,
    );
  }
}

class _Wi86Canvas extends LocalCanvasAccess {
  _Wi86Canvas(this.writes, {required super.vaultPath, super.db, super.cli});

  final _Wi86Writes writes;

  @override
  Future<CanvasInfo> createCanvas({required String title}) async {
    writes.canvasCreates.add(title);
    final unreachable = writes.unreachable;
    if (unreachable != null) throw unreachable;
    return super.createCanvas(title: title);
  }
}

/// A CLI whose `add` and `canvas new` behave like the real ones against [db].
FakeMemexCli _writingCli(FakeVaultDb db) => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..on('add', (call) {
    db.seedNote(
      id: _newNoteId,
      title: call.flag('title') ?? '',
      content: call.stdinBody ?? '',
      updatedAt: 1759500009000,
    );
    return FakeMemexCli.ok('note_id: $_newNoteId\n');
  })
  ..on('canvas new', (call) {
    db.db.execute(
      'INSERT INTO canvases (id, title, created_at, updated_at, version) '
      'VALUES (?, ?, ?, ?, ?)',
      [_newCanvasId, call.flag('title'), 1759500009000, 1759500009000, 1],
    );
    return FakeMemexCli.ok(
      '{"canvas_id":"$_newCanvasId","title":"${call.flag('title')}",'
      '"version":1,"created_at":1759500009000,"updated_at":1759500009000}',
    );
  });

/// A CLI whose `add` and `canvas new` fail with a C1 error.
FakeMemexCli _failingCli() => FakeMemexCli()
  ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
  ..on('add', (_) => FakeMemexCli.error('internal', 'disk full'))
  ..on('canvas new', (_) => FakeMemexCli.error('internal', 'disk full'));

/// Pumps the workspace with [writes] recording the vault writes, then closes
/// the launch tab (#22) so each journey starts from an empty workspace.
Future<WorkspaceHarness> _pump(
  WidgetTester tester, {
  required _Wi86Writes writes,
  FakeVaultDb? db,
  FakeMemexCli? cli,
  bool memexConfigured = true,
}) async {
  final vaultDb = db ?? FakeVaultDb.v5();
  final h = await pumpWorkspace(
    tester,
    db: vaultDb,
    cli: cli ?? _writingCli(vaultDb),
    memexConfigured: memexConfigured,
    overrides: [writes.override],
  );
  final tabs = h.read(tabsProvider.notifier);
  for (final tab in [...h.read(tabsProvider).tabs]) {
    tabs.close(tab);
  }
  await pumpFrames(tester);
  return h;
}

/// The sidebar's "new note": the Workspace's `onNewNote` callback.
Future<void> _newNote(WidgetTester tester) async {
  tester.widget<Sidebar>(find.byType(Sidebar)).onNewNote();
  await pumpFrames(tester);
}

/// The canvases header "+ new" (the second "+ NEW" in the sidebar; the
/// first is the vaults header).
Finder get _newCanvasButton => find
    .descendant(of: find.byType(Sidebar), matching: find.text('+ NEW'))
    .at(1);

/// Taps the canvases "+ new", enters [title] and confirms.
Future<void> _newCanvas(WidgetTester tester, String title) async {
  await tester.tap(_newCanvasButton);
  await pumpFrames(tester);
  expect(find.byKey(_canvasConfirm), findsOneWidget);
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    title,
  );
  await tester.tap(find.byKey(_canvasConfirm));
  await pumpFrames(tester);
}

Finder _textStarting(String prefix) => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').startsWith(prefix),
);

void main() {
  group('new note through VaultAccess (AC6)', () {
    testWidgets(
      'new note adds an Untitled note through VaultAccess bumps the vault revision once and opens its tab',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes);
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newNote(tester);

        expect(writes.noteAdds, [
          (title: 'Untitled', contentMd: '# Untitled\n\n'),
        ]);
        final call = h.cli.callsFor('add').single;
        expect(call.args, [
          'add',
          '--vault',
          h.vaultPath,
          '--title',
          'Untitled',
        ]);
        expect(call.stdinBody, '# Untitled\n\n');
        expect(h.read(vaultRevisionProvider), revisionBefore + 1);
        expect(h.read(activeTabProvider), const NoteTab(_newNoteId));
        expect(_textStarting('Could not create note'), findsNothing);
      },
    );
  });

  group('new canvas through VaultAccess (AC7)', () {
    testWidgets(
      'new canvas with a confirmed title creates the canvas through VaultAccess bumps the vault revision once and opens its tab',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes);
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newCanvas(tester, 'Fresh board');

        expect(writes.canvasCreates, ['Fresh board']);
        expect(h.cli.callsFor('canvas new').single.args, [
          'canvas',
          'new',
          '--vault',
          h.vaultPath,
          '--title',
          'Fresh board',
        ]);
        expect(h.read(vaultRevisionProvider), revisionBefore + 1);
        expect(h.read(activeTabProvider), const CanvasTab(_newCanvasId));
        expect(_textStarting('Could not create canvas'), findsNothing);
      },
    );

    testWidgets('cancelling the new canvas dialog creates nothing', (
      tester,
    ) async {
      final writes = _Wi86Writes();
      final h = await _pump(tester, writes: writes);
      final revisionBefore = h.read(vaultRevisionProvider);

      await tester.tap(_newCanvasButton);
      await pumpFrames(tester);
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester);

      expect(writes.canvasCreates, isEmpty);
      expect(h.cli.callsFor('canvas new'), isEmpty);
      expect(h.read(vaultRevisionProvider), revisionBefore);
      expect(h.read(tabsProvider).tabs, isEmpty);
    });
  });

  group('local CLI failures keep the Could not create snackbars (AC8)', () {
    testWidgets(
      'a failed local new note shows Could not create note with the error and opens no tab',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes, cli: _failingCli());
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newNote(tester);

        expect(writes.noteAdds, hasLength(1), reason: 'through VaultAccess');
        expect(
          find.text('Could not create note: add failed: disk full'),
          findsOneWidget,
        );
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(h.read(vaultRevisionProvider), revisionBefore);
      },
    );

    testWidgets(
      'a failed local new canvas shows Could not create canvas with the error and opens no tab',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes, cli: _failingCli());
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newCanvas(tester, 'Fresh board');

        expect(writes.canvasCreates, ['Fresh board'], reason: 'VaultAccess');
        expect(
          find.text('Could not create canvas: canvas new failed: disk full'),
          findsOneWidget,
        );
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(h.read(vaultRevisionProvider), revisionBefore);
      },
    );
  });

  group('unreachable vault server writes (AC9, Req 50)', () {
    for (final (name, mayHaveCommitted, snackbar) in [
      (
        'an unreachable new note shows the could not reach snackbar instead of Could not create note and opens no tab',
        false,
        "couldn't reach nas. try again.",
      ),
      (
        'a new note that may have committed shows the could not confirm snackbar instead of Could not create note and opens no tab',
        true,
        "couldn't confirm with nas — check before trying again",
      ),
    ]) {
      testWidgets(name, (tester) async {
        final writes = _Wi86Writes(
          unreachable: VaultUnreachableException(
            serverName: ['n', 'a', 's'].join(),
            mayHaveCommitted: mayHaveCommitted,
          ),
        );
        final h = await _pump(tester, writes: writes);
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newNote(tester);

        expect(writes.noteAdds, hasLength(1));
        expect(find.text(snackbar), findsOneWidget);
        expect(_textStarting('Could not create note'), findsNothing);
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(h.cli.callsFor('add'), isEmpty);
        // guardVaultWrite returned null: no bump, even when the write may
        // have committed. The revision poll (Req 22-24) shows a committed
        // write, not the write site.
        expect(h.read(vaultRevisionProvider), revisionBefore);
      });
    }

    for (final (name, mayHaveCommitted, snackbar) in [
      (
        'an unreachable new canvas shows the could not reach snackbar instead of Could not create canvas and opens no tab',
        false,
        "couldn't reach nas. try again.",
      ),
      (
        'a new canvas that may have committed shows the could not confirm snackbar instead of Could not create canvas and opens no tab',
        true,
        "couldn't confirm with nas — check before trying again",
      ),
    ]) {
      testWidgets(name, (tester) async {
        final writes = _Wi86Writes(
          unreachable: VaultUnreachableException(
            serverName: ['n', 'a', 's'].join(),
            mayHaveCommitted: mayHaveCommitted,
          ),
        );
        final h = await _pump(tester, writes: writes);
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newCanvas(tester, 'Fresh board');

        expect(writes.canvasCreates, ['Fresh board']);
        expect(find.text(snackbar), findsOneWidget);
        expect(_textStarting('Could not create canvas'), findsNothing);
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(h.cli.callsFor('canvas new'), isEmpty);
        expect(h.read(vaultRevisionProvider), revisionBefore);
      });
    }
  });

  group('the new canvas dialog outlives the sidebar', () {
    testWidgets(
      'closing the vault while the new canvas dialog is open creates no canvas',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes);
        final revisionBefore = h.read(vaultRevisionProvider);

        await tester.tap(_newCanvasButton);
        await pumpFrames(tester);
        expect(find.byKey(_canvasConfirm), findsOneWidget);

        // The vault closes under the open dialog: the picker replaces the
        // workspace and the sidebar that asked for the title unmounts.
        h.container.read(currentVaultProvider.notifier).state = null;
        await pumpFrames(tester);
        expect(find.byType(Sidebar), findsNothing);
        expect(find.byKey(_canvasConfirm), findsOneWidget);

        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'Late board',
        );
        await tester.tap(find.byKey(_canvasConfirm));
        await pumpFrames(tester);

        expect(writes.canvasCreates, isEmpty);
        expect(h.cli.callsFor('canvas new'), isEmpty);
        expect(h.read(vaultRevisionProvider), revisionBefore);
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(_textStarting('Could not create canvas'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('the real vault access with no override (AC6, AC7)', () {
    testWidgets(
      'new note and new canvas through the real vault access send the CLI calls of today',
      (tester) async {
        final db = FakeVaultDb.v5();
        final h = await pumpWorkspace(tester, db: db, cli: _writingCli(db));
        final tabs = h.read(tabsProvider.notifier);
        for (final tab in [...h.read(tabsProvider).tabs]) {
          tabs.close(tab);
        }
        await pumpFrames(tester);
        expect(h.read(vaultAccessProvider), isA<LocalVaultAccess>());
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newNote(tester);

        final add = h.cli.callsFor('add').single;
        expect(add.args, [
          'add',
          '--vault',
          h.vaultPath,
          '--title',
          'Untitled',
        ]);
        expect(add.stdinBody, '# Untitled\n\n');
        expect(h.read(vaultRevisionProvider), revisionBefore + 1);
        expect(h.read(activeTabProvider), const NoteTab(_newNoteId));

        await _newCanvas(tester, 'Fresh board');

        expect(h.cli.callsFor('canvas new').single.args, [
          'canvas',
          'new',
          '--vault',
          h.vaultPath,
          '--title',
          'Fresh board',
        ]);
        expect(h.read(vaultRevisionProvider), revisionBefore + 2);
        expect(h.read(activeTabProvider), const CanvasTab(_newCanvasId));
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });

  group('no memex binary configured (AC10)', () {
    testWidgets(
      'with no memex binary new note does nothing and shows no snackbar',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes, memexConfigured: false);
        expect(h.read(vaultAccessProvider)?.canWrite, isFalse);
        final revisionBefore = h.read(vaultRevisionProvider);

        await _newNote(tester);

        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(h.read(vaultRevisionProvider), revisionBefore);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'with no memex binary the canvases new button opens no dialog and creates nothing',
      (tester) async {
        final writes = _Wi86Writes();
        final h = await _pump(tester, writes: writes, memexConfigured: false);
        final revisionBefore = h.read(vaultRevisionProvider);

        await tester.tap(_newCanvasButton);
        await pumpFrames(tester);

        expect(find.byKey(_canvasConfirm), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(writes.canvasCreates, isEmpty);
        expect(h.read(tabsProvider).tabs, isEmpty);
        expect(h.read(vaultRevisionProvider), revisionBefore);
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });

  group('delete from the note menu (AC5)', () {
    testWidgets(
      'after deleting a note from the note menu the notes list no longer contains it',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(
            id: _alphaId,
            title: 'Alpha note',
            version: 7,
            updatedAt: 1759500002000,
          )
          ..seedNote(
            id: _betaId,
            title: 'Beta note',
            version: 3,
            updatedAt: 1759500001000,
          );
        final cli = FakeMemexCli()
          ..on(
            'settings get',
            (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout),
          )
          ..onRm(db);
        final h = await _pump(tester, writes: _Wi86Writes(), db: db, cli: cli);
        listenScoped(
          h.container,
          notesListAsyncProvider,
          const <NoteListItem>[],
          (_, _) {},
        );
        await pumpFrames(tester);
        List<String> ids() => [
          for (final n in readScoped(
            h.container,
            notesListAsyncProvider,
            const <NoteListItem>[],
          ))
            n.id,
        ];
        expect(ids(), [_alphaId, _betaId]);

        // Topics mode lists role-less notes under Unsorted (#24).
        await tester.tap(find.byKey(const Key('sidebar-mode-topics')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('topics-unsorted-$_alphaId')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('note-menu-button')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('note-menu-delete')));
        await pumpFrames(tester);
        await tester.tap(find.byKey(const Key('delete-note-confirm')));
        await pumpFrames(tester);

        expect(h.cli.callsFor('rm'), hasLength(1));
        expect(ids(), [_betaId]);
        final scoped = await h.read(notesListAsyncProvider.future);
        expect([for (final NoteListItem n in scoped.value) n.id], [_betaId]);
      },
    );
  });
}
