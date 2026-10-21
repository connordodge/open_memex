// WI #90 (W6): linksOutAsyncProvider and backlinksAsyncProvider read through
// VaultAccess (D13, D14a) and stay as synchronous facades that never show
// another vault's rows. Seeds are raw inserts (test/support/links_seeds.dart).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';
import '../support/links_seeds.dart';
import '../support/vault_access_shapes.dart';

const _vaultA = LocalVaultRef('/tmp/om-90-vault-a');
const _vaultB = LocalVaultRef('/tmp/om-90-vault-b');

FakeVaultDb _seeded() {
  final db = seedLinksFixture(FakeVaultDb.v5());
  addTearDown(db.close);
  return db;
}

/// A container over the real `vaultAccessProvider` (no override) for [vault],
/// reading [db].
ProviderContainer _real(VaultDb? db, {VaultRef? vault = _vaultA}) {
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

/// A container whose `vaultAccessProvider` hands out [notes] per vault, the
/// way two open vaults would each have their own door.
ProviderContainer _switching(Map<VaultRef, LocalNotesAccess> notes) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vaultA),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        final path = vault.localPath;
        if (path == null) return null;
        return LocalVaultAccess(vaultPath: path, notes: notes[vault]);
      }),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void _switchTo(ProviderContainer c, VaultRef? vault) =>
    c.read(currentVaultProvider.notifier).state = vault;

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

List<String> _ids(List<LinkRow> rows) => [for (final r in rows) r.id];

List<String> _titles(List<BacklinkEntry> entries) => [
  for (final e in entries) e.fromTitle,
];

/// Records what the backlinks reader asks for. Doubles extend the local class.
class _Wi90RecordingNotes extends LocalNotesAccess {
  _Wi90RecordingNotes({required super.vaultPath, super.db});

  final inKinds = <String?>[];
  final titleLookups = <List<String>>[];

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) {
    inKinds.add(kind);
    return super.linksInFor(noteId, kind: kind);
  }

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) {
    titleLookups.add(List.of(ids));
    return super.titlesForIds(ids);
  }
}

