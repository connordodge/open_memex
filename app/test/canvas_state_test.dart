import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/canvas_state.dart';

void main() {
  test('canvasViewportProvider family defaults to identity per canvas', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final a = c.read(canvasViewportProvider('a'));
    final b = c.read(canvasViewportProvider('b'));
    expect(a.zoom, 1.0);
    expect(a.offset, Offset.zero);
    expect(b.zoom, 1.0);
  });

  test('canvasViewportProvider preserves per-canvas state independently', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(canvasViewportProvider('a').notifier).state = const CanvasViewport(
      offset: Offset(10, 20),
      zoom: 2.0,
    );
    expect(c.read(canvasViewportProvider('a')).zoom, 2.0);
    // Canvas 'b' is untouched.
    expect(c.read(canvasViewportProvider('b')).zoom, 1.0);
  });

  test('canvasZoomProvider toggles between zoomed-in and none', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(canvasZoomProvider('a')).isZoomed, isFalse);
    c.read(canvasZoomProvider('a').notifier).state = const CanvasZoomState(
      zoomedNoteId: 'note-1',
    );
    expect(c.read(canvasZoomProvider('a')).isZoomed, isTrue);
    expect(c.read(canvasZoomProvider('a')).zoomedNoteId, 'note-1');
    c.read(canvasZoomProvider('a').notifier).state = CanvasZoomState.none;
    expect(c.read(canvasZoomProvider('a')).isZoomed, isFalse);
  });

  test('canvasSelectionProvider mutually-exclusive node vs edge selection', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(canvasSelectionProvider('a').notifier);
    notifier.state = notifier.state.withEdge('link-1');
    expect(c.read(canvasSelectionProvider('a')).selectedEdgeId, 'link-1');
    expect(c.read(canvasSelectionProvider('a')).selectedNodeIds, isEmpty);
    // Switching to nodes via `withNodes` clears edge selection.
    notifier.state = notifier.state.withNodes({'n1'});
    expect(c.read(canvasSelectionProvider('a')).selectedNodeIds, {'n1'});
    expect(c.read(canvasSelectionProvider('a')).selectedEdgeId, isNull);
  });

  test('animation config can be overridden for tests via the provider', () {
    final c = ProviderContainer(
      overrides: [
        canvasAnimationConfigProvider.overrideWithValue(
          const CanvasAnimationConfig(
            zoomDuration: Duration.zero,
            persistDebounce: Duration.zero,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final cfg = c.read(canvasAnimationConfigProvider);
    expect(cfg.zoomDuration, Duration.zero);
    expect(cfg.persistDebounce, Duration.zero);
  });
}
