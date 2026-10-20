// WI #87 (W3, verify): `emptyTopicsTree()` is the value the Topics pane shows
// while the first read is loading (the VaultAsyncView empty value).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/topics_state.dart';

void main() {
  test('emptyTopicsTree has no folders and no unsorted notes and is empty', () {
    final tree = emptyTopicsTree();
    expect(tree.folders, isEmpty);
    expect(tree.unsorted.notes, isEmpty);
    expect(tree.isEmpty, isTrue);
  });
}
