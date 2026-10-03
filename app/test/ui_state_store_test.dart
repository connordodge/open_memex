import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ui_state_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('read returns empty when file is missing', () {
    final store = UiStateStore(vaultPath: tmp.path);
    final state = store.read();
    expect(state.tabs, isEmpty);
    expect(state.activeTabIndex, 0);
    expect(state.canvasViewports, isEmpty);
  });

  test('write then read round-trips tabs + viewport', () async {
    final store = UiStateStore(vaultPath: tmp.path);
    final original = UiState(
      tabs: [
        PersistedTab(kind: PersistedTab.kindNote, id: '01H'),
        PersistedTab(kind: PersistedTab.kindCanvas, id: '01C'),
      ],
      activeTabIndex: 1,
      canvasViewports: {'01C': CanvasViewport(dx: 10.0, dy: -20.0, zoom: 1.5)},
    );
    await store.write(original);

    expect(
      File(p.join(tmp.path, '.memex', 'ui_state.json')).existsSync(),
      isTrue,
    );
    final reread = store.read();
    expect(reread.tabs.length, 2);
    expect(reread.tabs[0].kind, PersistedTab.kindNote);
    expect(reread.tabs[1].id, '01C');
    expect(reread.activeTabIndex, 1);
    expect(reread.canvasViewports['01C']!.zoom, 1.5);
  });

  test('corrupted file falls back to empty state', () async {
    final memexDir = Directory(p.join(tmp.path, '.memex'));
    memexDir.createSync();
    File(
      p.join(memexDir.path, 'ui_state.json'),
    ).writeAsStringSync('{ not valid json');
    final store = UiStateStore(vaultPath: tmp.path);
    expect(store.read().tabs, isEmpty);
  });

  test('atomic write does not leave stale .tmp on success', () async {
    final store = UiStateStore(vaultPath: tmp.path);
    await store.write(UiState.empty());
    final tmpFile = File(p.join(tmp.path, '.memex', 'ui_state.json.tmp'));
    expect(tmpFile.existsSync(), isFalse);
  });

  test('drops unknown tab kinds', () async {
    final memexDir = Directory(p.join(tmp.path, '.memex'));
    memexDir.createSync();
    final raw = '''
    {
      "tabs": [
        {"kind": "note", "id": "01H"},
        {"kind": "mystery", "id": "01M"},
        {"kind": "canvas", "id": "01C"}
      ],
      "active_tab_index": 0,
      "canvas_viewports": {}
    }
    ''';
    File(p.join(memexDir.path, 'ui_state.json')).writeAsStringSync(raw);
    final state = UiStateStore(vaultPath: tmp.path).read();
    expect(state.tabs.length, 2);
    expect(state.tabs.map((t) => t.kind).toList(), [
      PersistedTab.kindNote,
      PersistedTab.kindCanvas,
    ]);
  });

  test('drops non-finite or negative viewport zoom', () async {
    final memexDir = Directory(p.join(tmp.path, '.memex'));
    memexDir.createSync();
    final raw = '''
    {
      "tabs": [],
      "active_tab_index": 0,
      "canvas_viewports": {
        "good": {"dx": 1, "dy": 2, "zoom": 1.5},
        "bad": {"dx": 0, "dy": 0, "zoom": -1}
      }
    }
    ''';
    File(p.join(memexDir.path, 'ui_state.json')).writeAsStringSync(raw);
    final state = UiStateStore(vaultPath: tmp.path).read();
    expect(state.canvasViewports.keys.toList(), ['good']);
  });

  test('flush completes after every queued write has landed', () async {
    final tmp = await Directory.systemTemp.createTemp('ui_state_flush');
    addTearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final store = UiStateStore(vaultPath: tmp.path);
    final state = store.read();
    final a = store.write(state);
    final b = store.write(state);
    await store.flush();
    var done = 0;
    await Future.wait([a.then((_) => done++), b.then((_) => done++)]);
    expect(done, 2);
    expect(File('${tmp.path}/.memex/ui_state.json').existsSync(), isTrue);
  });
}
