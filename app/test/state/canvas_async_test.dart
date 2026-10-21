// WI #89 (W5): the canvas readers move onto VaultAccess (D13, D14a, Req 33).
// `canvasesAsyncProvider` / `canvasDetailAsyncProvider` return data stamped
// with the vault it was read for (`VaultScoped`). Readers never show another
// vault's data: these tests read them the way a reader renders them
// (`readScoped`, D14a). The sidebar rail and the canvas tab chip read them
// too.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/topics_reads.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/topics_state.dart';
import 'package:open_memex_app/src/state/topics_tree.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart';
import '../support/canvas_robot.dart';
import '../support/canvas_seeds.dart';
import '../support/fake_vault_db.dart';
import '../support/vault_scoped_reads.dart';

const _a = LocalVaultRef('/tmp/om-89-vault-a');
const _b = LocalVaultRef('/tmp/om-89-vault-b');
const _hostedA = HostedVaultRef('srv-89', 'hosted-a');

List<String> _ids(List<CanvasRow> rows) => [for (final r in rows) r.canvasId];

/// A container over a real [FakeVaultDb] for [vault] (through the real
/// `vaultAccessProvider`).
ProviderContainer _dbContainer(FakeVaultDb db, {VaultRef? vault = _a}) {
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A container whose vaults serve the given canvas doubles.
ProviderContainer _doubleContainer(
  Map<VaultRef, Wi89Canvas> canvases, {
  VaultRef? first,
}) {
  final container = ProviderContainer(
    overrides: wi89DoubleOverrides(
      canvases: canvases,
      first: first ?? canvases.keys.first,
    ),
  );
  addTearDown(container.dispose);
  return container;
}

FakeVaultDb _fixtureDb() {
  final db = seedCanvasFixture(FakeVaultDb.v5());
  addTearDown(db.close);
  return db;
}

/// Keeps the canvas reads alive and tracking, as a mounted widget would.
void _keepAlive(ProviderContainer c, [String? detailId]) {
  listenScoped(c, canvasesAsyncProvider, const <CanvasRow>[], (_, _) {});
  if (detailId != null) {
    listenScoped(c, canvasDetailAsyncProvider(detailId), null, (_, _) {});
  }
}

void main() {
  group('canvasesAsyncProvider', () {
    test(
      'canvasesAsyncProvider lists canvases newest updated first with their node counts',
      () async {
        final c = _dbContainer(_fixtureDb());

        final scoped = await c.read(canvasesAsyncProvider.future);

        expect(scoped.vault, _a);
        expect(_ids(scoped.value), [
          C89.newer,
          C89.middle,
          C89.older,
          C89.tieA,
          C89.tieB,
        ]);
        expect(
          [for (final r in scoped.value) r.title],
          ['Newer', 'Middle', 'Older', 'Tie A', 'Tie B'],
        );
        expect([for (final r in scoped.value) r.nodeCount], [2, 1, 0, 0, 0]);
        expect(scoped.value.first.version, 4);
      },
    );

    test(
      'canvasesAsyncProvider reads through the canvas domain of VaultAccess',
      () async {
        final row = wi89CanvasRow(
          'cv-from-access',
          'From access',
          nodeCount: 3,
        );
        final canvas = Wi89Canvas(canvases: [row]);
        final c = _doubleContainer({_a: canvas});

        final scoped = await c.read(canvasesAsyncProvider.future);

        expect(scoped.vault, _a);
        expect(scoped.value, [same(row)]);
        expect(canvas.listCalls, 1);
      },
    );

    test('canvasesAsyncProvider reads again on every revision bump', () async {
      final canvas = Wi89Canvas(canvases: [wi89CanvasRow('c1', 'One')]);
      final c = _doubleContainer({_a: canvas});
      expect(_ids((await c.read(canvasesAsyncProvider.future)).value), ['c1']);
      expect(canvas.listCalls, 1);

      canvas.canvases = [
        wi89CanvasRow('c2', 'Two'),
        wi89CanvasRow('c1', 'One'),
      ];
      c.read(vaultRevisionProvider.notifier).state++;
      final scoped = await c.read(canvasesAsyncProvider.future);

      expect(canvas.listCalls, 2);
      expect(_ids(scoped.value), ['c2', 'c1']);
    });

    test(
      'canvasesAsyncProvider yields an empty list stamped with no vault when no vault is open',
      () async {
        final c = _dbContainer(_fixtureDb(), vault: null);

        final scoped = await c.read(canvasesAsyncProvider.future);

        expect(scoped.vault, isNull);
        expect(scoped.value, isEmpty);
      },
    );
  });

  group('the canvases read', () {
    test('the canvases read yields an empty list with no vault', () async {
      final c = _dbContainer(_fixtureDb(), vault: null);
      _keepAlive(c);

      expect(
        readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
        isEmpty,
      );
      await c.read(canvasesAsyncProvider.future);
      expect(
        readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
        isEmpty,
      );
    });

    test(
      'the canvases read yields an empty list on a vault without canvas tables',
      () async {
        final db = FakeVaultDb.v5()..dropCanvasTables();
        addTearDown(db.close);
        final c = _dbContainer(db);
        _keepAlive(c);

        await c.read(canvasesAsyncProvider.future);

        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          isEmpty,
        );
      },
    );

    test(
      'the canvases read yields an empty list before the first load completes and the rows after',
      () async {
        final canvas = _held();
        final c = _doubleContainer({_a: canvas});
        _keepAlive(c);

        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          isEmpty,
        );
        await pumpEventQueue();
        expect(canvas.heldLists, hasLength(1));
        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          isEmpty,
        );

        canvas.heldLists.single.complete([
          wi89CanvasRow('c1', 'One'),
          wi89CanvasRow('c2', 'Two'),
        ]);
        await c.read(canvasesAsyncProvider.future);

        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c1', 'c2'],
        );
      },
    );

    test(
      'the canvases read keeps its rows during a reload until the new list arrives',
      () async {
        final canvas = Wi89Canvas(canvases: [wi89CanvasRow('c1', 'One')]);
        final c = _doubleContainer({_a: canvas});
        _keepAlive(c);
        await c.read(canvasesAsyncProvider.future);
        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c1'],
        );

        canvas.hold = true;
        c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();
        expect(canvas.heldLists, hasLength(1));
        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c1'],
        );

        canvas.heldLists.single.complete([wi89CanvasRow('c2', 'Two')]);
        await c.read(canvasesAsyncProvider.future);

        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c2'],
        );
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the canvases facade',
      () async {
        final a = Wi89Canvas(canvases: [wi89CanvasRow('c-a', 'Vault A')]);
        final b = _held();
        final c = _doubleContainer({_a: a, _b: b}, first: _a);
        _keepAlive(c);
        await c.read(canvasesAsyncProvider.future);
        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c-a'],
        );

        c.read(currentVaultProvider.notifier).state = _b;
        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          isEmpty,
        );
        await pumpEventQueue();
        expect(b.heldLists, hasLength(1));
        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          isEmpty,
        );

        b.heldLists.single.complete([wi89CanvasRow('c-b', 'Vault B')]);
        await c.read(canvasesAsyncProvider.future);

        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c-b'],
        );
      },
    );

    test(
      'a late list from the previous vault never shows in the canvases facade after a switch',
      () async {
        final a = _held();
        final b = _held();
        final c = _doubleContainer({_a: a, _b: b}, first: _a);
        _keepAlive(c);
        await pumpEventQueue();
        expect(a.heldLists, hasLength(1));

        c.read(currentVaultProvider.notifier).state = _b;
        await pumpEventQueue();
        a.heldLists.single.complete([wi89CanvasRow('c-a', 'Vault A')]);
        await pumpEventQueue();

        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          isEmpty,
        );
        b.heldLists.single.complete([wi89CanvasRow('c-b', 'Vault B')]);
        await c.read(canvasesAsyncProvider.future);
        expect(
          _ids(readScoped(c, canvasesAsyncProvider, const <CanvasRow>[])),
          ['c-b'],
        );
      },
    );
  });

  group('canvasDetailAsyncProvider', () {
    test(
      'canvasDetailAsyncProvider hydrates the nodes and edges of a canvas through VaultAccess',
      () async {
        final c = _dbContainer(_fixtureDb());

        final scoped = await c.read(
          canvasDetailAsyncProvider(C89.newer).future,
        );

        expect(scoped.vault, _a);
        final detail = scoped.value!;
        expect(detail.canvasId, C89.newer);
        expect(detail.title, 'Newer');
        expect(detail.version, 4);
        expect([for (final n in detail.nodes) n.noteId], [C89.beta, C89.alpha]);
        expect([for (final n in detail.nodes) n.noteTitle], ['Beta', 'Alpha']);
        expect(
          [for (final n in detail.nodes) (n.x, n.y)],
          [(300.0, 40.25), (10.5, 20.0)],
        );
        expect(detail.edges, hasLength(1));
        final edge = detail.edges.single;
        expect(edge.linkId, C89.link);
        expect(edge.fromNoteId, C89.alpha);
        expect(edge.toNoteId, C89.beta);
        expect(edge.kind, 'references');
        expect(edge.label, 'ties');
      },
    );

    test('canvasDetailAsyncProvider yields null for an unknown id', () async {
      final c = _dbContainer(_fixtureDb());

      final scoped = await c.read(canvasDetailAsyncProvider('no-such').future);

      expect(scoped.vault, _a);
      expect(scoped.value, isNull);
    });

    test(
      'canvasDetailAsyncProvider reads through the canvas domain of VaultAccess one canvas at a time',
      () async {
        final detail = wi89BoardDetail('cv-x');
        final canvas = Wi89Canvas(details: {'cv-x': detail});
        final c = _doubleContainer({_a: canvas});

        final scoped = await c.read(canvasDetailAsyncProvider('cv-x').future);
        final other = await c.read(canvasDetailAsyncProvider('cv-y').future);

        expect(scoped.value, same(detail));
        expect(other.value, isNull);
        expect(canvas.detailCalls, ['cv-x', 'cv-y']);
      },
    );

    test(
      'canvasDetailAsyncProvider reads again on every revision bump',
      () async {
        final canvas = Wi89Canvas(
          details: {'cv-x': wi89Detail('cv-x', title: 'Before')},
        );
        final c = _doubleContainer({_a: canvas});
        expect(
          (await c.read(canvasDetailAsyncProvider('cv-x').future)).value!.title,
          'Before',
        );

        canvas.details['cv-x'] = wi89Detail('cv-x', title: 'After');
        c.read(vaultRevisionProvider.notifier).state++;
        final scoped = await c.read(canvasDetailAsyncProvider('cv-x').future);

        expect(scoped.value!.title, 'After');
      },
    );
  });

  group('the canvas detail read', () {
    test(
      'the canvas detail read yields null before the first load and the detail after',
      () async {
        final detail = wi89BoardDetail('cv-x');
        final canvas = _held();
        canvas.details['cv-x'] = detail;
        final c = _doubleContainer({_a: canvas});
        _keepAlive(c, 'cv-x');

        expect(readScoped(c, canvasDetailAsyncProvider('cv-x'), null), isNull);
        await pumpEventQueue();
        expect(canvas.heldDetails, hasLength(1));
        expect(readScoped(c, canvasDetailAsyncProvider('cv-x'), null), isNull);

        canvas.heldDetails.single.complete(detail);
        await c.read(canvasDetailAsyncProvider('cv-x').future);

        expect(
          readScoped(c, canvasDetailAsyncProvider('cv-x'), null),
          same(detail),
        );
      },
    );

    test(
      'the canvas detail read yields null for an unknown id and on a vault without canvas tables',
      () async {
        final c = _dbContainer(_fixtureDb());
        _keepAlive(c, 'no-such');
        await c.read(canvasDetailAsyncProvider('no-such').future);
        expect(
          readScoped(c, canvasDetailAsyncProvider('no-such'), null),
          isNull,
        );

        final bare = FakeVaultDb.v5()..dropCanvasTables();
        addTearDown(bare.close);
        final d = _dbContainer(bare);
        _keepAlive(d, C89.newer);
        await d.read(canvasDetailAsyncProvider(C89.newer).future);
        expect(
          readScoped(d, canvasDetailAsyncProvider(C89.newer), null),
          isNull,
        );
      },
    );

    test('the canvas detail read yields null with no vault', () async {
      final c = _dbContainer(_fixtureDb(), vault: null);
      _keepAlive(c, C89.newer);

      await c.read(canvasDetailAsyncProvider(C89.newer).future);

      expect(readScoped(c, canvasDetailAsyncProvider(C89.newer), null), isNull);
    });

    test(
      'the canvas detail read keeps its detail during a reload until the new detail arrives',
      () async {
        final canvas = Wi89Canvas(
          details: {'cv-x': wi89Detail('cv-x', title: 'One')},
        );
        final c = _doubleContainer({_a: canvas});
        _keepAlive(c, 'cv-x');
        await c.read(canvasDetailAsyncProvider('cv-x').future);
        expect(
          readScoped(c, canvasDetailAsyncProvider('cv-x'), null)!.title,
          'One',
        );

        canvas.hold = true;
        c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();
        expect(canvas.heldDetails, hasLength(1));
        expect(
          readScoped(c, canvasDetailAsyncProvider('cv-x'), null)!.title,
          'One',
        );

        canvas.heldDetails.single.complete(wi89Detail('cv-x', title: 'Two'));
        await c.read(canvasDetailAsyncProvider('cv-x').future);

        expect(
          readScoped(c, canvasDetailAsyncProvider('cv-x'), null)!.title,
          'Two',
        );
      },
    );

    test(
      'switching vaults never shows the previous vault rows in the canvas detail facade',
      () async {
        final a = Wi89Canvas(
          details: {'cv-x': wi89Detail('cv-x', title: 'Vault A')},
        );
        final b = _held();
        final c = _doubleContainer({_a: a, _b: b}, first: _a);
        _keepAlive(c, 'cv-x');
        await c.read(canvasDetailAsyncProvider('cv-x').future);
        expect(
          readScoped(c, canvasDetailAsyncProvider('cv-x'), null)!.title,
          'Vault A',
        );

        c.read(currentVaultProvider.notifier).state = _b;
        expect(readScoped(c, canvasDetailAsyncProvider('cv-x'), null), isNull);
        await pumpEventQueue();
        expect(b.heldDetails, hasLength(1));
        expect(readScoped(c, canvasDetailAsyncProvider('cv-x'), null), isNull);

        b.heldDetails.single.complete(wi89Detail('cv-x', title: 'Vault B'));
        await c.read(canvasDetailAsyncProvider('cv-x').future);

        expect(
          readScoped(c, canvasDetailAsyncProvider('cv-x'), null)!.title,
          'Vault B',
        );
      },
    );
  });

  group('sidebar canvases rail', () {
    // WI #105 (A12, D14a): the rail renders through VaultAsyncView, so a
    // hosted first load shows the loading state; a local one never does.
    for (final (name, vault, hosted) in [
      (
        'sidebar canvases rail shows no canvases yet and a zero count with no spinner on a local first load, then its rows',
        _a,
        false,
      ),
      (
        'sidebar canvases rail shows the loading state and a zero count on a hosted first load, then its rows',
        _hostedA,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final canvas = _held();
        final c = await _pumpSidebar(tester, {vault: canvas});

        expect(canvas.heldLists, hasLength(1));
        expect(
          find.text('no canvases yet.'),
          hosted ? findsNothing : findsOneWidget,
        );
        expect(_canvasCount(tester), 0);
        expect(find.byKey(const Key('canvases-rail')), findsNothing);
        expect(
          find.byKey(vaultAsyncLoadingKey),
          hosted ? findsOneWidget : findsNothing,
        );
        if (!hosted) {
          expect(find.byType(CircularProgressIndicator), findsNothing);
        }

        canvas.heldLists.single.complete([
          wi89CanvasRow('c1', 'Board one', nodeCount: 4),
          wi89CanvasRow('c2', 'Board two'),
        ]);
        await tester.pump();
        await tester.pump();

        expect(find.text('no canvases yet.'), findsNothing);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(find.byKey(const Key('canvas-row-c1')), findsOneWidget);
        expect(find.byKey(const Key('canvas-row-c2')), findsOneWidget);
        expect(find.text('Board one'), findsOneWidget);
        expect(_canvasCount(tester), 2);
        expect(
          readScoped(c, canvasesAsyncProvider, const <CanvasRow>[]),
          hasLength(2),
        );
      });
    }

    testWidgets(
      'sidebar canvases rail shows its rows and count from the vault database through VaultAccess',
      (tester) async {
        final db = _fixtureDb();
        await _pumpSidebarOverDb(tester, db);

        expect(find.text('no canvases yet.'), findsNothing);
        for (final id in [
          C89.newer,
          C89.middle,
          C89.older,
          C89.tieA,
          C89.tieB,
        ]) {
          expect(find.byKey(Key('canvas-row-$id')), findsOneWidget);
        }
        expect(_canvasCount(tester), 5);
      },
    );

    testWidgets(
      'sidebar canvases rail shows no canvases yet for a vault without canvases',
      (tester) async {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        await _pumpSidebarOverDb(tester, db);

        expect(find.text('no canvases yet.'), findsOneWidget);
        expect(_canvasCount(tester), 0);
      },
    );

    testWidgets(
      'sidebar canvases rail keeps its rows during a reload until the new list arrives',
      (tester) async {
        final canvas = Wi89Canvas(canvases: [wi89CanvasRow('c1', 'Board one')]);
        final c = await _pumpSidebar(tester, {_a: canvas});
        expect(find.byKey(const Key('canvas-row-c1')), findsOneWidget);

        canvas.hold = true;
        c.read(vaultRevisionProvider.notifier).state++;
        await tester.pump();
        await tester.pump();

        expect(canvas.heldLists, hasLength(1));
        expect(find.byKey(const Key('canvas-row-c1')), findsOneWidget);
        expect(find.text('no canvases yet.'), findsNothing);
        expect(_canvasCount(tester), 1);

        canvas.heldLists.single.complete([
          wi89CanvasRow('c2', 'Board two'),
          wi89CanvasRow('c3', 'Board three'),
        ]);
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const Key('canvas-row-c1')), findsNothing);
        expect(find.byKey(const Key('canvas-row-c2')), findsOneWidget);
        expect(find.byKey(const Key('canvas-row-c3')), findsOneWidget);
        expect(_canvasCount(tester), 2);
      },
    );

    for (final (name, first, second) in [
      (
        'switching vaults never shows the previous vault rows in the canvases rail',
        _a,
        _b,
      ),
      (
        'switching hosted vaults never shows the previous vault rows in the canvases rail',
        _hostedA,
        HostedVaultRef('srv-89', 'hosted-b'),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = Wi89Canvas(canvases: [wi89CanvasRow('c-a', 'Vault A board')]);
        final b = _held();
        final c = await _pumpSidebar(tester, {
          first: a,
          second: b,
        }, first: first);
        expect(find.byKey(const Key('canvas-row-c-a')), findsOneWidget);
        expect(_canvasCount(tester), 1);

        c.read(currentVaultProvider.notifier).state = second;
        await tester.pump();
        await tester.pump();

        expect(b.heldLists, hasLength(1));
        expect(find.byKey(const Key('canvas-row-c-a')), findsNothing);
        expect(find.text('Vault A board'), findsNothing);
        expect(
          find.text('no canvases yet.'),
          second is HostedVaultRef ? findsNothing : findsOneWidget,
        );
        expect(
          find.byKey(vaultAsyncLoadingKey),
          second is HostedVaultRef ? findsOneWidget : findsNothing,
          reason:
              'a hosted first load of the new vault shows the loading state',
        );
        expect(_canvasCount(tester), 0);

        b.heldLists.single.complete([wi89CanvasRow('c-b', 'Vault B board')]);
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const Key('canvas-row-c-a')), findsNothing);
        expect(find.byKey(const Key('canvas-row-c-b')), findsOneWidget);
        expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
        expect(_canvasCount(tester), 1);
      });
    }
  });

  group('canvas tab chip', () {
    testWidgets(
      'a canvas tab chip shows the canvas title from the canvases facade',
      (tester) async {
        final h = await pumpWorkspace(tester, db: _fixtureDb());
        h.read(tabsProvider.notifier).openOrFocus(const CanvasTab(C89.newer));
        await pumpFrames(tester);

        final chip = find.byKey(const Key('tab-canvas-${C89.newer}'));
        expect(chip, findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text('Newer')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chip, matching: find.text('canvas')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a canvas tab chip shows canvas when the canvas is not in the list',
      (tester) async {
        final h = await pumpWorkspace(tester, db: _fixtureDb());
        h
            .read(tabsProvider.notifier)
            .openOrFocus(const CanvasTab('cv-missing'));
        await pumpFrames(tester);

        final chip = find.byKey(const Key('tab-canvas-cv-missing'));
        expect(chip, findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text('canvas')),
          findsOneWidget,
        );
      },
    );
  });
}

