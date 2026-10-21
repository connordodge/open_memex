import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// Pan + zoom for one canvas, kept in memory across tab switches.
class CanvasViewport {
  const CanvasViewport({required this.offset, required this.zoom});
  final Offset offset;
  final double zoom;

  static const initial = CanvasViewport(offset: Offset.zero, zoom: 1.0);

  CanvasViewport copyWith({Offset? offset, double? zoom}) =>
      CanvasViewport(offset: offset ?? this.offset, zoom: zoom ?? this.zoom);
}

/// Per-canvas viewport. Family keyed on canvas id.
final canvasViewportProvider = StateProvider.family<CanvasViewport, String>((
  ref,
  _,
) {
  return CanvasViewport.initial;
});

/// Per-canvas selection — which node ids and which edge id are currently
/// selected. Mutually exclusive: opening the edge inspector clears node
/// selection and vice versa.
class CanvasSelection {
  const CanvasSelection({
    this.selectedNodeIds = const <String>{},
    this.selectedEdgeId,
  });
  final Set<String> selectedNodeIds;
  final String? selectedEdgeId;

  static const empty = CanvasSelection();

  CanvasSelection withNodes(Set<String> ids) =>
      CanvasSelection(selectedNodeIds: ids);
  CanvasSelection withEdge(String? linkId) =>
      CanvasSelection(selectedEdgeId: linkId);
}

final canvasSelectionProvider = StateProvider.family<CanvasSelection, String>((
  ref,
  _,
) {
  return CanvasSelection.empty;
});

/// Whether a canvas tab is currently "zoomed into" a specific note. Drives
/// the AnimatedSwitcher from the canvas view to the embedded NoteEditor.
class CanvasZoomState {
  const CanvasZoomState({this.zoomedNoteId});
  final String? zoomedNoteId;

  static const none = CanvasZoomState();
  bool get isZoomed => zoomedNoteId != null;
}

final canvasZoomProvider = StateProvider.family<CanvasZoomState, String>((
  ref,
  _,
) {
  return CanvasZoomState.none;
});

/// Tunable animation config so widget tests can inject `Duration.zero`.
class CanvasAnimationConfig {
  const CanvasAnimationConfig({
    this.zoomDuration = const Duration(milliseconds: 250),
    this.persistDebounce = const Duration(milliseconds: 200),
  });
  final Duration zoomDuration;
  final Duration persistDebounce;
}

final canvasAnimationConfigProvider = Provider<CanvasAnimationConfig>(
  (_) => const CanvasAnimationConfig(),
);

/// All canvases in the current vault, ordered by `updated_at DESC`.
final canvasesProvider = Provider<List<CanvasRow>>((ref) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.listCanvases();
});

/// Hydrated canvas (metadata + placed nodes + edges). Provider.family keyed
/// on canvas id.
final canvasDetailProvider = Provider.family<CanvasDetailRow?, String>((
  ref,
  canvasId,
) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return null;
  return db.getCanvasDetail(canvasId);
});

/// Test skeleton (WI #89, red): the canvas list read through `VaultAccess`,
/// stamped with the vault it was read for (D14a). The implementer replaces
/// the body.
final canvasesAsyncProvider = FutureProvider<VaultScoped<List<CanvasRow>>>(
  (ref) => throw UnimplementedError('canvasesAsyncProvider'),
);

/// Test skeleton (WI #89, red): one hydrated canvas read through
/// `VaultAccess`, or null for an unknown id, stamped with the vault it was
/// read for (D14a). The implementer replaces the body.
final canvasDetailAsyncProvider =
    FutureProvider.family<VaultScoped<CanvasDetailRow?>, String>(
      (ref, canvasId) => throw UnimplementedError('canvasDetailAsyncProvider'),
    );
