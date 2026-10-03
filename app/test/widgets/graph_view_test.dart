// WI #30 (A12): the Graph view widget, pumped on its own (not inside the
// workspace, whose OmDot pulse never settles) so pumpAndSettle can prove the
// simulation stops. Positions are never asserted (TS5); tests use relative
// geometry only (who moved, by roughly how much, what paints first).
//
// Seams: FakeVaultDb for vaultDbProvider, a FakeMemexCli that records every
// call, and a tabsProvider over an in-memory recording UiStateStore.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/graph/graph_view.dart';

import '../support/daily_seed.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';

const _graphView = Key('graph-view');
const _tooltip = Key('graph-edge-tooltip');
Key _node(String id) => Key('graph-node-$id');
Key _hull(String id) => Key('graph-hull-$id');

/// Every `graph-node-*` keyed widget.
final _anyNode = find.byWidgetPredicate((w) {
  final k = w.key;
  return k is ValueKey<String> && k.value.startsWith('graph-node-');
});

/// A UiStateStore that never touches disk and records every write.
class _RecordingStore extends UiStateStore {
  _RecordingStore(String vaultPath) : super(vaultPath: vaultPath);

  final writes = <UiState>[];
  UiState _last = UiState.empty();

  @override
  UiState read() => _last;

  @override
  Future<void> write(UiState state) {
    writes.add(state);
    _last = state;
    return Future<void>.value();
  }

  @override
  Future<void> flush() => Future<void>.value();
}

class _Graph {
  _Graph({
    required this.container,
    required this.store,
    required this.cli,
    required this.vaultDir,
  });
  final ProviderContainer container;
  final _RecordingStore store;
  final FakeMemexCli cli;
  final Directory vaultDir;
}

FakeVaultDb _db(void Function(FakeVaultDb db) seed) {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  seed(db);
  return db;
}

/// Pumps a bare [GraphView] for [scope] in a 1200x900 window. Does not
/// settle: callers pump as they need.
Future<_Graph> _pumpGraph(
  WidgetTester tester,
  FakeVaultDb db,
  GraphScope scope,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final vaultDir = Directory.systemTemp.createTempSync('graph_view_test');
  addTearDown(() {
    if (vaultDir.existsSync()) vaultDir.deleteSync(recursive: true);
  });
  final store = _RecordingStore(vaultDir.path);
  final cli = FakeMemexCli();
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vaultDir.path),
      vaultDbProvider.overrideWithValue(db),
      vaultV5ReadyProvider.overrideWithValue(true),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
      tabsProvider.overrideWith(
        (ref) => TabsNotifier(store: store, onPersistedSelection: (_) {}),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: GraphView(scope: scope)),
      ),
    ),
  );
  return _Graph(
    container: container,
    store: store,
    cli: cli,
    vaultDir: vaultDir,
  );
}

/// pumpAndSettle with a bounded timeout: a simulation that never stops
/// fails here instead of hanging for ten virtual minutes.
Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 16),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 60),
);

Offset _center(WidgetTester tester, String id) =>
    tester.getCenter(find.byKey(_node(id)));

/// Render objects under the graph view in paint order (depth-first, children
/// in list order).
List<RenderObject> _paintOrder(WidgetTester tester) {
  final out = <RenderObject>[];
  void visit(RenderObject r) {
    out.add(r);
    r.visitChildren(visit);
  }

  visit(tester.renderObject(find.byKey(_graphView)));
  return out;
}

/// Alpha extends Beta (label `builds on`); Gamma is linked to neither.
void _seedPair(
  FakeVaultDb db, {
  String? label = 'builds on',
  String kind = 'extends',
}) {
  db.seedTopicNote(G.alpha, 'Alpha');
  db.seedTopicNote(G.beta, 'Beta');
  db.seedLink(G.alpha, G.beta, kind: kind, label: label);
}

Future<TestGesture> _mouse(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(2, 2));
  addTearDown(mouse.removePointer);
  return mouse;
}

Iterable<String> _texts(WidgetTester tester, Finder within) => tester
    .widgetList<RichText>(
      find.descendant(of: within, matching: find.byType(RichText)),
    )
    .map((r) => r.text.toPlainText());

