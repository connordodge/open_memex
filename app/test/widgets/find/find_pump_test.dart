// WI #80 (Spec #61 F1): the shared Find in note pump (test/support/
// find_pump.dart) that F2, F3 and F6 build on.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';

import '../../support/find_pump.dart';
import '../../support/font_fetch_hold.dart';

const _childKey = Key('find-pump-probe');

/// Shows the seeded state as text, so the test reads what a widget sees.
class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(findInNoteProvider);
    return SizedBox.expand(
      key: _childKey,
      child: Text('${s.query}:${s.matches.length}:${s.current}'),
    );
  }
}

final List<FindSource> _sources = [
  const FindSource(
    segment: 0,
    kind: FindSourceKind.body,
    text: 'bread one bread',
  ),
  const FindSource(segment: 2, kind: FindSourceKind.card, text: 'rye bread'),
];

void main() {
  holdFontFetches();

  testWidgets(
    'find_pump pumps a child under a seeded findInNoteProvider at a given body width and its doc names holdFontFetches',
    (tester) async {
      final h = await pumpFind(
        tester,
        child: const _Probe(),
        sources: _sources,
        query: 'bread',
        current: 1,
        bodyWidth: 264,
      );

      expect(tester.getSize(find.byKey(findPumpHostKey)), const Size(264, 400));
      expect(tester.getSize(find.byKey(_childKey)).width, 264);

      expect(h.state.open, isTrue);
      expect(h.state.query, 'bread');
      expect(h.state.lastQuery, 'bread');
      expect(h.state.sources, _sources);
      expect(h.state.matches, hasLength(3));
      expect(h.state.current, 1);
      expect(find.text('bread:3:1'), findsOneWidget);

      // The seeded notifier is the real one: its commands act on the seed.
      expect(h.notifier.next(), h.state.matches[2]);
      await tester.pump();
      expect(find.text('bread:3:2'), findsOneWidget);

      // The dispatch helper feeds findMenuActionsProvider.
      expect(h.lastMenuDispatch, isNull);
      await h.dispatch(FindMenuAction.show);
      await h.dispatch(FindMenuAction.show);
      expect(
        h.lastMenuDispatch,
        const FindMenuDispatch(FindMenuAction.show, 2),
      );

      final doc = File('test/support/find_pump.dart').readAsStringSync();
      expect(doc, contains('holdFontFetches()'));
    },
  );

  testWidgets('find_pump takes the current match from the caret by default', (
    tester,
  ) async {
    final h = await pumpFind(
      tester,
      child: const _Probe(),
      sources: _sources,
      query: 'bread',
      caret: const FindCaret(0, 1),
    );
    expect(
      tester.getSize(find.byKey(findPumpHostKey)).width,
      findPumpBodyWidth,
    );
    expect(h.state.caret, const FindCaret(0, 1));
    expect(h.state.current, 1);
  });

  testWidgets('find_pump seeds a closed state with no matches', (tester) async {
    final h = await pumpFind(
      tester,
      child: const _Probe(),
      sources: _sources,
      query: '',
      lastQuery: 'bread',
      open: false,
    );
    expect(h.state.open, isFalse);
    expect(h.state.matches, isEmpty);
    expect(h.state.current, isNull);
    expect(h.state.lastQuery, 'bread');

    h.notifier.show();
    await tester.pump();
    expect(h.state.open, isTrue);
    expect(h.state.matches, hasLength(3));
    expect(h.state.focusRequest, 1);
  });
}
