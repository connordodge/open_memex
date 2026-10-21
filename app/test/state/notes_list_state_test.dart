// WI #86 (W1): the sidebar note list moves onto VaultAccess (D14a, Req 33).
//
// `notesListAsyncProvider` reads `notes.listNotes(limit: 200)` through
// `vaultAccessProvider`, orders by `sidebarSortProvider` and stamps its
// result with the vault it was loaded for (`VaultScoped`). A reader of it
// (`readScoped`, D14a): empty with no vault and before the first load, the
// previous list during a same-vault reload, and never another vault's rows.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/widgets/sidebar/notes_pane.dart';

import '../support/fake_vault_db.dart';
import '../support/vault_scoped_reads.dart';

const _vaultA = LocalVaultRef('/tmp/om-86-vault-a');
const _vaultB = LocalVaultRef('/tmp/om-86-vault-b');
const _hosted = HostedVaultRef('srv-86', 'work');

/// A notes domain that records each `listNotes` limit and forwards to the
/// real local read (D21: doubles extend the local domain class).
class _Wi86RecordingNotes extends LocalNotesAccess {
  _Wi86RecordingNotes({required super.vaultPath, super.db});

  final limits = <int>[];

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) {
    limits.add(limit);
    return super.listNotes(limit: limit);
  }
}

/// A notes domain whose `listNotes` waits on a gate per call.
class _Wi86GatedNotes extends LocalNotesAccess {
  _Wi86GatedNotes(String vault) : super(vaultPath: vault);

  final gates = <Completer<List<NoteListItem>>>[];

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) {
    final gate = Completer<List<NoteListItem>>();
    gates.add(gate);
    return gate.future;
  }
}

NoteListItem _item(String id, String title, int updatedAt) => NoteListItem(
  id: id,
  title: title,
  snippet: '',
  version: 1,
  updatedAt: updatedAt,
);

/// Rows built at run time (not const), titled [titles], newest first.
List<NoteListItem> _rows(String prefix, List<String> titles) => [
  for (final (i, t) in titles.indexed)
    _item('$prefix-$i', t, 1759500009000 - i * 1000),
];

List<String> _titles(List<NoteListItem> notes) => [
  for (final n in notes) n.title,
];

/// Four notes whose last-edited order differs from both the case-sensitive
/// and the case-insensitive title order.
FakeVaultDb _seededDb() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  db.seedNote(id: 'n-beta', title: 'beta', updatedAt: 1759500004000);
  db.seedNote(id: 'n-delta', title: 'Delta', updatedAt: 1759500003000);
  db.seedNote(id: 'n-alpha', title: 'Alpha', updatedAt: 1759500002000);
  db.seedNote(id: 'n-charlie', title: 'charlie', updatedAt: 1759500001000);
  return db;
}

/// A container over [db] with the real `vaultAccessProvider` (no override).
ProviderContainer _realAccessContainer({
  required VaultRef? vault,
  required FakeVaultDb db,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// A container whose vault access gives each vault in [notes] its own notes
/// domain (a hosted ref gets one too, standing in for #96's hosted access).
ProviderContainer _gatedContainer(
  Map<VaultRef, LocalNotesAccess> notes, {
  VaultRef? start = _vaultA,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => start),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        final domain = notes[vault];
        if (vault == null || domain == null) return null;
        return LocalVaultAccess(vaultPath: domain.vaultPath, notes: domain);
      }),
    ],
  );
  addTearDown(c.dispose);
  // Keep the facade (and through it the reader) alive, as a sidebar would.
  listenScoped(
    c,
    notesListAsyncProvider,
    const <NoteListItem>[],
    (_, _) {},
    fireImmediately: true,
  );
  return c;
}

/// Lets a completed gate reach the reader and the facade.
Future<void> _drain() => pumpEventQueue();

