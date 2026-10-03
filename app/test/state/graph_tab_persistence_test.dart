// WI #30 (A12): GraphTab identity and persistence in ui_state.json (D26).
// Kind `graph`, id `<scope>:<id>`; older or unknown kinds are dropped while
// the other tabs still load.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

void main() {
  late Directory tmp;
  late UiStateStore store;
  final notifiers = <TabsNotifier>[];

  String filePath() => '${tmp.path}/.memex/ui_state.json';

  Map<String, dynamic> readJson() =>
      jsonDecode(File(filePath()).readAsStringSync()) as Map<String, dynamic>;

  void writeRawJson(Map<String, dynamic> json) {
    Directory('${tmp.path}/.memex').createSync(recursive: true);
    File(filePath()).writeAsStringSync(jsonEncode(json));
  }

  TabsNotifier restart() {
    final n = TabsNotifier(store: store, onPersistedSelection: (_) {});
    notifiers.add(n);
    return n;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('graph_tab_persistence');
    store = UiStateStore(vaultPath: tmp.path);
  });

  tearDown(() async {
    for (final n in notifiers) {
      n.dispose();
    }
    notifiers.clear();
    await store.flush();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('GraphTab identity (D26)', () {
    test('GraphTab ids are the scope kind and id joined by a colon', () {
      expect(GraphTab(const GraphScope.folder('sf1')).id, 'folder:sf1');
      expect(GraphTab(const GraphScope.topic('n1')).id, 'topic:n1');
      expect(GraphTab(const GraphScope.day('d1')).id, 'day:d1');
      expect(GraphTab(const GraphScope.vault()).id, 'vault:all');
    });

    test('GraphTab tab ids are graph- followed by the scope id', () {
      expect(GraphTab(const GraphScope.topic('n1')).tabId, 'graph-topic:n1');
      expect(GraphTab(const GraphScope.vault()).tabId, 'graph-vault:all');
    });

    test('GraphTabs with the same scope are equal and differ otherwise', () {
      final a = GraphTab(const GraphScope.topic('n1'));
      final b = GraphTab(const GraphScope.topic('n1'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(GraphTab(const GraphScope.day('n1'))));
      expect(a, isNot(GraphTab(const GraphScope.topic('n2'))));
      expect(a, isNot(const NoteTab('n1')));
      expect(a, isNot(const NoteTab('topic:n1')));
    });
  });

  group('ui_state.json (AC7)', () {
    test('a Graph tab is stored as kind graph with id topic:<id>', () async {
      final tabs = restart();
      tabs.openOrFocus(const NoteTab('n0'));
      tabs.openOrFocus(GraphTab(const GraphScope.topic('n1')));
      await store.flush();

      final json = readJson();
      expect(json['tabs'], [
        {'kind': 'note', 'id': 'n0'},
        {'kind': 'graph', 'id': 'topic:n1'},
      ]);
      expect(json['active_tab_index'], 1);
    });

    test(
      'a Graph tab survives a restart and is restored as the active tab',
      () async {
        final first = restart();
        first.openOrFocus(const NoteTab('n0'));
        first.openOrFocus(GraphTab(const GraphScope.topic('n1')));
        await store.flush();

        final second = restart();
        expect(second.state.tabs, [
          const NoteTab('n0'),
          GraphTab(const GraphScope.topic('n1')),
        ]);
        final active = second.state.activeTab;
        expect(active, isA<GraphTab>());
        expect((active! as GraphTab).scope.kind, GraphScopeKind.topic);
        expect((active as GraphTab).scope.id, 'n1');
      },
    );

    test('every Graph scope round-trips through ui_state.json', () async {
      final first = restart();
      final opened = [
        GraphTab(const GraphScope.folder('sf1')),
        GraphTab(const GraphScope.topic('t1')),
        GraphTab(const GraphScope.day('d1')),
        GraphTab(const GraphScope.vault()),
      ];
      opened.forEach(first.openOrFocus);
      await store.flush();

      expect(
        (readJson()['tabs'] as List).map((t) => (t as Map)['id']).toList(),
        ['folder:sf1', 'topic:t1', 'day:d1', 'vault:all'],
      );
      final second = restart();
      expect(second.state.tabs, opened);
      expect(
        second.state.tabs.map((t) => (t as GraphTab).scope.kind).toList(),
        [
          GraphScopeKind.folder,
          GraphScopeKind.topic,
          GraphScopeKind.day,
          GraphScopeKind.vault,
        ],
      );
    });

    test('a restored Graph tab is focused when opened again', () async {
      final first = restart();
      first.openOrFocus(GraphTab(const GraphScope.day('d1')));
      first.openOrFocus(const NoteTab('n0'));
      await store.flush();

      final second = restart();
      expect(second.state.activeIndex, 1);
      second.openOrFocus(GraphTab(const GraphScope.day('d1')));
      expect(second.state.tabs.length, 2);
      expect(second.state.activeIndex, 0);
    });

    test('a ui_state.json with an unknown kind still loads the other tabs', () {
      writeRawJson({
        'tabs': [
          {'kind': 'note', 'id': 'n0'},
          {'kind': 'timeline', 'id': 'x'},
          {'kind': 'graph', 'id': 'topic:t1'},
          {'kind': 'canvas', 'id': 'c1'},
        ],
        'active_tab_index': 0,
        'canvas_viewports': <String, dynamic>{},
      });

      final tabs = restart();
      expect(tabs.state.tabs, [
        const NoteTab('n0'),
        GraphTab(const GraphScope.topic('t1')),
        const CanvasTab('c1'),
      ]);
    });

    test('a graph entry with an unknown or malformed scope is dropped', () {
      writeRawJson({
        'tabs': [
          {'kind': 'graph', 'id': 'galaxy:x'},
          {'kind': 'graph', 'id': 'topic'},
          {'kind': 'note', 'id': 'n0'},
          {'kind': 'graph', 'id': 'vault:all'},
        ],
        'active_tab_index': 0,
        'canvas_viewports': <String, dynamic>{},
      });

      final tabs = restart();
      expect(tabs.state.tabs, [
        const NoteTab('n0'),
        GraphTab(const GraphScope.vault()),
      ]);
    });
  });
}
