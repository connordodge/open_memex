// WI #81 (Spec #61 F5; Reqs 11, 17; D13): Edit ▸ Find enablement and the
// native `find` route into `findMenuActionsProvider`.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_exit.dart';
import 'find_in_note_state.dart';
import 'tabs_state.dart';
import 'vault_state.dart';

/// Tracks the modal routes ([PopupRoute]s: dialogs, the Command palette,
/// popup menus) on the navigator it observes. [modalShowing] is true while
/// at least one is there.
class FindMenuModalObserver extends NavigatorObserver {
  int _modals = 0;
  final ValueNotifier<bool> _showing = ValueNotifier(false);

  /// Whether a modal route is over the workspace; notifies only on a change.
  ValueListenable<bool> get modalShowing => _showing;

  static int _weight(Route<dynamic>? route) => route is PopupRoute ? 1 : 0;

  /// Applies one navigator change in a single step, so a replace of one
  /// modal by another never reads as "no modal" in between.
  void _change(int delta) {
    _modals += delta;
    _showing.value = _modals > 0;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(_weight(route));

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(-_weight(route));

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(-_weight(route));

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _change(_weight(newRoute) - _weight(oldRoute));

  void _dispose() => _showing.dispose();
}

/// The observer the app root adds to its `navigatorObservers`: it tracks the
/// modal (popup and dialog) routes over the workspace, so Find is disabled
/// while one shows (D13).
final findMenuModalObserverProvider = Provider<FindMenuModalObserver>((ref) {
  final observer = FindMenuModalObserver();
  ref.onDispose(observer._dispose);
  return observer;
});

/// Whether a note editor is showing: a vault is open and the active tab is a
/// note (the virtual Today note included) or a canvas zoomed into a note.
final _noteEditorShowingProvider = Provider<bool>((ref) {
  if (ref.watch(currentVaultProvider) == null) return false;
  return switch (ref.watch(activeTabProvider)) {
    NoteTab() => true,
    CanvasTab(:final zoomedNoteId) => zoomedNoteId != null,
    GraphTab() || null => false,
  };
});

/// Attached once for the app's life (one line in main.dart): routes the
/// native `find` method to `findMenuActionsProvider`, and sends
/// `setFindMenuEnabled` through `windowMenuHostProvider` whenever "a note
/// editor is showing and no modal route is over the workspace" changes. It
/// sends its value once when attached (after a hot restart the native items
/// may still be enabled). A native error is logged and swallowed: the items
/// keep their last state and later changes still send.
final findMenuEnablementProvider = Provider<void>((ref) {
  final host = ref.watch(windowMenuHostProvider);
  final modal = ref.watch(findMenuModalObserverProvider).modalShowing;

  void onFind(FindMenuAction action) =>
      ref.read(findMenuActionsProvider.notifier).dispatch(action);
  appWindowRouter.setFindHandler(onFind);
  ref.onDispose(() => appWindowRouter.clearFindHandler(onFind));

  var editorShowing = false;
  bool? sent;
  void update() {
    final enabled = editorShowing && !modal.value;
    if (enabled == sent) return;
    sent = enabled;
    unawaited(_send(host, enabled));
  }

  ref.listen<bool>(_noteEditorShowingProvider, (_, showing) {
    editorShowing = showing;
    update();
  }, fireImmediately: true);
  modal.addListener(update);
  ref.onDispose(() => modal.removeListener(update));
});

Future<void> _send(WindowMenuHost host, bool enabled) async {
  try {
    await host.setFindMenuEnabled(enabled);
  } on PlatformException catch (e) {
    debugPrint('setFindMenuEnabled($enabled) failed: $e');
  }
}