void main() {
  group('linksOutAsyncProvider', () {
    test(
      'linksOutAsyncProvider yields the same rows as VaultDb linksOutFor on a seeded vault',
      () async {
        final db = _seeded();
        final c = _real(db);

        final scoped = await c.read(linksOutAsyncProvider(L.target).future);

        final today = db.linksOutFor(L.target);
        expect(today, hasLength(5));
        expect(vaultAccessShape(scoped.value), vaultAccessShape(today));
        expect(scoped.vault, _vaultA);
      },
    );

    test('linksOutAsyncProvider is empty for a note with no links', () async {
      final c = _real(_seeded());

      final scoped = await c.read(linksOutAsyncProvider(L.other).future);

      expect(scoped.value, isEmpty);
    });

    test(
      'linksOutAsyncProvider yields an empty list stamped with no vault when none is open',
      () async {
        final c = _real(null, vault: null);

        final scoped = await c.read(linksOutAsyncProvider(L.target).future);

        expect(scoped.value, isEmpty);
        expect(scoped.vault, isNull);
        expect(c.read(linksOutProvider(L.target)), isEmpty);
      },
    );

    test(
      'linksOutAsyncProvider re-reads after a vault revision bump',
      () async {
        final db = _seeded();
        final c = _real(db);
        expect(
          (await c.read(linksOutAsyncProvider(L.other).future)).value,
          isEmpty,
        );

        db.seedLink(L.other, L.alpha, id: 'out-late');
        _bump(c);

        final scoped = await c.read(linksOutAsyncProvider(L.other).future);
        expect(_ids(scoped.value), ['out-late']);
      },
    );

    test(
      'linksOutProvider is empty before the first load completes and equals the rows after',
      () async {
        final db = _seeded();
        final c = _real(db);

        expect(c.read(linksOutProvider(L.target)), isEmpty);

        await c.read(linksOutAsyncProvider(L.target).future);

        expect(
          vaultAccessShape(c.read(linksOutProvider(L.target))),
          vaultAccessShape(db.linksOutFor(L.target)),
        );
      },
    );

    test(
      'linksOutProvider keeps its previous rows while a reload is pending',
      () async {
        final gate = Wi90Gate();
        final notes = Wi90GatedNotes(
          vaultPath: _vaultA.path,
          gate: gate,
          out: [wi90Link('a1', from: 'x', to: 'y', text: 'First')],
        );
        final c = _switching({_vaultA: notes});
        await c.read(linksOutAsyncProvider('x').future);
        expect(_ids(c.read(linksOutProvider('x'))), ['a1']);

        gate.close();
        notes.out = [wi90Link('a2', from: 'x', to: 'y', text: 'Second')];
        _bump(c);
        await pumpEventQueue();

        expect(c.read(linksOutAsyncProvider('x')).isLoading, isTrue);
        expect(_ids(c.read(linksOutProvider('x'))), ['a1']);

        gate.open();
        await c.read(linksOutAsyncProvider('x').future);
        expect(_ids(c.read(linksOutProvider('x'))), ['a2']);
      },
    );

    test(
      'linksOutProvider switching vaults never shows the previous vault rows',
      () async {
        final gateB = Wi90Gate(open: false);
        final c = _switching({
          _vaultA: Wi90GatedNotes(
            vaultPath: _vaultA.path,
            gate: Wi90Gate(),
            out: [wi90Link('a-out', from: 'x', to: 'y')],
          ),
          _vaultB: Wi90GatedNotes(
            vaultPath: _vaultB.path,
            gate: gateB,
            out: [wi90Link('b-out', from: 'x', to: 'y')],
          ),
        });
        await c.read(linksOutAsyncProvider('x').future);
        expect(_ids(c.read(linksOutProvider('x'))), ['a-out']);

        _switchTo(c, _vaultB);
        await pumpEventQueue();

        expect(c.read(linksOutProvider('x')), isEmpty);
        expect(
          currentVaultData(c.read(linksOutAsyncProvider('x')), _vaultB),
          isNull,
        );

        gateB.open();
        final scoped = await c.read(linksOutAsyncProvider('x').future);
        expect(scoped.vault, _vaultB);
        expect(_ids(c.read(linksOutProvider('x'))), ['b-out']);

        _switchTo(c, null);
        await pumpEventQueue();
        expect(c.read(linksOutProvider('x')), isEmpty);
      },
    );

    test(
      'linksOutProvider ignores a late answer from the previous vault',
      () async {
        final gateA = Wi90Gate(open: false);
        final c = _switching({
          _vaultA: Wi90GatedNotes(
            vaultPath: _vaultA.path,
            gate: gateA,
            out: [wi90Link('a-out', from: 'x', to: 'y')],
          ),
          _vaultB: Wi90GatedNotes(
            vaultPath: _vaultB.path,
            gate: Wi90Gate(),
            out: [wi90Link('b-out', from: 'x', to: 'y')],
          ),
        });
        expect(c.read(linksOutProvider('x')), isEmpty);
        await pumpEventQueue();
        expect(gateA.calls, 1);

        _switchTo(c, _vaultB);
        await c.read(linksOutAsyncProvider('x').future);
        gateA.open();
        await pumpEventQueue();

        expect(_ids(c.read(linksOutProvider('x'))), ['b-out']);
        expect(
          (await c.read(linksOutAsyncProvider('x').future)).vault,
          _vaultB,
        );
      },
    );
  });

  group('backlinksAsyncProvider', () {
    test(
      'backlinksAsyncProvider groups incoming links by kind with source titles',
      () async {
        final c = _real(_seeded());

        final scoped = await c.read(backlinksAsyncProvider(L.target).future);

        final groups = scoped.value;
        expect(scoped.vault, _vaultA);
        expect(groups.keys.toSet(), {
          'extends',
          'contradicts',
          'references',
          'zeta-kind',
          'alpha-kind',
        });
        final contradicts = groups['contradicts']!.single;
        expect(contradicts.linkId, 'in-con-mike');
        expect(contradicts.fromNoteId, L.mike);
        expect(contradicts.fromTitle, 'Mike');
        expect(contradicts.kind, 'contradicts');
        expect(contradicts.label, isNull);
        expect(contradicts.source, 'inline_body');
        expect(_titles(groups['zeta-kind']!), ['Alpha']);
        expect(_titles(groups['alpha-kind']!), ['Mike']);
        expect(_titles(groups['references']!), ['Zulu']);
      },
    );

    test(
      'backlinksAsyncProvider sorts source titles within each kind',
      () async {
        final c = _real(_seeded());

        final groups = (await c.read(
          backlinksAsyncProvider(L.target).future,
        )).value;

        // Stored order is by source id (Zulu, Alpha, Mike, gone).
        expect(_titles(groups['extends']!), ['Alpha', 'Mike', 'Zulu', L.gone]);
        expect(
          [for (final e in groups['extends']!) e.fromNoteId],
          [L.alpha, L.mike, L.zulu, L.gone],
        );
      },
    );

    test(
      'backlinksAsyncProvider falls back to the source note id when the title is missing',
      () async {
        final c = _real(_seeded());

        final groups = (await c.read(
          backlinksAsyncProvider(L.target).future,
        )).value;

        final gone = groups['extends']!.singleWhere(
          (e) => e.fromNoteId == L.gone,
        );
        expect(gone.fromTitle, L.gone);
        expect(gone.linkId, 'in-ext-gone');
      },
    );

    test('backlinksAsyncProvider is empty when nothing links in', () async {
      final c = _real(_seeded());

      final scoped = await c.read(backlinksAsyncProvider(L.other).future);

      expect(scoped.value, isEmpty);
      expect(c.read(backlinksProvider(L.other)), isEmpty);
    });

    test(
      'backlinksAsyncProvider reads incoming links of every kind and looks up each source title once',
      () async {
        final db = _seeded();
        final notes = _Wi90RecordingNotes(vaultPath: _vaultA.path, db: db);
        final c = _switching({_vaultA: notes});

        await c.read(backlinksAsyncProvider(L.target).future);

        expect(notes.inKinds, [null]);
        expect(notes.titleLookups, hasLength(1));
        expect(notes.titleLookups.single.toSet(), {
          L.zulu,
          L.alpha,
          L.mike,
          L.gone,
        });
        expect(
          notes.titleLookups.single,
          hasLength(4),
          reason: 'each source id once, not once per link',
        );
      },
    );

    test(
      'backlinksAsyncProvider yields empty groups stamped with no vault when none is open',
      () async {
        final c = _real(null, vault: null);

        final scoped = await c.read(backlinksAsyncProvider(L.target).future);

        expect(scoped.value, isEmpty);
        expect(scoped.vault, isNull);
        expect(c.read(backlinksProvider(L.target)), isEmpty);
      },
    );

    test(
      'backlinksAsyncProvider re-reads after a vault revision bump',
      () async {
        final db = _seeded();
        final c = _real(db);
        expect(
          (await c.read(backlinksAsyncProvider(L.other).future)).value,
          isEmpty,
        );

        db.seedLink(L.mike, L.other, id: 'in-late', kind: 'extends');
        _bump(c);

        final groups = (await c.read(
          backlinksAsyncProvider(L.other).future,
        )).value;
        expect(_titles(groups['extends']!), ['Mike']);
      },
    );

    test(
      'backlinksProvider is empty before the first load completes and equals the groups after',
      () async {
        final c = _real(_seeded());

        expect(c.read(backlinksProvider(L.target)), isEmpty);

        final loaded = (await c.read(
          backlinksAsyncProvider(L.target).future,
        )).value;

        final facade = c.read(backlinksProvider(L.target));
        expect(facade.keys.toSet(), loaded.keys.toSet());
        expect(_titles(facade['extends']!), _titles(loaded['extends']!));
        expect(facade['extends'], hasLength(4));
      },
    );

    test(
      'backlinksProvider keeps its previous groups while a reload is pending',
      () async {
        final gate = Wi90Gate();
        final notes = Wi90GatedNotes(
          vaultPath: _vaultA.path,
          gate: gate,
          incoming: [wi90Link('a1', from: 's1', to: 'x', kind: 'extends')],
          titles: const {'s1': 'First source'},
        );
        final c = _switching({_vaultA: notes});
        await c.read(backlinksAsyncProvider('x').future);
        expect(_titles(c.read(backlinksProvider('x'))['extends']!), [
          'First source',
        ]);

        gate.close();
        notes.incoming = [wi90Link('a2', from: 's2', to: 'x', kind: 'extends')];
        notes.titles = const {'s2': 'Second source'};
        _bump(c);
        await pumpEventQueue();

        expect(c.read(backlinksAsyncProvider('x')).isLoading, isTrue);
        expect(_titles(c.read(backlinksProvider('x'))['extends']!), [
          'First source',
        ]);

        gate.open();
        await c.read(backlinksAsyncProvider('x').future);
        expect(_titles(c.read(backlinksProvider('x'))['extends']!), [
          'Second source',
        ]);
      },
    );

    test(
      'backlinksProvider switching vaults never shows the previous vault rows',
      () async {
        final gateB = Wi90Gate(open: false);
        final c = _switching({
          _vaultA: Wi90GatedNotes(
            vaultPath: _vaultA.path,
            gate: Wi90Gate(),
            incoming: [wi90Link('a-in', from: 's1', to: 'x')],
            titles: const {'s1': 'From vault A'},
          ),
          _vaultB: Wi90GatedNotes(
            vaultPath: _vaultB.path,
            gate: gateB,
            incoming: [wi90Link('b-in', from: 's2', to: 'x')],
            titles: const {'s2': 'From vault B'},
          ),
        });
        await c.read(backlinksAsyncProvider('x').future);
        expect(_titles(c.read(backlinksProvider('x'))['references']!), [
          'From vault A',
        ]);

        _switchTo(c, _vaultB);
        await pumpEventQueue();

        expect(c.read(backlinksProvider('x')), isEmpty);
        expect(
          currentVaultData(c.read(backlinksAsyncProvider('x')), _vaultB),
          isNull,
        );

        gateB.open();
        final scoped = await c.read(backlinksAsyncProvider('x').future);
        expect(scoped.vault, _vaultB);
        expect(_titles(c.read(backlinksProvider('x'))['references']!), [
          'From vault B',
        ]);
      },
    );
  });
}
