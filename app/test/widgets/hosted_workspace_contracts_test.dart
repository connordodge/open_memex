// WI #101 (H7), verify mode: contracts the red tests left unpinned.
//
//   - a loaded tab (and a local vault's tab) makes no extra request for the
//     not-loaded check: the content reads are counted through the access
//     doubles;
//   - the `incompatible` status shows no hosted banner and no not-loaded
//     state;
//   - a long banner text is ellipsised to one line, no overflow at 720 px;
//   - a read error that is not a VaultUnreachableException leaves the tab's
//     own body and never marks the tab loaded;
//   - the shared `workspaceTabTitle(ref, tab)` gives the title the chip shows.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/graph_reads.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/hosted_identity.dart';
import 'package:open_memex_app/src/state/tab_not_loaded.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/canvas_view.dart';
import 'package:open_memex_app/src/widgets/graph/graph_view.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';
import 'package:open_memex_app/src/widgets/vault_schema_banner.dart';

import '../support/app_harness.dart';

const _server = 'srv-nas';
const _vault = HostedVaultRef(_server, 'work');
const _notLoadedKey = Key('tab-not-loaded');
const _bannerKeys = [
  Key('hosted-banner-unreachable'),
  Key('hosted-banner-unauthorized'),
  Key('hosted-banner-vault-gone'),
];

/// What the content reads of the doubles do, and how many ran.
class _C101Gate {
  /// Thrown by every read when set.
  Object? error;
  int noteReads = 0;
  int canvasReads = 0;
  int graphReads = 0;

  /// What the canvas list read serves (the canvas chip title reads it).
  List<CanvasRow> canvases = const [];

  /// Where the note chip title reads from: `notes.titlesForIds` answers from
  /// the harness db, like the local notes domain does. Set after the pump.
  VaultDb? db;

  void check() {
    if (error != null) throw error!;
  }

  int get total => noteReads + canvasReads + graphReads;
}

const _unreachable = VaultUnreachableException(
  serverName: 'nas',
  mayHaveCommitted: false,
);

class _C101Notes extends LocalNotesAccess {
  _C101Notes(this.gate) : super(vaultPath: '/tmp/om-101c');
  final _C101Gate gate;

  @override
  Future<Map<String, String>> titlesForIds(List<String> ids) async =>
      gate.db?.titlesForIds(ids) ?? const {};

  @override
  Future<Note?> getNote(String id) async {
    gate.noteReads++;
    gate.check();
    return Note(
      id: id,
      title: 'Loaded $id',
      contentMd: '# Loaded $id\n',
      frontmatter: '{}',
      version: 1,
      createdAt: 1759500000000,
      updatedAt: 1759500000000,
      tags: const [],
    );
  }
}

class _C101Canvas extends LocalCanvasAccess {
  _C101Canvas(this.gate) : super(vaultPath: '/tmp/om-101c');
  final _C101Gate gate;

  @override
  Future<CanvasDetailRow?> getCanvasDetail(String canvasId) async {
    gate.canvasReads++;
    gate.check();
    return null;
  }

  @override
  Future<List<CanvasRow>> listCanvases() async => gate.canvases;
}

class _C101Graph extends LocalGraphAccess {
  _C101Graph(this.gate) : super(vaultPath: '/tmp/om-101c');
  final _C101Gate gate;

  @override
  Future<List<GraphNoteRow>> graphNotes() async {
    gate.graphReads++;
    gate.check();
    return const [];
  }

  @override
  Future<List<GraphLinkRow>> graphLinks() async {
    gate.check();
    return const [];
  }
}

typedef _Kind = ({
  String name,
  WorkspaceTab Function(String id) tab,
  WorkspaceTab other,
  Type body,
  int Function(_C101Gate) reads,
});

final _kinds = <_Kind>[
  (
    name: 'note',
    tab: (id) => NoteTab(id),
    other: const CanvasTab('other-c'),
    body: NoteEditor,
    reads: (g) => g.noteReads,
  ),
  (
    name: 'canvas',
    tab: (id) => CanvasTab(id),
    other: const NoteTab('other-n'),
    body: CanvasView,
    reads: (g) => g.canvasReads,
  ),
  (
    name: 'graph',
    tab: (id) => GraphTab(const GraphScope.vault()),
    other: const NoteTab('other-n'),
    body: GraphView,
    reads: (g) => g.graphReads,
  ),
];

