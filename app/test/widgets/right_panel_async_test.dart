// WI #90 (W6): the right panel on async reads. Reloads keep the previous
// content on screen, a vault switch never shows the previous vault's rows,
// and a hosted first load shows the A12 loading state (VaultAsyncView).
// Completer-gated doubles extend the local domain classes (D21).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart' show LinkRow;
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
import '../support/vault_scoped_reads.dart';

const _note = 'n90-target';

/// One vault's doors: gated notes and graph doubles with that vault's data.
class _Side {
  _Side(this.vault, {required String tag, bool open = true})
    : gate = Wi90Gate(open: open) {
    // The selected note is read through the notes domain (#78), so each
    // side's notes double needs a database holding it.
    db = FakeVaultDb.v5()
      ..seedNote(id: _note, title: 'Target', tags: const ['t1']);
    notes = Wi90GatedNotes(
      vaultPath: '/unused-$tag',
      db: db,
      gate: gate,
      out: [wi90Link('$tag-out', from: _note, to: 'x-$tag', text: '$tag out')],
      incoming: [wi90Link('$tag-in', from: 's-$tag', to: _note)],
      titles: {'s-$tag': '$tag source'},
    );
    graph = Wi90GatedGraph(
      vaultPath: '/unused-$tag',
      gate: gate,
      changes: [
        AgentChangeRow(
          id: '$tag-ch',
          noteId: _note,
          day: '2026-09-05',
          createdAt: DateTime(2026, 9, 5, 14, 32).millisecondsSinceEpoch,
          bullets: ['$tag bullet'],
        ),
      ],
    );
  }

  final VaultRef vault;
  final Wi90Gate gate;
  late final FakeVaultDb db;
  late final Wi90GatedNotes notes;
  late final Wi90GatedGraph graph;

  Finder get outRow => find.byKey(Key('outgoing-link-${vault.tag}-out'));
  Finder get inRow =>
      find.byKey(Key('backlink-item-s-${vault.tag}-${vault.tag}-in'));
  Finder get entry => find.byKey(Key('activity-entry-${vault.tag}-ch'));
}

extension on VaultRef {
  String get tag => switch (this) {
    LocalVaultRef(:final path) => path.split('-').last,
    HostedVaultRef(:final vaultName) => vaultName,
  };
}

class _Panel {
  _Panel(this.container, this.a, this.b);
  final ProviderContainer container;
  final _Side a;
  final _Side b;

  void switchTo(VaultRef? v) =>
      container.read(currentVaultProvider.notifier).state = v;
  void bump() => container.read(vaultRevisionProvider.notifier).state++;
}

Future<_Panel> _pump(
  WidgetTester tester, {
  required _Side a,
  required _Side b,
  required RightPanelTab tab,
}) async {
  // Same text scale as the workspace harness (the test font is 1em wide).
  tester.platformDispatcher.textScaleFactorTestValue = 0.5;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  db.seedNote(id: _note, title: 'Target', tags: const ['t1']);
  addTearDown(a.db.close);
  addTearDown(b.db.close);
  final sides = {a.vault: a, b.vault: b};
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => a.vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(null),
      selectedNoteIdProvider.overrideWith((_) => _note),
      rightPanelTabProvider.overrideWith((_) => tab),
      vaultAccessProvider.overrideWith((ref) {
        final side = sides[ref.watch(currentVaultProvider)];
        if (side == null) return null;
        return LocalVaultAccess(
          vaultPath: side.notes.vaultPath,
          notes: side.notes,
          graph: side.graph,
        );
      }),
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
  return _Panel(container, a, b);
}

const _local = (
  LocalVaultRef('/tmp/om-90-vault-a'),
  LocalVaultRef('/tmp/om-90-vault-b'),
);
const _hosted = (HostedVaultRef('srv', 'a'), HostedVaultRef('srv', 'b'));

final _loading = find.byKey(vaultAsyncLoadingKey);

