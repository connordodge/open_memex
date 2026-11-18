// WI #81 (Spec #61 F5; Reqs 11, 17; TD6; D13): Edit ▸ Find enablement.
//
// `findMenuEnablementProvider` (attached once from main.dart) sends
// `setFindMenuEnabled` through `windowMenuHostProvider`: true exactly when a
// note editor is showing (a vault is open and the active tab is a NoteTab,
// or a CanvasTab zoomed into a note) and no modal route is over the
// workspace, false otherwise, and only when that value changes. Modal routes
// are tracked by the observer `findMenuModalObserverProvider` gives the app's
// `navigatorObservers`; the Command palette (#59) is a root-navigator dialog
// (D13). A native error is logged and swallowed, as in
// agents_menu_enablement.dart.
//
// The tabs are a real TabsNotifier over an in-memory UiStateStore, driven
// through its public commands.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart' show appNavigatorKeyProvider;
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/find_menu_enablement.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/app_harness.dart';
import '../support/font_fetch_hold.dart';
import '../support/window_menu_fakes.dart';

/// A UiStateStore that never touches disk.
class _Wi81MemoryStore extends UiStateStore {
  _Wi81MemoryStore() : super(vaultPath: '/nonexistent/find-menu-enablement');

  UiState _last = UiState(
    tabs: const [],
    activeTabIndex: 0,
    canvasViewports: const {},
  );

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

/// Note ids built at run time, so the tab constructors run.
String _wi81Id(String name) => 'note-81-$name';

NoteTab _wi81Note(String name) => NoteTab(_wi81Id(name));

CanvasTab _wi81Canvas({String? zoomedInto}) => CanvasTab(
  'board-81',
  zoomedNoteId: zoomedInto == null ? null : _wi81Id(zoomedInto),
);

GraphTab _wi81Graph() => GraphTab(GraphScope.topic(_wi81Id('topic')));

/// A container with a [FakeWindowMenuHost], real in-memory tabs, and a vault
/// open unless [vault] is false. The enablement is not read yet.
class _Wi81Rig {
  _Wi81Rig({List<Override> overrides = const []}) {
    container = ProviderContainer(
      overrides: [
        windowMenuHostProvider.overrideWithValue(menu),
        tabsProvider.overrideWith(
          (ref) => TabsNotifier(
            store: _Wi81MemoryStore(),
            onPersistedSelection: (_) {},
          ),
        ),
        ...overrides,
      ],
    );
    addTearDown(container.dispose);
  }

  final menu = FakeWindowMenuHost();
  late final ProviderContainer container;

  TabsNotifier get tabs => container.read(tabsProvider.notifier);

  void openVault() => container.read(currentVaultProvider.notifier).state =
      LocalVaultRef('/vaults/My Vault 81');

  void closeVault() =>
      container.read(currentVaultProvider.notifier).state = null;

  void attach() => container.read(findMenuEnablementProvider);

  NavigatorObserver get observer =>
      container.read(findMenuModalObserverProvider);
}

/// A rig with a vault open and the enablement attached. The fake host
/// records each send as it is made, so nothing needs pumping here.
_Wi81Rig _wi81Attached() {
  final r = _Wi81Rig()..openVault();
  r.attach();
  return r;
}

/// One frame plus a moment of fake time: Riverpod can flush provider
/// listeners on a zero-length timer, which a bare `pump()` never elapses.
Future<void> _wi81Flush(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 1));

/// Pumps an app whose root navigator carries the rig's observer, over the
/// rig's container.
Future<GlobalKey<NavigatorState>> _wi81PumpNavigator(
  WidgetTester tester,
  _Wi81Rig r,
) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: r.container,
      child: MaterialApp(
        navigatorKey: key,
        navigatorObservers: [r.observer],
        home: const SizedBox(key: Key('workspace-81')),
      ),
    ),
  );
  return key;
}

