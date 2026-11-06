// WI #263 (N0): the navigation seam on TabsNotifier: follow, navigate and
// followLater. #266 (N3) made navigate real: it replaces what the active tab
// shows (flipped from the N0 stub, where it matched openOrFocus). The rest of
// navigate's contract is in tabs_navigate_test.dart.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

import '../support/recording_tabs.dart';

const _a = NoteTab('a');
const _b = NoteTab('b');
const _target = NoteTab('target');
const _canvas = CanvasTab('c1');

/// A UiStateStore that never touches disk.
class _MemoryStore extends UiStateStore {
  _MemoryStore() : super(vaultPath: '/nonexistent/tabs-follow-seam');

  UiState _last = UiState.empty();

  @override
  UiState read() => _last;

  @override
  Future<void> write(UiState state) {
    _last = state;
    return Future<void>.value();
  }

  @override
  Future<void> flush() => Future<void>.value();
}

/// A real notifier that also counts the calls reaching the two paths `follow`
/// chooses between.
class _CountingTabs extends TabsNotifier {
  _CountingTabs({
    super.isNewTabModifierPressed,
    super.navigationObserver,
    void Function(String? activeNoteId)? onSelection,
  }) : super(
         store: _MemoryStore(),
         onPersistedSelection: onSelection ?? (_) {},
       );

  final opened = <WorkspaceTab>[];
  final navigatedTo = <WorkspaceTab>[];

  @override
  int openOrFocus(WorkspaceTab tab) {
    opened.add(tab);
    return super.openOrFocus(tab);
  }

  @override
  void navigate(WorkspaceTab target) {
    navigatedTo.add(target);
    super.navigate(target);
  }
}

_CountingTabs _tabs({
  bool Function()? modifier,
  TabsNavigationObserver? observer,
  void Function(String? activeNoteId)? onSelection,
}) {
  final tabs = _CountingTabs(
    isNewTabModifierPressed: modifier,
    navigationObserver: observer,
    onSelection: onSelection,
  );
  addTearDown(() {
    if (tabs.mounted) tabs.dispose();
  });
  return tabs;
}

/// Runs [body] with the Cmd key [key] held, releasing it even when [body]
/// throws so a failure can't leak a pressed key into the next test.
Future<void> _holding(
  WidgetTester tester,
  LogicalKeyboardKey key,
  void Function() body,
) async {
  await tester.sendKeyDownEvent(key, platform: 'macos');
  try {
    body();
  } finally {
    await tester.sendKeyUpEvent(key, platform: 'macos');
  }
}

