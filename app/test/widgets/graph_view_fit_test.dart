// WI #30 (A12): Graph view behaviour beyond the ACs (implementer tests):
// the view keeps the layout in sight until the person takes over, trackpad
// pinch zoom, hovering a node, and the empty scope.
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/graph/graph_view.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/graph_seeds.dart';

const _graphView = Key('graph-view');
const _tooltip = Key('graph-edge-tooltip');

Future<void> _pump(
  WidgetTester tester,
  void Function(FakeVaultDb db) seed,
  GraphScope scope,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  seed(db);
  final container = ProviderContainer(
    overrides: [vaultDbProvider.overrideWithValue(db)],
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
}

Future<void> _settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 16),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 60),
);

Offset _centre(WidgetTester tester, String id) =>
    tester.getCenter(find.byKey(Key('graph-node-$id')));

void _seedTrio(FakeVaultDb db) {
  db.seedTopicNote(G.alpha, 'Alpha');
  db.seedTopicNote(G.beta, 'Beta');
  db.seedTopicNote(G.gamma, 'Gamma');
  db.seedLink(G.alpha, G.beta, kind: 'extends');
}

void main() {
  testWidgets('the settled view keeps every node of a large graph in sight', (
    tester,
  ) async {
    await _pump(
      tester,
      (db) => seedTopicRing(db, 30),
      const GraphScope.vault(),
    );
    await _settle(tester);

    final view = tester.getRect(find.byKey(_graphView));
    for (var i = 0; i < 30; i++) {
      final id = 't${i.toString().padLeft(2, '0')}';
      expect(view.contains(_centre(tester, id)), isTrue, reason: id);
    }
  });

  testWidgets('the view stops following the layout once the person zooms', (
    tester,
  ) async {
    await _pump(
      tester,
      (db) => seedTopicRing(db, 30),
      const GraphScope.vault(),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final centre = tester.getCenter(find.byKey(_graphView));
    // Zoom far in while the layout is still moving: the view must not
    // zoom back out to fit the layout afterwards.
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: centre,
        kind: PointerDeviceKind.mouse,
        scrollDelta: const Offset(0, -1200),
      ),
    );
    await _settle(tester);

    final view = tester.getRect(find.byKey(_graphView));
    final outside = [
      for (var i = 0; i < 30; i++)
        if (!view.contains(_centre(tester, 't${i.toString().padLeft(2, '0')}')))
          i,
    ];
    expect(outside, isNotEmpty);
  });

  testWidgets('pinching a trackpad zooms the view', (tester) async {
    await _pump(tester, _seedTrio, const GraphScope.vault());
    await _settle(tester);
    double gap() =>
        (_centre(tester, G.alpha) - _centre(tester, G.beta)).distance;
    final before = gap();

    final centre = tester.getCenter(find.byKey(_graphView));
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pointer.panZoomStart(centre));
    await tester.sendEventToBinding(pointer.panZoomUpdate(centre, scale: 1.5));
    await tester.sendEventToBinding(pointer.panZoomUpdate(centre, scale: 2));
    await tester.sendEventToBinding(pointer.panZoomEnd());
    await _settle(tester);

    expect(gap(), moreOrLessEquals(before * 2, epsilon: 0.5));
  });

  testWidgets('hovering a node shows no edge tooltip', (tester) async {
    await _pump(tester, _seedTrio, const GraphScope.vault());
    await _settle(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(2, 2));
    addTearDown(mouse.removePointer);

    final mid = (_centre(tester, G.alpha) + _centre(tester, G.beta)) / 2.0;
    await mouse.moveTo(mid);
    await tester.pump();
    expect(find.byKey(_tooltip), findsOneWidget);

    await mouse.moveTo(_centre(tester, G.alpha));
    await tester.pump();
    expect(find.byKey(_tooltip), findsNothing);
  });

  testWidgets('a scope with no notes shows a hint and no nodes', (
    tester,
  ) async {
    await _pump(tester, (_) {}, const GraphScope.topic('note-missing'));
    await _settle(tester);

    expect(find.text('Nothing to show in this graph yet.'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
