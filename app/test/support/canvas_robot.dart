// WI #89 (W5): a harness and a robot for the canvas view. The harness pumps a
// bare CanvasView (not the workspace, whose OmDot pulse never settles) next to
// a note-drag source; the robot drives drags, drops, links and edge edits and
// reads what the view paints.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/canvas_edge_painter.dart';
import 'package:open_memex_app/src/widgets/canvas_view.dart';

import 'canvas_seeds.dart';
import 'fake_memex_cli.dart';

/// Key of the note source the drop tests drag onto the canvas.
const wi89DropSourceKey = Key('wi89-drop-source');

/// Note id the drop source carries.
const wi89DroppedNoteId = C89.gamma;

/// The debounce the move tests run with (the production default).
const wi89Debounce = Duration(milliseconds: 200);

/// A [CanvasView] for [canvasId] in a 800x600 window under a Scaffold, with a
/// 60 px strip above it holding a `Draggable<String>` of [wi89DroppedNoteId].
Widget wi89CanvasHost(String canvasId) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        SizedBox(
          height: 60,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Draggable<String>(
              data: wi89DroppedNoteId,
              feedback: const SizedBox(width: 40, height: 20),
              child: Container(
                key: wi89DropSourceKey,
                width: 40,
                height: 20,
                color: const Color(0xFFCC3333),
              ),
            ),
          ),
        ),
        Expanded(child: CanvasView(canvasId: canvasId)),
      ],
    ),
  ),
);