void main() {
  group('follow', () {
    test(
      'follow with the modifier returning false reaches navigate exactly once',
      () {
        final recorder = TabsRecorder();
        final tabs = _tabs(modifier: () => false, observer: recorder.observer);

        tabs.follow(_target);

        expect(tabs.navigatedTo, [_target]);
        expect(recorder.followed, [_target]);
        expect(recorder.navigated, [_target]);
        expect(tabs.state.activeTab, _target);
      },
    );

    test(
      'follow with the modifier returning true reaches openOrFocus exactly once and never navigate',
      () {
        final recorder = TabsRecorder();
        final tabs = _tabs(modifier: () => true, observer: recorder.observer);

        tabs.follow(_target);

        expect(tabs.opened, [_target]);
        expect(tabs.navigatedTo, isEmpty);
        expect(recorder.followed, [_target]);
        expect(recorder.navigated, isEmpty);
        expect(tabs.state.activeTab, _target);
      },
    );

    test('follow without an observer still shows the target on both paths', () {
      final plain = _tabs(modifier: () => false);
      final held = _tabs(modifier: () => true);

      plain.follow(_target);
      held.follow(_canvas);

      expect(plain.state.activeTab, _target);
      expect(held.state.activeTab, _canvas);
    });

    test('follow with the modifier returning true focuses an open target', () {
      final tabs = _tabs(modifier: () => true);
      tabs.openOrFocus(_a);
      tabs.openOrFocus(_b);
      tabs.opened.clear();

      tabs.follow(_a);

      expect(tabs.opened, [_a]);
      expect(tabs.state.tabs, [_a, _b]);
      expect(tabs.state.activeIndex, 0);
    });
  });

  group('the default modifier', () {
    testWidgets(
      'follow with no injected modifier treats a held metaLeft as the modifier',
      (tester) async {
        final tabs = _tabs();

        await _holding(
          tester,
          LogicalKeyboardKey.metaLeft,
          () => tabs.follow(_target),
        );

        expect(tabs.opened, [_target]);
        expect(tabs.navigatedTo, isEmpty);
      },
    );

    testWidgets(
      'follow with no injected modifier treats a released metaLeft as no modifier',
      (tester) async {
        final tabs = _tabs();
        await _holding(tester, LogicalKeyboardKey.metaLeft, () {});

        tabs.follow(_target);

        expect(tabs.navigatedTo, [_target]);
      },
    );

    testWidgets(
      'follow with no injected modifier treats a held metaRight as the modifier',
      (tester) async {
        final tabs = _tabs();

        await _holding(
          tester,
          LogicalKeyboardKey.metaRight,
          () => tabs.follow(_target),
        );

        expect(tabs.opened, [_target]);
        expect(tabs.navigatedTo, isEmpty);
      },
    );

    testWidgets('an injected modifier wins over a held metaLeft', (
      tester,
    ) async {
      final tabs = _tabs(modifier: () => false);

      await _holding(
        tester,
        LogicalKeyboardKey.metaLeft,
        () => tabs.follow(_target),
      );

      expect(tabs.navigatedTo, [_target]);
    });
  });

  group('navigate', () {
    /// A notifier with tabs a and b open and b active.
    _CountingTabs twoOpen({void Function(String?)? onSelection}) {
      final tabs = _tabs(onSelection: onSelection);
      tabs.openOrFocus(_a);
      tabs.openOrFocus(_b);
      return tabs;
    }

    test(
      'navigate replaces what the active tab shows for a target another tab shows',
      () {
        final selections = <String?>[];
        final navigated = twoOpen(onSelection: selections.add);

        navigated.navigate(_a);

        expect(navigated.opened, [_a, _b], reason: 'only the setup opened');
        expect(navigated.state.tabs, [_a, _a]);
        expect(navigated.state.activeIndex, 1);
        expect(selections.last, 'a');
      },
    );

    test(
      'navigate replaces what the active tab shows for a target no tab shows',
      () {
        final selections = <String?>[];
        final navigated = twoOpen(onSelection: selections.add);

        navigated.navigate(_target);

        expect(navigated.opened, [_a, _b], reason: 'only the setup opened');
        expect(navigated.state.tabs, [_a, _target]);
        expect(navigated.state.activeIndex, 1);
        expect(selections.last, 'target');
      },
    );

    test('navigate tells the observer and not followed', () {
      final recorder = TabsRecorder();
      final tabs = _tabs(observer: recorder.observer);

      tabs.navigate(_target);

      expect(recorder.navigated, [_target]);
      expect(recorder.followed, isEmpty);
    });

    test('navigate without an observer still shows the target', () {
      final tabs = _tabs();

      tabs.navigate(_target);

      expect(tabs.state.activeTab, _target);
    });
  });

  group('followLater', () {
    test(
      'followLater keeps a released modifier when it is pressed before the function runs',
      () {
        var pressed = false;
        final recorder = TabsRecorder();
        final tabs = _tabs(
          modifier: () => pressed,
          observer: recorder.observer,
        );

        final later = tabs.followLater();
        pressed = true;
        later(_target);

        expect(tabs.navigatedTo, [_target]);
        expect(recorder.followed, [_target]);
        expect(recorder.navigated, [_target]);
      },
    );

    test(
      'followLater keeps a held modifier when it is released before the function runs',
      () {
        var pressed = true;
        final recorder = TabsRecorder();
        final tabs = _tabs(
          modifier: () => pressed,
          observer: recorder.observer,
        );

        final later = tabs.followLater();
        pressed = false;
        later(_target);

        expect(tabs.opened, [_target]);
        expect(tabs.navigatedTo, isEmpty);
        expect(recorder.followed, [_target]);
        expect(recorder.navigated, isEmpty);
      },
    );

    testWidgets(
      'followLater keeps a released metaLeft when it is pressed before the function runs',
      (tester) async {
        final tabs = _tabs();

        final later = tabs.followLater();
        await _holding(
          tester,
          LogicalKeyboardKey.metaLeft,
          () => later(_target),
        );

        expect(tabs.navigatedTo, [_target]);
      },
    );

    testWidgets(
      'followLater keeps a held metaLeft when it is released before the function runs',
      (tester) async {
        final tabs = _tabs();
        late void Function(WorkspaceTab) later;

        await _holding(
          tester,
          LogicalKeyboardKey.metaLeft,
          () => later = tabs.followLater(),
        );
        later(_target);

        expect(tabs.opened, [_target]);
        expect(tabs.navigatedTo, isEmpty);
      },
    );

    test(
      'followLater without an observer still shows the target on both paths',
      () {
        final plain = _tabs(modifier: () => false);
        final held = _tabs(modifier: () => true);

        plain.followLater()(_target);
        held.followLater()(_canvas);

        expect(plain.state.activeTab, _target);
        expect(held.state.activeTab, _canvas);
      },
    );

    test(
      'a followLater function taken with the modifier released does nothing once the notifier is disposed',
      () {
        final recorder = TabsRecorder();
        final tabs = _tabs(modifier: () => false, observer: recorder.observer);
        // A live function does reach the seam, so the silence below is the
        // disposal's doing.
        tabs.followLater()(_a);
        final stale = tabs.followLater();

        tabs.dispose();
        stale(_target);

        expect(tabs.navigatedTo, [_a]);
        expect(tabs.opened, isNot(contains(_target)));
        expect(recorder.followed, [_a]);
        expect(recorder.navigated, [_a]);
      },
    );

    test(
      'a followLater function taken with the modifier held does nothing once the notifier is disposed',
      () {
        final recorder = TabsRecorder();
        final tabs = _tabs(modifier: () => true, observer: recorder.observer);
        tabs.followLater()(_a);
        final stale = tabs.followLater();

        tabs.dispose();
        stale(_target);

        expect(tabs.opened, [_a]);
        expect(tabs.navigatedTo, isEmpty);
        expect(recorder.followed, [_a]);
        expect(recorder.navigated, isEmpty);
      },
    );
  });

  group('TabsRecorder over tabsProvider', () {
    ({TabsRecorder recorder, ProviderContainer container}) recorded() {
      final recorder = TabsRecorder();
      final container = ProviderContainer(
        overrides: [
          recorder.override,
          uiStateStoreProvider.overrideWithValue(_MemoryStore()),
        ],
      );
      addTearDown(container.dispose);
      return (recorder: recorder, container: container);
    }

    testWidgets(
      'TabsRecorder records a followLater result in followed and tab state still changes',
      (tester) async {
        final (:recorder, :container) = recorded();

        container.read(tabsProvider.notifier).followLater()(_target);

        expect(recorder.followed, [_target]);
        expect(container.read(tabsProvider).activeTab, _target);
      },
    );

    testWidgets(
      'TabsRecorder records a plain follow in followed and navigated and tab state still changes',
      (tester) async {
        final (:recorder, :container) = recorded();

        container.read(tabsProvider.notifier).follow(_target);

        expect(recorder.followed, [_target]);
        expect(recorder.navigated, [_target]);
        expect(container.read(tabsProvider).activeTab, _target);
      },
    );

    testWidgets(
      'TabsRecorder records a Cmd follow in followed only and tab state still changes',
      (tester) async {
        final (:recorder, :container) = recorded();

        await _holding(
          tester,
          LogicalKeyboardKey.metaLeft,
          () => container.read(tabsProvider.notifier).follow(_target),
        );

        expect(recorder.followed, [_target]);
        expect(recorder.navigated, isEmpty);
        expect(container.read(tabsProvider).activeTab, _target);
      },
    );

    testWidgets(
      'TabsRecorder records a direct navigate in navigated only and tab state still changes',
      (tester) async {
        final (:recorder, :container) = recorded();

        container.read(tabsProvider.notifier).navigate(_target);

        expect(recorder.navigated, [_target]);
        expect(recorder.followed, isEmpty);
        expect(container.read(tabsProvider).activeTab, _target);
      },
    );
  });

  test(
    'GLOSSARY.md has one Navigation section defining Navigate and Tab history',
    () {
      final glossary = File('../GLOSSARY.md').readAsStringSync();

      expect('## Navigation (#230)'.allMatches(glossary), hasLength(1));
      expect(glossary, contains('**Navigate**:'));
      expect(glossary, contains('**Tab history**:'));
    },
  );
}
