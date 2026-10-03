import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Per-vault, machine-local UI state: open tabs, active tab, and per-canvas
/// viewport (pan + zoom). Lives outside the vault DB so MCP clients never see
/// it and so the file can change shape without a schema migration.
///
/// File path: `<vaultPath>/.memex/ui_state.json`. Writes are atomic via the
/// classic tmp + rename pattern.
class UiStateStore {
  UiStateStore({required this.vaultPath});

  final String vaultPath;

  static const int defaultTabCap = 20;

  String get _filePath => p.join(vaultPath, '.memex', 'ui_state.json');

  /// Serialize concurrent writes so the tmp+rename pattern stays atomic.
  Future<void> _writeQueue = Future<void>.value();

  /// Read the persisted state. Returns the empty state when the file is
  /// missing or corrupt — never throws.
  UiState read() {
    try {
      final file = File(_filePath);
      if (!file.existsSync()) return UiState.empty();
      final text = file.readAsStringSync();
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) return UiState.empty();
      return UiState.fromJson(json);
    } catch (_) {
      return UiState.empty();
    }
  }

  /// Persist [state] atomically. Creates the `.memex/` directory if needed.
  /// Writes are serialized: a second `write` call awaits the first.
  Future<void> write(UiState state) {
    final next = _writeQueue.then((_) => _doWrite(state));
    // Swallow errors on the chained future so one failure doesn't poison
    // every subsequent write; individual callers still observe their own.
    _writeQueue = next.catchError((_) {});
    return next;
  }

  /// Completes once every write queued so far has finished (successfully or
  /// not). Lets callers and tests wait for unawaited persistence.
  Future<void> flush() => _writeQueue;

  Future<void> _doWrite(UiState state) async {
    final dir = Directory(p.dirname(_filePath));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final tmp = File('$_filePath.tmp');
    final encoded = const JsonEncoder.withIndent('  ').convert(state.toJson());
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(_filePath);
  }
}

/// In-memory shape of the per-vault UI state.
class UiState {
  UiState({
    required this.tabs,
    required this.activeTabIndex,
    required this.canvasViewports,
  });

  factory UiState.empty() =>
      UiState(tabs: const [], activeTabIndex: 0, canvasViewports: const {});

  final List<PersistedTab> tabs;
  final int activeTabIndex;
  final Map<String, CanvasViewport> canvasViewports;

  Map<String, dynamic> toJson() => {
    'tabs': tabs.map((t) => t.toJson()).toList(),
    'active_tab_index': activeTabIndex,
    'canvas_viewports': canvasViewports.map((k, v) => MapEntry(k, v.toJson())),
  };

  static UiState fromJson(Map<String, dynamic> json) {
    final tabs = ((json['tabs'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PersistedTab.fromJson)
        .whereType<PersistedTab>()
        .toList();
    final active = (json['active_tab_index'] as num?)?.toInt() ?? 0;
    final viewports = <String, CanvasViewport>{};
    final raw = json['canvas_viewports'];
    if (raw is Map<String, dynamic>) {
      raw.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          final vp = CanvasViewport.fromJson(v);
          if (vp != null) viewports[k] = vp;
        }
      });
    }
    return UiState(
      tabs: tabs,
      activeTabIndex: active.clamp(0, tabs.isEmpty ? 0 : tabs.length - 1),
      canvasViewports: viewports,
    );
  }
}

/// Tagged-union of tab kinds. `kind` ∈ {`note`, `canvas`}; `id` is the
/// underlying note_id or canvas_id.
class PersistedTab {
  PersistedTab({required this.kind, required this.id});

  static const String kindNote = 'note';
  static const String kindCanvas = 'canvas';

  final String kind;
  final String id;

  bool get isNote => kind == kindNote;
  bool get isCanvas => kind == kindCanvas;

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id};

  static PersistedTab? fromJson(Map<String, dynamic> json) {
    final k = json['kind'] as String?;
    final i = json['id'] as String?;
    if (k == null || i == null) return null;
    if (k != kindNote && k != kindCanvas) return null;
    return PersistedTab(kind: k, id: i);
  }

  @override
  bool operator ==(Object other) =>
      other is PersistedTab && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// Pan + zoom state for one canvas.
class CanvasViewport {
  CanvasViewport({required this.dx, required this.dy, required this.zoom});

  final double dx;
  final double dy;
  final double zoom;

  Map<String, dynamic> toJson() => {'dx': dx, 'dy': dy, 'zoom': zoom};

  static CanvasViewport? fromJson(Map<String, dynamic> json) {
    final dx = (json['dx'] as num?)?.toDouble();
    final dy = (json['dy'] as num?)?.toDouble();
    final zoom = (json['zoom'] as num?)?.toDouble();
    if (dx == null || dy == null || zoom == null) return null;
    if (!zoom.isFinite || zoom <= 0) return null;
    return CanvasViewport(dx: dx, dy: dy, zoom: zoom);
  }
}