/// Pumps [wi89CanvasHost] over a container built from [overrides]. Settles
/// the first frames but never `pumpAndSettle`.
Future<ProviderContainer> pumpWi89Host(
  WidgetTester tester,
  String canvasId, {
  required List<Override> overrides,
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      canvasAnimationConfigProvider.overrideWithValue(
        const CanvasAnimationConfig(
          zoomDuration: Duration.zero,
          persistDebounce: wi89Debounce,
        ),
      ),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: wi89CanvasHost(canvasId),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

/// Overrides that open [first] and serve [canvases] / [notes] per vault
/// through a [LocalVaultAccess] (D21). With [canWrite] false there is no CLI
/// at all (`canWrite` false, `memexCliProvider` null). A vault with no entry
/// in [canvases] has no access.
List<Override> wi89DoubleOverrides({
  required Map<VaultRef, Wi89Canvas> canvases,
  Map<VaultRef, Wi89Notes> notes = const {},
  required VaultRef? first,
  bool canWrite = true,
}) => [
  currentVaultProvider.overrideWith((_) => first),
  vaultDbProvider.overrideWithValue(null),
  memexCliProvider.overrideWithValue(canWrite ? FakeMemexCli() : null),
  vaultAccessProvider.overrideWith((ref) {
    final vault = ref.watch(currentVaultProvider);
    final canvas = canvases[vault];
    if (canvas == null) return null;
    return LocalVaultAccess(
      vaultPath: vault.localPath ?? '/tmp/om-89-hosted',
      cli: canWrite ? FakeMemexCli() : null,
      canvas: canvas,
      notes: notes[vault],
    );
  }),
];

/// A harness over [wi89DoubleOverrides] for one pumped CanvasView.
class CanvasHarness {
  CanvasHarness._(
    this.container,
    this.canvasId,
    this.canvases,
    this.notes,
    this.first,
  );

  final ProviderContainer container;
  final String canvasId;
  final Map<VaultRef, Wi89Canvas> canvases;
  final Map<VaultRef, Wi89Notes> notes;
  final VaultRef first;

  Wi89Canvas get canvas => canvases[first]!;
  Wi89Notes get notesA => notes[first]!;
  int get revision => container.read(vaultRevisionProvider);
  VaultRef? get vault => container.read(currentVaultProvider);

  void switchTo(VaultRef? vault) =>
      container.read(currentVaultProvider.notifier).state = vault;

  static Future<CanvasHarness> pump(
    WidgetTester tester,
    String canvasId, {
    required Map<VaultRef, Wi89Canvas> canvases,
    Map<VaultRef, Wi89Notes>? notes,
    VaultRef? first,
    bool canWrite = true,
  }) async {
    final start = first ?? canvases.keys.first;
    final notesByVault =
        notes ?? {for (final v in canvases.keys) v: Wi89Notes()};
    final container = await pumpWi89Host(
      tester,
      canvasId,
      overrides: wi89DoubleOverrides(
        canvases: canvases,
        notes: notesByVault,
        first: start,
        canWrite: canWrite,
      ),
    );
    return CanvasHarness._(container, canvasId, canvases, notesByVault, start);
  }
}

/// Drives and reads one [CanvasView].
class CanvasRobot {
  CanvasRobot(this.tester, this.canvasId);

  final WidgetTester tester;
  final String canvasId;

  Finder get view => find.byKey(Key('canvas-view-$canvasId'));
  Finder node(String noteId) => find.byKey(Key('canvas-node-$noteId'));
  Finder get loadingText => find.text('Loading canvas…');

  /// A node's painted top-left in canvas coordinates (the viewport is the
  /// identity transform in these tests).
  Offset nodePosition(String noteId) =>
      tester.getTopLeft(node(noteId)) - tester.getTopLeft(view);

  /// Ids of the painted nodes.
  Set<String> get nodeIds => {
    for (final e
        in find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith('canvas-node-'),
            )
            .evaluate())
      (e.widget.key! as ValueKey<String>).value.substring(
        'canvas-node-'.length,
      ),
  };

  /// Link ids of the edges the painter was given.
  List<String> get edgeIds {
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((p) => p.painter)
        .whereType<CanvasEdgePainter>();
    return [for (final p in painters) ...p.edges.map((e) => e.linkId)];
  }

  /// Pans [noteId] by [delta] with one drag, in ten steps so the pan wins
  /// the gesture arena over the viewer.
  Future<void> dragNode(String noteId, Offset delta) async {
    final gesture = await tester.startGesture(tester.getCenter(node(noteId)));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(delta / 10);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  /// Drags the note source onto the canvas by [delta] and returns the canvas
  /// coordinate the feedback's top-left lands on.
  Future<Offset> dropNote(Offset delta) async {
    final source = find.byKey(wi89DropSourceKey);
    final topLeft = tester.getTopLeft(source);
    final gesture = await tester.startGesture(tester.getCenter(source));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(delta / 10);
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump();
    return topLeft + delta - tester.getTopLeft(view);
  }

  /// Drags the edge handle of [from] onto [to], which opens the link popover.
  Future<void> startLink(String from, String to) async {
    final handle = tester.getCenter(find.byKey(Key('edge-handle-$from')));
    final target = tester.getCenter(node(to));
    final gesture = await tester.startGesture(handle);
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveTo(Offset.lerp(handle, target, 0.5)!);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();
  }

  /// Lets the closing dialog run out its timers.
  Future<void> settle() async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// Links [from] to [to] and confirms the popover with [kind] (a built-in
  /// chip) and [label] (typed when non-null).
  Future<void> linkNodes(
    String from,
    String to, {
    String? kind,
    String? label,
  }) async {
    await startLink(from, to);
    if (kind != null) {
      await tester.tap(find.byKey(Key('edge-kind-chip-$kind')));
      await tester.pump();
    }
    if (label != null) {
      await tester.enterText(find.byKey(const Key('edge-label-input')), label);
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('link-popover-confirm')));
    await settle();
  }

  /// Selects [linkId] (opens the edge inspector).
  Future<void> selectEdge(ProviderContainer container, String linkId) async {
    container.read(canvasSelectionProvider(canvasId).notifier).state =
        CanvasSelection(selectedEdgeId: linkId);
    await tester.pump();
  }

  /// Edits the open edge inspector: taps [kind]'s chip, replaces the label
  /// with [label] (empty clears it) and taps Save.
  Future<void> saveEdge(
    ProviderContainer container, {
    String? kind,
    String? label,
  }) async {
    if (kind != null) {
      await tester.tap(find.byKey(Key('edge-kind-chip-$kind')));
      await tester.pump();
    }
    if (label != null) {
      await tester.enterText(find.byKey(const Key('edge-label-input')), label);
      await tester.pump();
    }
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump();
  }
}