void main() {
  holdFontFetches();

  group('a note editor is showing (AC enablement true)', () {
    test(
      'with no vault open the enablement sends setFindMenuEnabled false once when attached',
      () async {
        final r = _Wi81Rig();
        expect(r.menu.findEnabledCalls, isEmpty);
        r.attach();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false]);
        expect(
          r.menu.enabledCalls,
          isEmpty,
          reason: 'the Agents item is not touched',
        );
      },
    );

    test('a NoteTab with a vault open sends setFindMenuEnabled true', () async {
      final r = _wi81Attached();
      expect(r.menu.findEnabledCalls, [false], reason: 'no tab yet');

      r.tabs.openOrFocus(_wi81Note('alpha'));
      await pumpEventQueue();
      expect(r.menu.findEnabledCalls, [false, true]);
      expect(r.menu.findEnabled, isTrue);
    });

    test(
      'attached with a NoteTab already active the enablement sends true and no false',
      () async {
        final r = _Wi81Rig()..openVault();
        r.tabs.openOrFocus(_wi81Note('alpha'));
        r.attach();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [true]);
      },
    );

    test(
      'a CanvasTab zoomed into a note sends true and zooming out sends false',
      () async {
        final r = _wi81Attached();
        r.tabs.openOrFocus(_wi81Canvas());
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false], reason: 'unzoomed: no change');

        r.tabs.navigate(_wi81Canvas(zoomedInto: 'alpha'));
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true]);

        r.tabs.navigate(_wi81Canvas());
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true, false]);
      },
    );

    test('the virtual Today note counts as a NoteTab and sends true', () async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(VirtualTodayTab('2026-11-${17 + 1}'));
      await pumpEventQueue();
      expect(r.menu.findEnabledCalls, [false, true]);
    });
  });

  group('no note editor is showing (AC enablement false)', () {
    test('a GraphTab after a NoteTab sends false', () async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(_wi81Note('alpha'));
      await pumpEventQueue();
      r.tabs.openOrFocus(_wi81Graph());
      await pumpEventQueue();
      expect(r.menu.findEnabledCalls, [false, true, false]);

      // Back on the note tab: true again.
      r.tabs.setActive(0);
      await pumpEventQueue();
      expect(r.menu.findEnabledCalls, [false, true, false, true]);
    });

    test('an unzoomed CanvasTab after a NoteTab sends false', () async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(_wi81Note('alpha'));
      await pumpEventQueue();
      r.tabs.openOrFocus(_wi81Canvas());
      await pumpEventQueue();
      expect(r.menu.findEnabledCalls, [false, true, false]);
    });

    test('closing the last tab leaves no active tab and sends false', () async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(_wi81Note('alpha'));
      await pumpEventQueue();
      r.tabs.closeAt(0);
      await pumpEventQueue();
      expect(r.container.read(tabsProvider).activeTab, isNull);
      expect(r.menu.findEnabledCalls, [false, true, false]);
    });

    test(
      'with no vault open a NoteTab sends false and opening then closing the vault sends true then false',
      () async {
        final r = _Wi81Rig();
        r.tabs.openOrFocus(_wi81Note('alpha'));
        r.attach();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [
          false,
        ], reason: 'a note tab with no vault open is not an editor showing');

        r.openVault();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true]);

        r.closeVault();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true, false]);
      },
    );
  });

  group('only on a change (AC enablement dedupe)', () {
    test('two note tabs in a row send one true', () async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(_wi81Note('alpha'));
      await pumpEventQueue();
      r.tabs.openOrFocus(_wi81Note('bravo'));
      await pumpEventQueue();
      r.tabs.navigate(_wi81Note('charlie'));
      await pumpEventQueue();
      r.tabs.setActive(0);
      await pumpEventQueue();
      expect(r.menu.findEnabledCalls, [false, true]);
    });

    test(
      'a note tab then a zoomed canvas tab send one true and a graph then an unzoomed canvas send one false',
      () async {
        final r = _wi81Attached();
        r.tabs.openOrFocus(_wi81Note('alpha'));
        await pumpEventQueue();
        r.tabs.openOrFocus(_wi81Canvas(zoomedInto: 'bravo'));
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true]);

        r.tabs.openOrFocus(_wi81Graph());
        await pumpEventQueue();
        r.tabs.openOrFocus(CanvasTab('other-81'));
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true, false]);
      },
    );

    test(
      'reading the enablement again sends no second setFindMenuEnabled',
      () async {
        final r = _wi81Attached();
        r.attach();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false]);
        r.tabs.openOrFocus(_wi81Note('alpha'));
        await pumpEventQueue();
        r.attach();
        await pumpEventQueue();
        expect(r.menu.findEnabledCalls, [false, true]);
      },
    );
  });

  group('modal routes (AC enablement modal)', () {
    testWidgets(
      'a modal route pushed over the workspace sends false and popping it sends true again',
      (tester) async {
        final r = _wi81Attached();
        r.tabs.openOrFocus(_wi81Note('alpha'));
        final nav = await _wi81PumpNavigator(tester, r);
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false, true]);

        showDialog<void>(
          context: nav.currentContext!,
          builder: (_) => const SizedBox(key: Key('dialog-81')),
        );
        await _wi81Flush(tester);
        expect(find.byKey(const Key('dialog-81')), findsOneWidget);
        expect(r.menu.findEnabledCalls, [false, true, false]);

        nav.currentState!.pop();
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false, true, false, true]);
      },
    );

    testWidgets(
      'a general dialog over the workspace disables Find and popping it enables it again',
      (tester) async {
        // The Command palette (#59) is a root-navigator dialog (D13).
        final r = _wi81Attached();
        r.tabs.openOrFocus(_wi81Note('alpha'));
        final nav = await _wi81PumpNavigator(tester, r);
        await _wi81Flush(tester);

        showGeneralDialog<void>(
          context: nav.currentContext!,
          pageBuilder: (_, _, _) => const SizedBox(key: Key('palette-81')),
        );
        await _wi81Flush(tester);
        expect(r.menu.findEnabled, isFalse);

        nav.currentState!.pop();
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false, true, false, true]);
      },
    );

    testWidgets('two stacked dialogs keep Find disabled until both pop', (
      tester,
    ) async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(_wi81Note('alpha'));
      final nav = await _wi81PumpNavigator(tester, r);
      await _wi81Flush(tester);

      showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const SizedBox(key: Key('first-81')),
      );
      await _wi81Flush(tester);
      showDialog<void>(
        context: nav.currentContext!,
        builder: (_) => const SizedBox(key: Key('second-81')),
      );
      await _wi81Flush(tester);
      expect(r.menu.findEnabledCalls, [false, true, false]);

      nav.currentState!.pop();
      await _wi81Flush(tester);
      expect(find.byKey(const Key('first-81')), findsOneWidget);
      expect(r.menu.findEnabledCalls, [
        false,
        true,
        false,
      ], reason: 'one dialog still shows');

      nav.currentState!.pop();
      await _wi81Flush(tester);
      expect(r.menu.findEnabledCalls, [false, true, false, true]);
    });

    testWidgets('a dialog removed without a pop enables Find again', (
      tester,
    ) async {
      final r = _wi81Attached();
      r.tabs.openOrFocus(_wi81Note('alpha'));
      final nav = await _wi81PumpNavigator(tester, r);
      await _wi81Flush(tester);

      final route = DialogRoute<void>(
        context: nav.currentContext!,
        builder: (_) => const SizedBox(key: Key('removed-81')),
      );
      nav.currentState!.push(route);
      await _wi81Flush(tester);
      expect(r.menu.findEnabled, isFalse);

      nav.currentState!.removeRoute(route);
      await _wi81Flush(tester);
      expect(r.menu.findEnabledCalls, [false, true, false, true]);
    });

    testWidgets(
      'a dialog replaced by another dialog keeps Find disabled until the second pops',
      (tester) async {
        final r = _wi81Attached();
        r.tabs.openOrFocus(_wi81Note('alpha'));
        final nav = await _wi81PumpNavigator(tester, r);
        await _wi81Flush(tester);

        final first = DialogRoute<void>(
          context: nav.currentContext!,
          builder: (_) => const SizedBox(key: Key('first-81')),
        );
        nav.currentState!.push(first);
        await _wi81Flush(tester);
        nav.currentState!.replace(
          oldRoute: first,
          newRoute: DialogRoute<void>(
            context: nav.currentContext!,
            builder: (_) => const SizedBox(key: Key('second-81')),
          ),
        );
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false, true, false]);

        nav.currentState!.pop();
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false, true, false, true]);
      },
    );

    testWidgets(
      'a modal route over a graph tab sends nothing and a note tab under it stays disabled until it pops',
      (tester) async {
        final r = _wi81Attached();
        r.tabs.openOrFocus(_wi81Graph());
        final nav = await _wi81PumpNavigator(tester, r);
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false]);

        showDialog<void>(
          context: nav.currentContext!,
          builder: (_) => const SizedBox(key: Key('dialog-81')),
        );
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false], reason: 'already false');

        // A note tab becomes active while the dialog shows: still no editor
        // can take Find.
        r.tabs.openOrFocus(_wi81Note('alpha'));
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false]);

        nav.currentState!.pop();
        await _wi81Flush(tester);
        expect(r.menu.findEnabledCalls, [false, true]);
      },
    );

    testWidgets(
      'in the running app a dialog over the workspace disables Find and closing it enables Find again',
      (tester) async {
        final menu = FakeWindowMenuHost();
        final app = await pumpWorkspace(
          tester,
          overrides: [windowMenuHostProvider.overrideWithValue(menu)],
        );
        expect(app.read(activeTabProvider), isA<NoteTab>());
        expect(
          menu.findEnabled,
          isTrue,
          reason: 'the launch lands on a note: ${menu.findEnabledCalls}',
        );
        final before = menu.findEnabledCalls.length;

        final nav = app.read(appNavigatorKeyProvider);
        showDialog<void>(
          context: nav.currentContext!,
          builder: (_) => const SizedBox(key: Key('dialog-81')),
        );
        await pumpFrames(tester);
        expect(menu.findEnabledCalls.skip(before), [false]);

        nav.currentState!.pop();
        await pumpFrames(tester);
        expect(menu.findEnabledCalls.skip(before), [false, true]);
      },
    );
  });

  group('native error (AC enablement error)', () {
    testWidgets(
      'a native error on setFindMenuEnabled raises no uncaught error and later changes still send',
      (tester) async {
        // The real PlatformWindowMenuHost passes a native PlatformException
        // on; the enablement sends from a listener, so an escaping error
        // would reach the test zone and fail this test.
        final sent = <Object?>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(appWindowChannel, (call) async {
          if (call.method == 'setFindMenuEnabled') sent.add(call.arguments);
          throw PlatformException(code: 'bad_arguments', message: 'nope');
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(appWindowChannel, null),
        );

        final c = ProviderContainer(
          overrides: [
            tabsProvider.overrideWith(
              (ref) => TabsNotifier(
                store: _Wi81MemoryStore(),
                onPersistedSelection: (_) {},
              ),
            ),
          ],
        );
        addTearDown(c.dispose);
        c.read(currentVaultProvider.notifier).state = LocalVaultRef(
          '/vaults/My Vault 81',
        );
        c.read(findMenuEnablementProvider);
        await _wi81Flush(tester);
        c.read(tabsProvider.notifier).openOrFocus(_wi81Note('alpha'));
        await _wi81Flush(tester);
        c.read(tabsProvider.notifier).openOrFocus(_wi81Graph());
        await _wi81Flush(tester);
        c.read(tabsProvider.notifier).setActive(0);
        await _wi81Flush(tester);

        expect(sent, [false, true, false, true]);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a native error on setFindMenuEnabled is logged once per failed call with the value sent',
      (tester) async {
        final logs = <String>[];
        final oldDebugPrint = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) =>
            logs.add(message ?? '');
        // Restored in the body: the framework's invariant check runs before
        // addTearDown callbacks.
        void restore() => debugPrint = oldDebugPrint;

        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(appWindowChannel, (call) async {
          throw PlatformException(code: 'menu_failed', message: 'nope');
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(appWindowChannel, null),
        );

        final c = ProviderContainer(
          overrides: [
            tabsProvider.overrideWith(
              (ref) => TabsNotifier(
                store: _Wi81MemoryStore(),
                onPersistedSelection: (_) {},
              ),
            ),
          ],
        );
        addTearDown(c.dispose);
        c.read(currentVaultProvider.notifier).state = LocalVaultRef(
          '/vaults/My Vault 81',
        );
        c.read(findMenuEnablementProvider);
        await _wi81Flush(tester);
        final findLogs = logs.where((l) => l.contains('setFindMenuEnabled'));
        expect(findLogs, hasLength(1));
        expect(findLogs.single, contains('setFindMenuEnabled(false)'));
        expect(findLogs.single, contains('menu_failed'));

        c.read(tabsProvider.notifier).openOrFocus(_wi81Note('alpha'));
        await _wi81Flush(tester);
        final after = logs.where((l) => l.contains('setFindMenuEnabled'));
        expect(after, hasLength(2));
        expect(after.last, contains('setFindMenuEnabled(true)'));
        restore();
        expect(tester.takeException(), isNull);
      },
    );
  });
}