Future<(WorkspaceHarness, _C101Gate)> _pumpHosted(
  WidgetTester tester, {
  Object? error,
  VaultRef vault = _vault,
  HostedConnectionStatus? status,
  List<Override> extraOverrides = const [],
}) async {
  final gate = _C101Gate()..error = error;
  final h = await pumpWorkspace(
    tester,
    overrides: [
      ...extraOverrides,
      hostedServerNameProvider.overrideWith(
        (ref, id) => id == _server ? 'nas' : id,
      ),
      vaultAccessProvider.overrideWith(
        (ref) => LocalVaultAccess(
          vaultPath: '/tmp/om-101c',
          notes: _C101Notes(gate),
          canvas: _C101Canvas(gate),
          graph: _C101Graph(gate),
        ),
      ),
    ],
  );
  gate.db = h.db;
  h.container.read(currentVaultProvider.notifier).state = vault;
  await pumpFrames(tester);
  h.container.read(hostedConnectionStatusProvider(_server).notifier).state =
      status;
  await pumpFrames(tester);
  return (h, gate);
}

Future<void> _open(WidgetTester tester, WorkspaceHarness h, WorkspaceTab tab) {
  h.container.read(tabsProvider.notifier).openOrFocus(tab);
  return pumpFrames(tester);
}

Future<void> _setStatus(
  WidgetTester tester,
  WorkspaceHarness h,
  HostedConnectionStatus? status,
) {
  h.container.read(hostedConnectionStatusProvider(_server).notifier).state =
      status;
  return pumpFrames(tester);
}

Future<void> _bump(WidgetTester tester, WorkspaceHarness h) {
  h.container.read(vaultRevisionProvider.notifier).state++;
  return pumpFrames(tester);
}

String _chipTitle(WidgetTester tester, WorkspaceTab tab) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(Key('tab-${tab.tabId}')),
        matching: find.byType(Text),
      ),
    )
    .data!;

/// Opens a [kind] tab on a hosted vault, then drives revision bumps, an outage and a recovery
/// and a trip to another tab and back. Returns the tab's content reads once it
/// loaded and after the whole sequence.
Future<({int loadedReads, int finalReads})> _runLoadedTabScenario(
  WidgetTester tester,
  _Kind kind, {
  required bool withCheck,
}) async {
  final (h, gate) = await _pumpHosted(
    tester,
    status: HostedConnectionStatus.connected,
    // Without the check the tab body is all that reads.
    extraOverrides: [
      if (!withCheck) tabNotLoadedProvider.overrideWith((ref, tab) => null),
    ],
  );
  await _open(tester, h, kind.tab('x1'));
  expect(find.byType(kind.body), findsOneWidget);
  final loadedReads = kind.reads(gate);

  await _bump(tester, h);
  await _setStatus(tester, h, HostedConnectionStatus.unreachable);
  await _bump(tester, h);
  await _setStatus(tester, h, HostedConnectionStatus.connected);
  await _open(tester, h, kind.other);
  h.container.read(tabsProvider.notifier).setActive(0);
  await pumpFrames(tester);
  await _bump(tester, h);

  expect(find.byType(kind.body), findsOneWidget);
  final finalReads = kind.reads(gate);
  // Unmount this workspace so a second scenario can run in the same test.
  await tester.pumpWidget(const SizedBox());
  await pumpFrames(tester);
  return (loadedReads: loadedReads, finalReads: finalReads);
}

