import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'app_support_dir.dart';
import 'vault_state.dart';

/// The UI state store of the open vault (Req 35):
/// `<vault>/.memex/ui_state.json` for a local vault; for a hosted vault a
/// store under `<app support>/hosted/<serverId>/<vaultName>` (D19), so two
/// vaults of one name on different servers keep separate state and nothing
/// is written in any vault folder. Null with no vault open, and for a
/// hosted vault while no app-support dir is set (`appSupportDirProvider`
/// not overridden, as in tests that never open one through `main()`).
final uiStateStoreProvider = Provider<UiStateStore?>((ref) {
  final vault = ref.watch(currentVaultProvider);
  switch (vault) {
    case null:
      return null;
    case LocalVaultRef(:final path):
      return UiStateStore(vaultPath: path);
    case HostedVaultRef(:final serverId, :final vaultName):
      final String appSupport;
      try {
        appSupport = ref.watch(appSupportDirProvider);
      } on UnimplementedError {
        return null;
      }
      return UiStateStore(
        vaultPath: hostedUiStateDir(appSupport, serverId, vaultName),
      );
  }
});

/// `<appSupport>/hosted/<serverId>/<vaultName>`, each name one encoded path
/// segment.
String hostedUiStateDir(String appSupport, String serverId, String vaultName) =>
    p.join(
      appSupport,
      'hosted',
      Uri.encodeComponent(serverId),
      Uri.encodeComponent(vaultName),
    );

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

  /// Per file: the write queue that serializes every store's writes, so the
  /// tmp+rename pattern stays atomic even with one store per provider.
  static final Map<String, Future<void>> _queues = {};

  /// Per file: the latest state queued and not yet on disk. [read] returns it
  /// so a read-modify-write (the tabs, the sidebar mode) never builds on a
  /// file another write is about to replace.
  static final Map<String, UiState> _pending = {};

  /// Read the persisted state (or the newest state still waiting to be
  /// written). Returns the empty state when the file is missing or corrupt —
  /// never throws.
  UiState read() {
    final pending = _pending[_filePath];
    if (pending != null) return pending;
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
  /// Writes to one file are serialized across stores: a second `write` call
  /// awaits the first.
  Future<void> write(UiState state) {
    final path = _filePath;
    _pending[path] = state;
    final next = flush().then((_) => _doWrite(state));
    // Swallow errors on the chained future so one failure doesn't poison
    // every subsequent write; individual callers still observe their own.
    late final Future<void> settled;
    settled = next.catchError((_) {}).whenComplete(() {
      if (identical(_pending[path], state)) _pending.remove(path);
      if (identical(_queues[path], settled)) _queues.remove(path);
    });
    _queues[path] = settled;
    return next;
  }

  /// Completes once every write queued so far for this file has finished
  /// (successfully or not), by this store or another one on the same vault.
  /// Lets callers and tests wait for unawaited persistence.
  Future<void> flush() => _queues[_filePath] ?? Future<void>.value();

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

/// The sidebar's two modes (Req 50, WI #23), persisted per vault as
/// `sidebar_mode` (`days` | `topics`). A missing or unknown value reads as
/// [SidebarMode.days].
enum SidebarMode { days, topics, tags }

/// In-memory shape of the per-vault UI state.
class UiState {
  UiState({
    required this.tabs,
    required this.activeTabIndex,
    required this.canvasViewports,
    this.sidebarMode = SidebarMode.days,
  });

  factory UiState.empty() =>
      UiState(tabs: const [], activeTabIndex: 0, canvasViewports: const {});

  final List<PersistedTab> tabs;
  final int activeTabIndex;
  final Map<String, CanvasViewport> canvasViewports;

  /// The sidebar mode (`sidebar_mode`), [SidebarMode.days] by default.
  final SidebarMode sidebarMode;

  Map<String, dynamic> toJson() => {
    'tabs': tabs.map((t) => t.toJson()).toList(),
    'active_tab_index': activeTabIndex,
    'canvas_viewports': canvasViewports.map((k, v) => MapEntry(k, v.toJson())),
    'sidebar_mode': sidebarMode.name,
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
      sidebarMode: switch (json['sidebar_mode']) {
        'topics' => SidebarMode.topics,
        _ => SidebarMode.days,
      },
    );
  }
}

/// Tagged-union of tab kinds. `kind` ∈ {`note`, `canvas`, `graph`}; `id` is
/// the underlying note_id or canvas_id, or for `graph` the scope as
/// `<scope>:<id>` (D26: `folder:<smartFolderId>`, `topic:<noteId>`,
/// `day:<noteId>`, `vault:all`). Unknown kinds are dropped on read, so older
/// apps skip newer tab kinds and keep the rest.
class PersistedTab {
  PersistedTab({required this.kind, required this.id});

  static const String kindNote = 'note';
  static const String kindCanvas = 'canvas';
  static const String kindGraph = 'graph';

  static const _knownKinds = {kindNote, kindCanvas, kindGraph};

  final String kind;
  final String id;

  bool get isNote => kind == kindNote;
  bool get isCanvas => kind == kindCanvas;
  bool get isGraph => kind == kindGraph;

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id};

  /// Null for an unknown kind or a malformed entry (missing or non-string
  /// `kind`/`id`).
  static PersistedTab? fromJson(Map<String, dynamic> json) {
    if (json case {
      'kind': final String k,
      'id': final String i,
    } when _knownKinds.contains(k)) {
      return PersistedTab(kind: k, id: i);
    }
    return null;
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
