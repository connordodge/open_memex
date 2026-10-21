// WI #90 (W6) verify: contracts the implementer listed as unpinned.
// - Connections composes two reads; one errored with the other loaded shows
//   the empty state (no partial rows), local and hosted (lead ruling).
// - agentChangesAsyncProvider: a hosted vault (no local db) is not V5-gated;
//   a local V4 vault yields empty without reading or throwing.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/state/activity_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/app_harness.dart';
import '../support/fake_vault_db.dart';
import '../support/links_seeds.dart';

const _note = 'n90c-target';
const VaultRef _localVault = LocalVaultRef('/tmp/om-90c-vault');
const VaultRef _hostedVault = HostedVaultRef('srv', 'a');

/// A notes domain whose chosen read throws.
class _Wi90cFailingNotes extends Wi90GatedNotes {
  _Wi90cFailingNotes({
    required super.vaultPath,
    super.db,
    required super.gate,
    super.out,
    super.incoming,
    super.titles,
    this.failOut = false,
    this.failIn = false,
  });

  final bool failOut;
  final bool failIn;

  @override
  Future<List<LinkRow>> linksOutFor(String noteId) async {
    if (failOut) throw StateError('linksOutFor failed');
    return super.linksOutFor(noteId);
  }

  @override
  Future<List<LinkRow>> linksInFor(String noteId, {String? kind}) async {
    if (failIn) throw StateError('linksInFor failed');
    return super.linksInFor(noteId, kind: kind);
  }
}

Future<void> _pumpConnections(
  WidgetTester tester, {
  required VaultRef vault,
  bool failOut = false,
  bool failIn = false,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  db.seedNote(id: _note, title: 'Target', tags: const ['t1', 't2']);
  final notes = _Wi90cFailingNotes(
    vaultPath: '/unused-c',
    db: db,
    gate: Wi90Gate(),
    failOut: failOut,
    failIn: failIn,
    out: [wi90Link('c-out', from: _note, to: 'x-c', text: 'c out')],
    incoming: [wi90Link('c-in', from: 's-c', to: _note)],
    titles: {'s-c': 'c source'},
  );
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      selectedNoteIdProvider.overrideWith((_) => _note),
      rightPanelTabProvider.overrideWith((_) => RightPanelTab.connections),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(vaultPath: '/unused-c', notes: notes),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(body: RightPanel(onClose: () {})),
      ),
    ),
  );
  await pumpFrames(tester);
}

void _expectEmptyState() {
  expect(find.textContaining('no links yet.'), findsOneWidget);
  expect(find.byKey(const Key('outgoing-link-c-out')), findsNothing);
  expect(find.byKey(const Key('backlink-item-s-c-c-in')), findsNothing);
  expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
  expect(find.text('0 outgoing · 0 backlinks · 2 tags'), findsOneWidget);
}

ProviderContainer _activityContainer({
  required VaultRef? vault,
  required VaultDb? db,
  required Wi90GatedGraph graph,
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(vaultPath: '/unused-c', graph: graph),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

AgentChangeRow _change() => AgentChangeRow(
  id: 'c-ch',
  noteId: _note,
  day: '2026-09-05',
  createdAt: 1000,
  bullets: const ['c bullet'],
);

void main() {
  group('Connections with one read errored', () {
    for (final (name, vault, failOut, failIn) in [
      (
        'the Connections tab shows the empty state when the outgoing read errors and the backlinks load on a local vault',
        _localVault,
        true,
        false,
      ),
      (
        'the Connections tab shows the empty state when the backlinks read errors and the outgoing links load on a local vault',
        _localVault,
        false,
        true,
      ),
      (
        'the Connections tab shows the empty state when the outgoing read errors and the backlinks load on a hosted vault',
        _hostedVault,
        true,
        false,
      ),
      (
        'the Connections tab shows the empty state when the backlinks read errors and the outgoing links load on a hosted vault',
        _hostedVault,
        false,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _pumpConnections(
          tester,
          vault: vault,
          failOut: failOut,
          failIn: failIn,
        );
        _expectEmptyState();
      });
    }
  });

  group('agentChangesAsyncProvider V5 gate', () {
    test(
      'agentChangesAsyncProvider on a hosted vault with no local database is not V5-gated',
      () async {
        final graph = Wi90GatedGraph(
          vaultPath: '/unused-c',
          gate: Wi90Gate(),
          changes: [_change()],
        );
        final c = _activityContainer(
          vault: _hostedVault,
          db: null,
          graph: graph,
        );

        final scoped = await c.read(agentChangesAsyncProvider(_note).future);

        expect(scoped.vault, _hostedVault);
        expect(scoped.value.map((r) => r.id), ['c-ch']);
        expect(graph.gate.calls, 1);
      },
    );

    test(
      'agentChangesAsyncProvider on a local vault with no database still reads through access',
      () async {
        final graph = Wi90GatedGraph(
          vaultPath: '/unused-c',
          gate: Wi90Gate(),
          changes: [_change()],
        );
        final c = _activityContainer(
          vault: _localVault,
          db: null,
          graph: graph,
        );

        final scoped = await c.read(agentChangesAsyncProvider(_note).future);

        expect(scoped.value.map((r) => r.id), ['c-ch']);
        expect(graph.gate.calls, 1);
      },
    );

    test(
      'agentChangesAsyncProvider on a local V4 vault is empty without reading or throwing',
      () async {
        final db = FakeVaultDb.v4();
        addTearDown(db.close);
        final graph = Wi90GatedGraph(
          vaultPath: '/unused-c',
          gate: Wi90Gate(),
          changes: [_change()],
        );
        final c = _activityContainer(vault: _localVault, db: db, graph: graph);

        final scoped = await c.read(agentChangesAsyncProvider(_note).future);

        expect(scoped.vault, _localVault);
        expect(scoped.value, isEmpty);
        expect(graph.gate.calls, 0);
        expect(c.read(agentChangesProvider(_note)), isEmpty);
      },
    );

    test(
      'agentChangesAsyncProvider on a local V5 vault reads through access',
      () async {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        final graph = Wi90GatedGraph(
          vaultPath: '/unused-c',
          gate: Wi90Gate(),
          changes: [_change()],
        );
        final c = _activityContainer(vault: _localVault, db: db, graph: graph);

        final scoped = await c.read(agentChangesAsyncProvider(_note).future);

        expect(scoped.value.map((r) => r.id), ['c-ch']);
        expect(graph.gate.calls, 1);
      },
    );
  });
}