void main() {
  group('notesListAsyncProvider reads (AC1)', () {
    test(
      'notesListAsyncProvider reads the open vault notes through vaultAccessProvider newest edited first',
      () async {
        final c = _realAccessContainer(vault: _vaultA, db: _seededDb());

        final scoped = await c.read(notesListAsyncProvider.future);

        expect(scoped.vault, _vaultA, reason: 'stamped with the open vault');
        expect(_titles(scoped.value), ['beta', 'Delta', 'Alpha', 'charlie']);
      },
    );

    test('notesListAsyncProvider asks notes.listNotes for 200 notes', () async {
      final db = _seededDb();
      final recording = _Wi86RecordingNotes(vaultPath: _vaultA.path, db: db);
      final c = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith((_) => _vaultA),
          vaultDbProvider.overrideWithValue(db),
          memexCliProvider.overrideWithValue(null),
          vaultAccessProvider.overrideWith(
            (ref) => LocalVaultAccess(
              vaultPath: _vaultA.path,
              db: db,
              notes: recording,
            ),
          ),
        ],
      );
      addTearDown(c.dispose);

      final scoped = await c.read(notesListAsyncProvider.future);

      expect(recording.limits, [200]);
      expect(_titles(scoped.value), ['beta', 'Delta', 'Alpha', 'charlie']);
    });

    test(
      'notesListAsyncProvider orders case insensitively by title when the sidebar sort is alphabetical',
      () async {
        final c = _realAccessContainer(vault: _vaultA, db: _seededDb());
        c.read(sidebarSortProvider.notifier).state = NoteSortMode.alphabetical;

        final sorted = await c.read(notesListAsyncProvider.future);
        expect(_titles(sorted.value), ['Alpha', 'beta', 'charlie', 'Delta']);
        expect(sorted.vault, _vaultA);

        // Back to the default: last edited again.
        c.read(sidebarSortProvider.notifier).state = NoteSortMode.lastEdited;
        final edited = await c.read(notesListAsyncProvider.future);
        expect(_titles(edited.value), ['beta', 'Delta', 'Alpha', 'charlie']);
      },
    );

    test(
      'the notes list read follows the sidebar sort once the read completes',
      () async {
        final c = _realAccessContainer(vault: _vaultA, db: _seededDb());
        listenScoped(
          c,
          notesListAsyncProvider,
          const <NoteListItem>[],
          (_, _) {},
          fireImmediately: true,
        );
        await c.read(notesListAsyncProvider.future);
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['beta', 'Delta', 'Alpha', 'charlie'],
        );

        c.read(sidebarSortProvider.notifier).state = NoteSortMode.alphabetical;
        await c.read(notesListAsyncProvider.future);
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Alpha', 'beta', 'charlie', 'Delta'],
        );
      },
    );
  });

  group('the notes list read first load (AC2)', () {
    test('the notes list read is empty with no vault open', () async {
      // A database handle with rows, but no open vault: the read goes
      // through vaultAccessProvider (null), never the handle directly.
      final c = _realAccessContainer(vault: null, db: _seededDb());

      final scoped = await c.read(notesListAsyncProvider.future);

      expect(scoped.vault, isNull);
      expect(scoped.value, isEmpty);
      expect(
        readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
        isEmpty,
      );
    });

    test(
      'the notes list read is empty before the first load completes and then shows the loaded list',
      () async {
        final a = _Wi86GatedNotes(_vaultA.path);
        final c = _gatedContainer({_vaultA: a});

        expect(a.gates, hasLength(1), reason: 'the first read is in flight');
        expect(c.read(notesListAsyncProvider).isLoading, isTrue);
        expect(
          readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          isEmpty,
        );

        a.gates.single.complete(_rows('a', ['Alpha from A', 'Beta from A']));
        await _drain();

        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Alpha from A', 'Beta from A'],
        );
        expect(c.read(notesListAsyncProvider).value?.vault, _vaultA);
      },
    );

    test('a failed first load leaves the notes list read empty', () async {
      final a = _Wi86GatedNotes(_vaultA.path);
      final c = _gatedContainer({_vaultA: a});

      a.gates.single.completeError(StateError('read of A failed'));
      await _drain();

      final value = c.read(notesListAsyncProvider);
      expect(value.hasError, isTrue);
      expect(value.error, isA<StateError>());
      expect(
        readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
        isEmpty,
      );
    });
  });

  group('the notes list read reloads (AC3)', () {
    test(
      'after a vault revision bump the facade keeps the previous list until the new read completes',
      () async {
        final a = _Wi86GatedNotes(_vaultA.path);
        final c = _gatedContainer({_vaultA: a});
        a.gates.single.complete(_rows('a', ['Alpha from A']));
        await _drain();
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Alpha from A'],
        );

        c.read(vaultRevisionProvider.notifier).state++;
        await _drain();

        expect(a.gates, hasLength(2), reason: 'the bump started a new read');
        expect(c.read(notesListAsyncProvider).isLoading, isTrue);
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Alpha from A'],
        );

        a.gates[1].complete(_rows('a', ['Alpha from A', 'New from A']));
        await _drain();
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Alpha from A', 'New from A'],
        );
      },
    );

    test(
      'a failed reload keeps the previous list in the notes list read',
      () async {
        final a = _Wi86GatedNotes(_vaultA.path);
        final c = _gatedContainer({_vaultA: a});
        a.gates.single.complete(_rows('a', ['Alpha from A']));
        await _drain();

        c.read(vaultRevisionProvider.notifier).state++;
        await _drain();
        a.gates[1].completeError(StateError('reload of A failed'));
        await _drain();

        expect(c.read(notesListAsyncProvider).hasError, isTrue);
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Alpha from A'],
        );
      },
    );
  });

  group('vault switch (AC4, D14a)', () {
    test('switching vaults never shows the previous vault rows', () async {
      final a = _Wi86GatedNotes(_vaultA.path);
      final b = _Wi86GatedNotes(_vaultB.path);
      final c = _gatedContainer({_vaultA: a, _vaultB: b});
      a.gates.single.complete(_rows('a', ['Alpha from A', 'Beta from A']));
      await _drain();
      expect(
        _titles(readScoped(c, notesListAsyncProvider, const <NoteListItem>[])),
        ['Alpha from A', 'Beta from A'],
      );

      c.read(currentVaultProvider.notifier).state = _vaultB;
      await _drain();

      expect(b.gates, hasLength(1), reason: 'the switch started a read of B');
      // The reader still carries A's value while B loads: the case under test.
      final pending = c.read(notesListAsyncProvider);
      expect(pending.isLoading, isTrue);
      expect(pending.valueOrNull?.vault, _vaultA);
      expect(
        readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
        isEmpty,
      );

      b.gates.single.complete(_rows('b', ['Gamma from B']));
      await _drain();
      expect(
        _titles(readScoped(c, notesListAsyncProvider, const <NoteListItem>[])),
        ['Gamma from B'],
      );
      expect(c.read(notesListAsyncProvider).value?.vault, _vaultB);

      // And back to A: B's rows never show while A re-reads.
      c.read(currentVaultProvider.notifier).state = _vaultA;
      await _drain();
      expect(a.gates, hasLength(2));
      expect(
        readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
        isEmpty,
      );
      a.gates[1].complete(_rows('a', ['Alpha from A']));
      await _drain();
      expect(
        _titles(readScoped(c, notesListAsyncProvider, const <NoteListItem>[])),
        ['Alpha from A'],
      );
    });

    test(
      'switching from a local vault to a hosted vault never shows the previous vault rows',
      () async {
        final a = _Wi86GatedNotes(_vaultA.path);
        final h = _Wi86GatedNotes('hosted-work');
        final c = _gatedContainer({_vaultA: a, _hosted: h});
        a.gates.single.complete(_rows('a', ['Alpha from A']));
        await _drain();

        c.read(currentVaultProvider.notifier).state = _hosted;
        await _drain();

        expect(h.gates, hasLength(1));
        expect(
          readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          isEmpty,
        );

        h.gates.single.complete(_rows('h', ['Hosted note']));
        await _drain();
        expect(
          _titles(
            readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          ),
          ['Hosted note'],
        );
        expect(c.read(notesListAsyncProvider).value?.vault, _hosted);
      },
    );

    test(
      'closing the vault while a read is pending leaves the facade empty',
      () async {
        final a = _Wi86GatedNotes(_vaultA.path);
        final c = _gatedContainer({_vaultA: a});
        a.gates.single.complete(_rows('a', ['Alpha from A']));
        await _drain();

        c.read(currentVaultProvider.notifier).state = null;
        await _drain();

        expect(
          readScoped(c, notesListAsyncProvider, const <NoteListItem>[]),
          isEmpty,
        );
        final closed = c.read(notesListAsyncProvider).value;
        expect(closed?.vault, isNull);
        expect(closed?.value, isEmpty);
      },
    );
  });

  group('sidebar note list through VaultAsyncView (Req 33)', () {
    Future<_Wi86GatedNotes> pumpView(
      WidgetTester tester, {
      required VaultRef vault,
    }) async {
      final gated = _Wi86GatedNotes('view-vault');
      final container = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith((_) => vault),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
          vaultAccessProvider.overrideWith(
            (ref) => LocalVaultAccess(vaultPath: 'view-vault', notes: gated),
          ),
        ],
      );
      addTearDown(container.dispose);
      tester.platformDispatcher.textScaleFactorTestValue = 0.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildOmTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 268,
                height: 600,
                child: Consumer(
                  builder: (context, ref, _) =>
                      VaultAsyncView<List<NoteListItem>>(
                        value: ref.watch(notesListAsyncProvider),
                        empty: const [],
                        builder: (context, notes) =>
                            NotesPane(notes: notes, onNewNote: () {}),
                      ),
                ),
              ),
            ),
          ),
        ),
      );
      // Never pumpAndSettle: the hosted spinner animates continuously.
      await tester.pump();
      return gated;
    }

    testWidgets(
      'a hosted first load of the note list shows the loading state and then the rows',
      (tester) async {
        final gated = await pumpView(tester, vault: _hosted);

        expect(gated.gates, hasLength(1));
        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
        expect(find.text('no notes yet.'), findsNothing);

        gated.gates.single.complete(_rows('h', ['Hosted note']));
        await tester.pump();
        await tester.pump();

        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(find.byIcon(LucideIcons.loader2), findsNothing);
        expect(find.byKey(const Key('note-list-item-h-0')), findsOneWidget);
      },
    );

    testWidgets(
      'a local first load of the note list shows the no notes yet empty state and no spinner',
      (tester) async {
        final gated = await pumpView(tester, vault: _vaultA);

        expect(gated.gates, hasLength(1));
        expect(find.text('no notes yet.'), findsOneWidget);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);

        gated.gates.single.complete(_rows('a', ['Alpha from A']));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const Key('notes-rail')), findsOneWidget);
        expect(find.byKey(const Key('note-list-item-a-0')), findsOneWidget);
      },
    );
  });
}