void main() {
  group('nodes (AC8)', () {
    testWidgets('the Graph view renders one graph-node per scope node', (
      tester,
    ) async {
      final db = _db(seedGraphFixture);
      await _pumpGraph(tester, db, const GraphScope.folder(G.projects));
      await _settle(tester);

      expect(find.byKey(_graphView), findsOneWidget);
      for (final id in [G.alpha, G.beta, G.gamma, G.loose]) {
        expect(find.byKey(_node(id)), findsOneWidget, reason: id);
      }
      expect(_anyNode, findsNWidgets(4));
      expect(find.byKey(_node(G.delta)), findsNothing);
      expect(find.byKey(_node(G.day0905)), findsNothing);
    });

    testWidgets('daily nodes are labelled by date and topic nodes by title', (
      tester,
    ) async {
      final db = _db(seedGraphFixture);
      await _pumpGraph(tester, db, const GraphScope.topic(G.alpha));
      await _settle(tester);

      expect(
        find.descendant(
          of: find.byKey(_node(G.day0905)),
          matching: find.text('2026-09-05'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_node(G.alpha)),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_node(G.epsilon)),
          matching: find.text('Epsilon'),
        ),
        findsOneWidget,
      );
    });
  });

  group('hulls and pinned glyphs (AC9)', () {
    testWidgets('a Smart Folder hull renders behind its member nodes', (
      tester,
    ) async {
      final db = _db(seedGraphFixture);
      await _pumpGraph(tester, db, const GraphScope.folder(G.projects));
      await _settle(tester);

      final members = {
        G.projects: [G.alpha, G.beta],
        G.research: [G.gamma],
        G.deep: [G.loose],
        G.archive: [G.beta],
      };
      final order = _paintOrder(tester);
      for (final MapEntry(key: folder, value: ids) in members.entries) {
        final hull = find.byKey(_hull(folder));
        expect(hull, findsOneWidget, reason: folder);
        final hullRect = tester.getRect(hull);
        final hullIndex = order.indexOf(tester.renderObject(hull));
        expect(hullIndex, greaterThanOrEqualTo(0));
        for (final id in ids) {
          final nodeIndex = order.indexOf(
            tester.renderObject(find.byKey(_node(id))),
          );
          expect(
            hullIndex,
            lessThan(nodeIndex),
            reason: 'hull $folder paints before (behind) node $id',
          );
          expect(
            hullRect.contains(_center(tester, id)),
            isTrue,
            reason: 'hull $folder surrounds node $id',
          );
        }
      }
    });

    testWidgets('a pinned Smart Folder hull shows the pinned glyph', (
      tester,
    ) async {
      final db = _db(seedGraphFixture);
      await _pumpGraph(tester, db, const GraphScope.folder(G.projects));
      await _settle(tester);

      Finder pinIn(String folder) => find.descendant(
        of: find.byKey(_hull(folder)),
        matching: find.byIcon(LucideIcons.pin),
      );
      expect(pinIn(G.projects), findsOneWidget);
      expect(pinIn(G.research), findsNothing);
      expect(pinIn(G.deep), findsNothing);
      expect(pinIn(G.archive), findsNothing);
    });

    testWidgets('a node with a pinned membership shows the pinned glyph', (
      tester,
    ) async {
      final db = _db(seedGraphFixture);
      await _pumpGraph(tester, db, const GraphScope.folder(G.projects));
      await _settle(tester);

      Finder pinIn(String id) => find.descendant(
        of: find.byKey(_node(id)),
        matching: find.byIcon(LucideIcons.pin),
      );
      expect(pinIn(G.alpha), findsOneWidget, reason: 'pinned in Projects');
      expect(pinIn(G.beta), findsOneWidget, reason: 'pinned in Archive');
      expect(pinIn(G.gamma), findsNothing);
      expect(pinIn(G.loose), findsNothing);
    });
  });

  group('edge hover (AC11)', () {
    testWidgets('hovering an edge shows a tooltip with its kind and label', (
      tester,
    ) async {
      final db = _db(_seedPair);
      await _pumpGraph(tester, db, const GraphScope.topic(G.alpha));
      await _settle(tester);
      final mouse = await _mouse(tester);
      expect(find.byKey(_tooltip), findsNothing);

      final mid = (_center(tester, G.alpha) + _center(tester, G.beta)) / 2.0;
      await mouse.moveTo(mid);
      await tester.pump();

      final tooltip = find.byKey(_tooltip);
      expect(tooltip, findsOneWidget);
      final text = _texts(tester, tooltip).join(' ');
      expect(text, contains('extends'));
      expect(text, contains('builds on'));
    });

    testWidgets('hovering an edge without a label shows its kind', (
      tester,
    ) async {
      final db = _db((db) => _seedPair(db, label: null, kind: 'references'));
      await _pumpGraph(tester, db, const GraphScope.topic(G.alpha));
      await _settle(tester);
      final mouse = await _mouse(tester);

      final mid = (_center(tester, G.alpha) + _center(tester, G.beta)) / 2.0;
      await mouse.moveTo(mid);
      await tester.pump();

      final tooltip = find.byKey(_tooltip);
      expect(tooltip, findsOneWidget);
      final text = _texts(tester, tooltip).join(' ');
      expect(text, contains('references'));
      expect(text, isNot(contains('null')));
    });

    testWidgets('moving the pointer off an edge hides the tooltip', (
      tester,
    ) async {
      final db = _db(_seedPair);
      await _pumpGraph(tester, db, const GraphScope.topic(G.alpha));
      await _settle(tester);
      final mouse = await _mouse(tester);

      final mid = (_center(tester, G.alpha) + _center(tester, G.beta)) / 2.0;
      await mouse.moveTo(mid);
      await tester.pump();
      expect(find.byKey(_tooltip), findsOneWidget);

      await mouse.moveTo(const Offset(8, 8));
      await tester.pump();
      expect(find.byKey(_tooltip), findsNothing);
    });
  });

  group('drag, pan and zoom (AC12)', () {
    /// Alpha extends Beta; Gamma is isolated.
    void seedTrio(FakeVaultDb db) {
      _seedPair(db);
      db.seedTopicNote(G.gamma, 'Gamma');
    }

    testWidgets('dragging a node moves it while the rest of the view stays', (
      tester,
    ) async {
      final db = _db(seedTrio);
      await _pumpGraph(tester, db, const GraphScope.vault());
      await _settle(tester);

      final gammaStart = _center(tester, G.gamma);
      final alphaStart = _center(tester, G.alpha);
      final drag = await tester.startGesture(gammaStart);
      for (var i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(16, 9));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final moved = _center(tester, G.gamma) - gammaStart;
      expect(moved.dx, greaterThan(96), reason: 'pointer moved 160 right');
      expect(moved.dy, greaterThan(54), reason: 'pointer moved 90 down');
      expect(
        (_center(tester, G.alpha) - alphaStart).distance,
        lessThan(40),
        reason: 'dragging a node does not pan the view',
      );

      await drag.up();
      await _settle(tester); // the reheat after a drag stops by itself
      expect(find.byKey(_node(G.gamma)), findsOneWidget);
    });

    testWidgets('dragging the background pans the whole view', (tester) async {
      final db = _db(seedTrio);
      await _pumpGraph(tester, db, const GraphScope.vault());
      await _settle(tester);

      final a0 = _center(tester, G.alpha);
      final b0 = _center(tester, G.beta);
      final pan = await tester.startGesture(const Offset(30, 30));
      for (var i = 0; i < 10; i++) {
        await pan.moveBy(const Offset(15, 8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await pan.up();
      await _settle(tester);

      final da = _center(tester, G.alpha) - a0;
      final db2 = _center(tester, G.beta) - b0;
      expect(da.dx, greaterThan(75), reason: 'pointer moved 150 right');
      expect(da.dy, greaterThan(35), reason: 'pointer moved 80 down');
      expect(
        (da - db2).distance,
        lessThan(1.0),
        reason: 'panning moves every node by the same amount',
      );
    });

    testWidgets('scrolling zooms the view in and out', (tester) async {
      final db = _db(seedTrio);
      await _pumpGraph(tester, db, const GraphScope.vault());
      await _settle(tester);

      double gap() =>
          (_center(tester, G.alpha) - _center(tester, G.beta)).distance;
      final before = gap();
      final mouse = await _mouse(tester);
      final center = tester.getCenter(find.byKey(_graphView));
      await mouse.moveTo(center);

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          kind: PointerDeviceKind.mouse,
          scrollDelta: const Offset(0, -300),
        ),
      );
      await _settle(tester);
      final zoomedIn = gap();
      expect(zoomedIn, greaterThan(before * 1.2));

      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: center,
          kind: PointerDeviceKind.mouse,
          scrollDelta: const Offset(0, 600),
        ),
      );
      await _settle(tester);
      expect(gap(), lessThan(zoomedIn / 1.2));
    });

    testWidgets(
      'dragging, panning and zooming write nothing to the vault or ui_state',
      (tester) async {
        final db = _db(seedTrio);
        final notesBefore = db.db.select('SELECT * FROM notes').length;
        final linksBefore = db.db.select('SELECT * FROM links').length;
        final g = await _pumpGraph(tester, db, const GraphScope.vault());
        await _settle(tester);

        final drag = await tester.startGesture(_center(tester, G.gamma));
        for (var i = 0; i < 6; i++) {
          await drag.moveBy(const Offset(20, 10));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await drag.up();
        await _settle(tester);

        final pan = await tester.startGesture(const Offset(30, 30));
        for (var i = 0; i < 6; i++) {
          await pan.moveBy(const Offset(20, 10));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await pan.up();
        await _settle(tester);

        final center = tester.getCenter(find.byKey(_graphView));
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            kind: PointerDeviceKind.mouse,
            scrollDelta: const Offset(0, -200),
          ),
        );
        await _settle(tester);

        expect(g.store.writes, isEmpty, reason: 'no ui_state.json write');
        expect(
          g.cli.calls.where((c) => c.subcommand != 'settings get'),
          isEmpty,
          reason: 'no memex write',
        );
        expect(
          Directory('${g.vaultDir.path}/.memex').existsSync(),
          isFalse,
          reason: 'nothing persisted beside the vault either',
        );
        expect(db.db.select('SELECT * FROM notes').length, notesBefore);
        expect(db.db.select('SELECT * FROM links').length, linksBefore);
      },
    );
  });

  group('simulation (AC14)', () {
    testWidgets(
      'the simulation stops by itself so pumpAndSettle completes on a 30-node graph',
      (tester) async {
        final db = _db((db) => seedTopicRing(db, 30));
        await _pumpGraph(tester, db, const GraphScope.vault());
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.binding.hasScheduledFrame,
          isTrue,
          reason: 'the force simulation animates after the first frame',
        );

        await _settle(tester);

        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(_anyNode, findsNWidgets(30));
      },
    );
  });
}
