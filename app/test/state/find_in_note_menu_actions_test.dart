// WI #80 (Spec #61 F1, TD5): the native menu action dispatch F5 feeds and
// F6 performs.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';

void main() {
  test(
    'findMenuActionsProvider raises its sequence once per dispatch so two equal dispatches notify twice',
    () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(findMenuActionsProvider), isNull);

      final seen = <FindMenuDispatch?>[];
      c.listen<FindMenuDispatch?>(
        findMenuActionsProvider,
        (_, next) => seen.add(next),
      );
      final menu = c.read(findMenuActionsProvider.notifier);

      menu.dispatch(FindMenuAction.next);
      menu.dispatch(FindMenuAction.next);
      menu.dispatch(FindMenuAction.useSelection);

      expect(seen, const [
        FindMenuDispatch(FindMenuAction.next, 1),
        FindMenuDispatch(FindMenuAction.next, 2),
        FindMenuDispatch(FindMenuAction.useSelection, 3),
      ]);
      expect(
        c.read(findMenuActionsProvider),
        const FindMenuDispatch(FindMenuAction.useSelection, 3),
      );
    },
  );

  test('FindMenuAction names the four native Find items', () {
    expect(FindMenuAction.values.map((a) => a.name), [
      'show',
      'next',
      'previous',
      'useSelection',
    ]);
  });

  test('FindMenuDispatch compares action and sequence by value', () {
    final seq = DateTime(2026).year - 2025; // 1, built at run time
    expect(
      FindMenuDispatch(FindMenuAction.show, seq),
      const FindMenuDispatch(FindMenuAction.show, 1),
    );
    expect(
      FindMenuDispatch(FindMenuAction.show, seq).hashCode,
      const FindMenuDispatch(FindMenuAction.show, 1).hashCode,
    );
    expect(
      FindMenuDispatch(FindMenuAction.show, seq),
      isNot(const FindMenuDispatch(FindMenuAction.show, 2)),
    );
    expect(
      FindMenuDispatch(FindMenuAction.show, seq),
      isNot(const FindMenuDispatch(FindMenuAction.next, 1)),
    );
  });
}