void main() {
  group('no extra request', () {
    for (final kind in _kinds) {
      final name = switch (kind.name) {
        'note' =>
          'a loaded note tab makes no extra request for the not loaded check',
        'canvas' =>
          'a loaded canvas tab makes no extra request for the not loaded check',
        _ =>
          'a loaded graph tab makes no extra request for the not loaded check',
      };
      testWidgets(name, (tester) async {
        // The same steps with the not-loaded check and with it switched off.
        // Whatever the tab body itself re-reads on a revision bump (the
        // canvas and graph views read through their async providers) shows up
        // in both runs; the check adds reads only if the run with it reads
        // more than the run without it.
        final hosted = await _runLoadedTabScenario(
          tester,
          kind,
          withCheck: true,
        );
        final bodyOnly = await _runLoadedTabScenario(
          tester,
          kind,
          withCheck: false,
        );
        expect(hosted.loadedReads, greaterThan(0));
        expect(
          hosted.finalReads - hosted.loadedReads,
          bodyOnly.finalReads - bodyOnly.loadedReads,
        );
      });
    }

    testWidgets('a local vault tab makes no not loaded read', (tester) async {
      // The editor loads the note through the vault access itself, so the
      // gate's total includes its reads. The check adds none when the run
      // with it reads exactly what the run without it does.
      Future<int> run({required bool withCheck}) async {
        final (h, gate) = await _pumpHosted(
          tester,
          vault: const LocalVaultRef('/tmp/om-101c-local'),
          status: HostedConnectionStatus.unreachable,
          extraOverrides: [
            if (!withCheck)
              tabNotLoadedProvider.overrideWith((ref, tab) => null),
          ],
        );
        await _open(tester, h, const NoteTab('x1'));
        await _bump(tester, h);
        expect(find.byType(NoteEditor), findsOneWidget);
        final total = gate.total;
        await tester.pumpWidget(const SizedBox());
        await pumpFrames(tester);
        return total;
      }

      final withCheck = await run(withCheck: true);
      final bodyOnly = await run(withCheck: false);
      expect(bodyOnly, greaterThan(0));
      expect(withCheck, bodyOnly);
    });
  });

  group('incompatible status', () {
    Future<ProviderContainer> pumpSlot(
      WidgetTester tester, {
      List<Override> overrides = const [],
    }) async {
      final container = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith((_) => _vault),
          vaultOpenProvider.overrideWith(
            (_) async => const VaultOpenState(schemaOutdated: false),
          ),
          hostedServerNameProvider.overrideWith((ref, id) => 'nas'),
          ...overrides,
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildOmTheme(),
            home: const Scaffold(body: Column(children: [VaultSchemaBanner()])),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return container;
    }

    testWidgets('an incompatible server status shows no hosted banner', (
      tester,
    ) async {
      final c = await pumpSlot(tester);
      // From each other status into incompatible: the banner goes away.
      for (final from in [
        HostedConnectionStatus.unreachable,
        HostedConnectionStatus.tokenRejected,
      ]) {
        c.read(hostedConnectionStatusProvider(_server).notifier).state = from;
        await tester.pump();
        expect(
          _bannerKeys.where((k) => find.byKey(k).evaluate().isNotEmpty),
          hasLength(1),
        );
        c.read(hostedConnectionStatusProvider(_server).notifier).state =
            HostedConnectionStatus.incompatible;
        await tester.pump();
        for (final key in _bannerKeys) {
          expect(find.byKey(key), findsNothing);
        }
        expect(find.byType(SizedBox), findsWidgets);
      }
    });

    testWidgets('an incompatible server status does not show not loaded', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(
        tester,
        error: _unreachable,
        status: HostedConnectionStatus.incompatible,
      );
      await _open(tester, h, const NoteTab('x1'));
      expect(find.byKey(_notLoadedKey), findsNothing);
      expect(find.byType(NoteEditor), findsOneWidget);
    });
  });

  group('long banner text', () {
    // The test font draws every glyph 1em wide, so 120 characters need far
    // more than 720 px.
    final longName = List.filled(120, 'x').join();

    Future<ProviderContainer> pumpNarrow(WidgetTester tester) async {
      final container = ProviderContainer(
        overrides: [
          currentVaultProvider.overrideWith((_) => _vault),
          vaultOpenProvider.overrideWith(
            (_) async => const VaultOpenState(schemaOutdated: false),
          ),
          hostedServerNameProvider.overrideWith((ref, id) => longName),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildOmTheme(),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: 720, child: VaultSchemaBanner()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return container;
    }

    void expectOneEllipsisedLine(WidgetTester tester, Key key) {
      expect(tester.takeException(), isNull);
      final banner = find.byKey(key);
      expect(banner, findsOneWidget);
      expect(tester.getSize(banner).height, 36);
      expect(tester.getSize(banner).width, 720);
      final label = tester.widget<Text>(
        find.descendant(of: banner, matching: find.byType(Text)).first,
      );
      expect(label.maxLines, 1);
      expect(label.overflow, TextOverflow.ellipsis);
      final labelRect = tester.getRect(
        find.descendant(of: banner, matching: find.byType(Text)).first,
      );
      // One line (ink 12 px at 1.4 line height), inside the banner.
      expect(labelRect.height, lessThan(20));
      expect(labelRect.right, lessThanOrEqualTo(720));
    }

    testWidgets('a long unreachable banner text is ellipsised to one line', (
      tester,
    ) async {
      final c = await pumpNarrow(tester);
      c.read(hostedConnectionStatusProvider(_server).notifier).state =
          HostedConnectionStatus.unreachable;
      await tester.pump();
      expectOneEllipsisedLine(tester, _bannerKeys[0]);
      // The button keeps its place inside the banner.
      final button = tester.getRect(
        find.byKey(const Key('hosted-banner-retry')),
      );
      expect(button.right, lessThanOrEqualTo(720));
      expect(button.left, greaterThan(0));
    });

    testWidgets('a long rejected banner text is ellipsised to one line', (
      tester,
    ) async {
      final c = await pumpNarrow(tester);
      c.read(hostedConnectionStatusProvider(_server).notifier).state =
          HostedConnectionStatus.tokenRejected;
      await tester.pump();
      expectOneEllipsisedLine(tester, _bannerKeys[1]);
      final button = tester.getRect(
        find.byKey(const Key('hosted-banner-update-token')),
      );
      expect(button.right, lessThanOrEqualTo(720));
    });

    testWidgets('a long vault gone banner text is ellipsised to one line', (
      tester,
    ) async {
      final c = await pumpNarrow(tester);
      c.read(hostedVaultGoneProvider(_vault).notifier).state = true;
      await tester.pump();
      expectOneEllipsisedLine(tester, _bannerKeys[2]);
    });
  });

  group('read errors that are not unreachable', () {
    testWidgets(
      'a read error that is not unreachable shows the tab body and does not mark it loaded',
      (tester) async {
        final (h, gate) = await _pumpHosted(
          tester,
          error: StateError('broken row'),
          status: HostedConnectionStatus.unreachable,
        );
        await _open(tester, h, const NoteTab('x1'));
        // The tab's own body stays; the not-loaded state does not take over.
        expect(find.byKey(_notLoadedKey), findsNothing);
        expect(find.byType(NoteEditor), findsOneWidget);
        expect(gate.noteReads, greaterThan(0));

        // The tab never loaded: once reads fail as unreachable it shows the
        // not-loaded state (a loaded tab would keep its body).
        gate.error = _unreachable;
        await _bump(tester, h);
        expect(find.byKey(_notLoadedKey), findsOneWidget);
        expect(find.byType(NoteEditor), findsNothing);
      },
    );
  });

  group('workspaceTabTitle', () {
    testWidgets('workspaceTabTitle gives the title the tab chip shows', (
      tester,
    ) async {
      final (h, gate) = await _pumpHosted(
        tester,
        status: HostedConnectionStatus.connected,
      );
      // Note titles read the harness db through titlesForIds; canvas titles read the canvas list
      // through the vault access (the canvas async migration), so the canvas
      // double serves the list.
      h.db.seedNote(id: 'n-weekly', title: 'weekly review');
      gate.canvases = [
        CanvasRow(
          canvasId: 'c-board',
          title: 'Board',
          createdAt: 1759500000000,
          updatedAt: 1759500000000,
          version: 1,
          nodeCount: 0,
        ),
      ];
      await _bump(tester, h);

      final tabs = <WorkspaceTab>[
        const NoteTab('n-weekly'),
        const NoteTab('n-unknown'),
        const VirtualTodayTab('2026-10-03'),
        const CanvasTab('c-board'),
        const CanvasTab('c-unknown'),
        GraphTab(const GraphScope.vault()),
      ];
      final chips = <String>[];
      for (final tab in tabs) {
        await _open(tester, h, tab);
        chips.add(_chipTitle(tester, tab));
      }
      expect(chips, [
        'weekly review',
        'note',
        '2026-10-03',
        'Board',
        'canvas',
        'Graph · Whole vault',
      ]);

      final titles = <String>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                titles
                  ..clear()
                  ..addAll(tabs.map((t) => workspaceTabTitle(ref, t)));
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(titles, chips);
    });
  });
}