Wi89Canvas _held() => Wi89Canvas()..hold = true;

/// The count the sidebar's `canvases` panel header shows.
int _canvasCount(WidgetTester tester) => tester
    .widget<PanelHeader>(
      find.byWidgetPredicate(
        (w) => w is PanelHeader && w.eyebrow == 'canvases',
      ),
    )
    .count!;

Future<ProviderContainer> _pumpSidebar(
  WidgetTester tester,
  Map<VaultRef, Wi89Canvas> canvases, {
  VaultRef? first,
}) => _pumpSidebarWith(
  tester,
  wi89DoubleOverrides(canvases: canvases, first: first ?? canvases.keys.first),
);

Future<ProviderContainer> _pumpSidebarOverDb(
  WidgetTester tester,
  FakeVaultDb db,
) => _pumpSidebarWith(tester, [
  currentVaultProvider.overrideWith((_) => _a),
  vaultDbProvider.overrideWithValue(db),
  memexCliProvider.overrideWithValue(null),
]);

/// Pumps the real [Sidebar] (canvases read through the facade) over
/// [overrides], with the seams the sidebar needs besides the canvases.
Future<ProviderContainer> _pumpSidebarWith(
  WidgetTester tester,
  List<Override> overrides,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': '/nonexistent/memex-test-binary',
  });
  final settings = await SettingsController.load();
  final vaultDir = Directory.systemTemp.createTempSync('canvas_async_test');
  addTearDown(() {
    if (vaultDir.existsSync()) vaultDir.deleteSync(recursive: true);
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        smartFolderTreeAsyncProvider.overrideWith(
          (ref) => VaultScoped(
            ref.watch(currentVaultProvider),
            buildTopicsTree(
              const SmartFolderData(folders: [], members: []),
              const [],
            ),
          ),
        ),
        notesListAsyncProvider.overrideWith(
          (ref) => VaultScoped(
            ref.watch(currentVaultProvider),
            const <NoteListItem>[],
          ),
        ),
        tabsProvider.overrideWith(
          (ref) => TabsNotifier(
            store: UiStateStore(vaultPath: vaultDir.path),
            onPersistedSelection: (_) {},
          ),
        ),
        ...overrides,
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        // The test font renders wider than the real fonts; shrink text so
        // the fixed-width (268) sidebar lays out without overflow.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(height: 900, child: Sidebar(onNewNote: () {})),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  // The scope owns the container, so its providers (and their timers) are
  // disposed with the widget tree.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Sidebar)),
  );
  return container;
}