void main() {
  group('reloads keep the previous content', () {
    testWidgets(
      'the Connections tab keeps its previous content on screen after a vault revision bump until the new reads complete',
      (tester) async {
        final a = _Side(_local.$1, tag: 'a');
        final p = await _pump(
          tester,
          a: a,
          b: _Side(_local.$2, tag: 'b'),
          tab: RightPanelTab.connections,
        );
        expect(a.outRow, findsOneWidget);
        expect(a.inRow, findsOneWidget);

        a.gate.close();
        a.notes.out = [wi90Link('a2-out', from: _note, to: 'x', text: 'a2')];
        a.notes.incoming = [wi90Link('a2-in', from: 's-a', to: _note)];
        p.bump();
        await pumpFrames(tester);

        expect(a.outRow, findsOneWidget);
        expect(a.inRow, findsOneWidget);
        expect(find.textContaining('no links yet.'), findsNothing);
        expect(_loading, findsNothing);

        a.gate.open();
        await pumpFrames(tester);

        expect(a.outRow, findsNothing);
        expect(find.byKey(const Key('outgoing-link-a2-out')), findsOneWidget);
        expect(
          find.byKey(const Key('backlink-item-s-a-a2-in')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the Activity tab keeps its previous entries on screen after a vault revision bump until the new reads complete',
      (tester) async {
        final a = _Side(_local.$1, tag: 'a');
        final p = await _pump(
          tester,
          a: a,
          b: _Side(_local.$2, tag: 'b'),
          tab: RightPanelTab.activity,
        );
        expect(a.entry, findsOneWidget);

        a.gate.close();
        a.graph.changes = [
          AgentChangeRow(
            id: 'a2-ch',
            noteId: _note,
            day: '2026-09-06',
            createdAt: 1759800000000,
            bullets: const ['second'],
          ),
        ];
        p.bump();
        await pumpFrames(tester);

        expect(a.entry, findsOneWidget);
        expect(find.byKey(const Key('activity-empty')), findsNothing);
        expect(_loading, findsNothing);

        a.gate.open();
        await pumpFrames(tester);

        expect(a.entry, findsNothing);
        expect(find.byKey(const Key('activity-entry-a2-ch')), findsOneWidget);
      },
    );
  });

  group('a vault switch never shows the previous vault rows', () {
    for (final (name, vaults, hosted) in [
      (
        'Connections tab switching local vaults never shows the previous vault rows',
        _local,
        false,
      ),
      (
        'Connections tab switching hosted vaults never shows the previous vault rows',
        _hosted,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = _Side(vaults.$1, tag: 'a');
        final b = _Side(vaults.$2, tag: 'b', open: false);
        final p = await _pump(
          tester,
          a: a,
          b: b,
          tab: RightPanelTab.connections,
        );
        expect(a.outRow, findsOneWidget);
        expect(a.inRow, findsOneWidget);

        p.switchTo(vaults.$2);
        await pumpFrames(tester);

        expect(a.outRow, findsNothing);
        expect(a.inRow, findsNothing);
        expect(find.text('a out'), findsNothing);
        expect(b.outRow, findsNothing);
        expect(
          readScoped(
            p.container,
            linksOutAsyncProvider(_note),
            const <LinkRow>[],
          ),
          isEmpty,
          reason: 'the outgoing links read',
        );
        expect(
          readScoped(
            p.container,
            backlinksAsyncProvider(_note),
            const <String, List<BacklinkEntry>>{},
          ),
          isEmpty,
          reason: 'the backlinks read',
        );
        if (hosted) {
          expect(_loading, findsOneWidget);
        } else {
          expect(find.textContaining('no links yet.'), findsOneWidget);
          expect(_loading, findsNothing);
        }

        b.gate.open();
        await pumpFrames(tester);

        expect(b.outRow, findsOneWidget);
        expect(b.inRow, findsOneWidget);
        expect(a.outRow, findsNothing);
        expect(_loading, findsNothing);
      });
    }

    for (final (name, vaults, hosted) in [
      (
        'Activity tab switching local vaults never shows the previous vault rows',
        _local,
        false,
      ),
      (
        'Activity tab switching hosted vaults never shows the previous vault rows',
        _hosted,
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = _Side(vaults.$1, tag: 'a');
        final b = _Side(vaults.$2, tag: 'b', open: false);
        final p = await _pump(tester, a: a, b: b, tab: RightPanelTab.activity);
        expect(a.entry, findsOneWidget);

        p.switchTo(vaults.$2);
        await pumpFrames(tester);

        expect(a.entry, findsNothing);
        expect(find.text('· a bullet'), findsNothing);
        expect(
          readScoped(
            p.container,
            agentChangesAsyncProvider(_note),
            const <AgentChangeRow>[],
          ),
          isEmpty,
          reason: 'the agent changes read',
        );
        if (hosted) {
          expect(_loading, findsOneWidget);
        } else {
          expect(find.byKey(const Key('activity-empty')), findsOneWidget);
          expect(_loading, findsNothing);
        }

        b.gate.open();
        await pumpFrames(tester);

        expect(b.entry, findsOneWidget);
        expect(a.entry, findsNothing);
        expect(_loading, findsNothing);
      });
    }
  });

  group('hosted first load', () {
    testWidgets(
      'the Connections tab shows the loading state on a hosted first load and the rows once they arrive',
      (tester) async {
        final a = _Side(_hosted.$1, tag: 'a', open: false);
        final p = await _pump(
          tester,
          a: a,
          b: _Side(_hosted.$2, tag: 'b'),
          tab: RightPanelTab.connections,
        );

        expect(_loading, findsOneWidget);
        expect(find.textContaining('no links yet.'), findsNothing);
        expect(a.outRow, findsNothing);

        a.gate.open();
        await pumpFrames(tester);

        expect(_loading, findsNothing);
        expect(a.outRow, findsOneWidget);
        expect(a.inRow, findsOneWidget);
        expect(
          readScoped(
            p.container,
            linksOutAsyncProvider(_note),
            const <LinkRow>[],
          ),
          hasLength(1),
        );
      },
    );

    testWidgets(
      'the Activity tab shows the loading state on a hosted first load and the entries once they arrive',
      (tester) async {
        final a = _Side(_hosted.$1, tag: 'a', open: false);
        await _pump(
          tester,
          a: a,
          b: _Side(_hosted.$2, tag: 'b'),
          tab: RightPanelTab.activity,
        );

        expect(_loading, findsOneWidget);
        expect(find.byKey(const Key('activity-empty')), findsNothing);

        a.gate.open();
        await pumpFrames(tester);

        expect(_loading, findsNothing);
        expect(a.entry, findsOneWidget);
      },
    );
  });
}
