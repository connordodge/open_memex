import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'find_in_note_state.dart' show FindMenuAction;

/// The app's window method channel (macOS `MainFlutterWindow.swift`).
///
/// - native → Dart `windowShouldClose` (no arguments): the window delegate
///   asks before the window closes; Dart replies a bool, true to close.
/// - Dart → native `setTitle` (argument: the title `String`): sets the
///   native window title.
/// - native → Dart `openAgents` (no arguments): Window ▸ Agents… (or ⇧⌘A)
///   was picked; Dart opens the Agents sheet.
/// - Dart → native `setAgentsMenuEnabled` (argument: a `bool`): enables or
///   greys out Window ▸ Agents….
/// - native → Dart `find` (argument: the action string `show`, `next`,
///   `previous` or `useSelection`): Edit ▸ Find ▸ Find… (⌘F), Find Next
///   (⌘G), Find Previous (⇧⌘G) or Use Selection for Find (⌘E) was picked;
///   Dart performs it. Native never reads the reply.
/// - Dart → native `setFindMenuEnabled` (argument: a `bool`): enables or
///   greys out those four items.
///
/// The channel has one Dart handler, [appWindowRouter] (D18); no host sets
/// its own.
const appWindowChannel = MethodChannel('open_memex/window');

/// The one Dart handler on a window channel (Spec #394 req 7, D18). It
/// dispatches `windowShouldClose` to the [AppExitHost]'s handler,
/// `openAgents` to the [WindowMenuHost]'s callback and `find` to the find
/// handler (Spec #61 F5; a `find` whose argument is no known action string
/// is answered and ignored); any other method, or one whose host is not
/// attached, throws [MissingPluginException] (an empty reply natively). A second `setMethodCallHandler` would replace the first,
/// so the hosts register here instead and attach in either order.
class WindowChannelRouter {
  WindowChannelRouter(this.channel);

  final MethodChannel channel;

  WindowCloseHandler? _onWindowClose;
  VoidCallback? _onOpenAgents;
  FindMenuHandler? _onFind;

  /// The `find` argument (the native wire format) → its action.
  static const _findActions = <String, FindMenuAction>{
    'show': FindMenuAction.show,
    'next': FindMenuAction.next,
    'previous': FindMenuAction.previous,
    'useSelection': FindMenuAction.useSelection,
  };

  /// Routes `windowShouldClose` to [handler].
  void setWindowCloseHandler(WindowCloseHandler handler) {
    _onWindowClose = handler;
    _sync();
  }

  /// Stops routing `windowShouldClose`, unless another handler than
  /// [handler] has been set since.
  void clearWindowCloseHandler(WindowCloseHandler handler) {
    if (!identical(_onWindowClose, handler)) return;
    _onWindowClose = null;
    _sync();
  }

  /// Routes `find` to [handler].
  void setFindHandler(FindMenuHandler handler) {
    _onFind = handler;
    _sync();
  }

  /// Stops routing `find`, unless another handler than [handler] has been
  /// set since.
  void clearFindHandler(FindMenuHandler handler) {
    if (!identical(_onFind, handler)) return;
    _onFind = null;
    _sync();
  }

  /// Routes `openAgents` to [callback].
  void setOpenAgentsHandler(VoidCallback callback) {
    _onOpenAgents = callback;
    _sync();
  }

  /// Stops routing `openAgents`, unless another callback than [callback]
  /// has been set since.
  void clearOpenAgentsHandler(VoidCallback callback) {
    if (!identical(_onOpenAgents, callback)) return;
    _onOpenAgents = null;
    _sync();
  }

  /// One handler while any host is attached; none once all detach.
  void _sync() {
    final idle =
        _onWindowClose == null && _onOpenAgents == null && _onFind == null;
    channel.setMethodCallHandler(idle ? null : _handle);
  }

  Future<Object?> _handle(MethodCall call) async {
    final onWindowClose = _onWindowClose;
    final onOpenAgents = _onOpenAgents;
    final onFind = _onFind;
    if (call.method == 'windowShouldClose' && onWindowClose != null) {
      return onWindowClose();
    }
    if (call.method == 'openAgents' && onOpenAgents != null) {
      onOpenAgents();
      return null;
    }
    if (call.method == 'find' && onFind != null) {
      final action = _findActions[call.arguments];
      if (action != null) onFind(action);
      return null;
    }
    throw MissingPluginException('${channel.name}: ${call.method}');
  }
}

/// The router that owns [appWindowChannel]'s handler.
final appWindowRouter = WindowChannelRouter(appWindowChannel);

/// Performs one native Edit ▸ Find item (`find` on [appWindowChannel]).
typedef FindMenuHandler = void Function(FindMenuAction action);

/// Answers a window-close request: true lets the window close.
typedef WindowCloseHandler = Future<bool> Function();

/// Answers a quit request (⌘Q, the app menu).
typedef QuitHandler = Future<AppExitResponse> Function();

/// The app-exit seam (D20): where window-close and quit requests come from.
/// The app root attaches its handlers once; tests swap in a fake that
/// simulates the requests and records the answers.
abstract interface class AppExitHost {
  /// Routes window-close requests to [onWindowClose] and quit requests to
  /// [onQuit] until [detach].
  void attach({
    required WindowCloseHandler onWindowClose,
    required QuitHandler onQuit,
  });

  /// Stops routing requests to the handlers.
  void detach();
}

/// The real host: window close arrives as `windowShouldClose` on
/// [appWindowChannel]; quit arrives through
/// `AppLifecycleListener.onExitRequested`.
///
/// Native close fallback (MainFlutterWindow.swift): a `true` reply closes
/// the window; `false`, an error or any other reply keeps it open; no Dart
/// handler (not attached yet, or detached) closes it, since nothing is
/// guarding then.
class PlatformAppExitHost implements AppExitHost {
  AppLifecycleListener? _listener;
  WindowCloseHandler? _onWindowClose;

  @override
  void attach({
    required WindowCloseHandler onWindowClose,
    required QuitHandler onQuit,
  }) {
    _onWindowClose = onWindowClose;
    appWindowRouter.setWindowCloseHandler(onWindowClose);
    _listener = AppLifecycleListener(onExitRequested: onQuit);
  }

  @override
  void detach() {
    final onWindowClose = _onWindowClose;
    if (onWindowClose != null) {
      appWindowRouter.clearWindowCloseHandler(onWindowClose);
    }
    _onWindowClose = null;
    _listener?.dispose();
    _listener = null;
  }
}

/// The app-exit seam the app root attaches to.
final appExitHostProvider = Provider<AppExitHost>((_) => PlatformAppExitHost());

/// The Window menu seam (Spec #394 req 4, 5, 7; D18): Window ▸ Agents…
/// arrives as native → Dart `openAgents` on [appWindowChannel]; Dart sends
/// `setAgentsMenuEnabled(bool)` to grey the item out with no vault open.
abstract interface class WindowMenuHost {
  /// Routes `openAgents` to [onOpenAgents] until [detach].
  void attach({required VoidCallback onOpenAgents});

  /// Stops routing `openAgents` to the callback.
  void detach();

  /// Enables or disables Window ▸ Agents… (and with it ⇧⌘A). With no
  /// native handler (widget tests) it does nothing.
  Future<void> setAgentsMenuEnabled(bool enabled);

  /// Enables or disables Edit ▸ Find ▸ Find…, Find Next, Find Previous and
  /// Use Selection for Find. With no native handler (widget tests) it does
  /// nothing.
  Future<void> setFindMenuEnabled(bool enabled);
}

/// The real host: `openAgents` arrives on [appWindowChannel] through the
/// channel's one router ([appWindowRouter]), shared with
/// [PlatformAppExitHost].
class PlatformWindowMenuHost implements WindowMenuHost {
  VoidCallback? _onOpenAgents;

  @override
  void attach({required VoidCallback onOpenAgents}) {
    _onOpenAgents = onOpenAgents;
    appWindowRouter.setOpenAgentsHandler(onOpenAgents);
  }

  @override
  void detach() {
    final onOpenAgents = _onOpenAgents;
    if (onOpenAgents != null) {
      appWindowRouter.clearOpenAgentsHandler(onOpenAgents);
    }
    _onOpenAgents = null;
  }

  /// Sends `setAgentsMenuEnabled` on [appWindowChannel]. Only a missing
  /// native handler is swallowed; a native error is passed on.
  @override
  Future<void> setAgentsMenuEnabled(bool enabled) async {
    try {
      await appWindowChannel.invokeMethod<void>(
        'setAgentsMenuEnabled',
        enabled,
      );
    } on MissingPluginException {
      // No native window (widget tests, other platforms): no menu to grey.
    }
  }

  /// Sends `setFindMenuEnabled` on [appWindowChannel]. Only a missing
  /// native handler is swallowed; a native error is passed on.
  @override
  Future<void> setFindMenuEnabled(bool enabled) async {
    try {
      await appWindowChannel.invokeMethod<void>('setFindMenuEnabled', enabled);
    } on MissingPluginException {
      // No native window (widget tests, other platforms): no menu to grey.
    }
  }
}

/// The Window menu seam the workspace attaches to.
final windowMenuHostProvider = Provider<WindowMenuHost>(
  (_) => PlatformWindowMenuHost(),
);

/// The native window title seam (L21). #96 sets the title through it.
abstract interface class WindowTitle {
  Future<void> setTitle(String title);
}

/// Sends `setTitle` on [appWindowChannel]. With no native handler (widget
/// tests) it does nothing.
class PlatformWindowTitle implements WindowTitle {
  const PlatformWindowTitle();

  @override
  Future<void> setTitle(String title) async {
    try {
      await appWindowChannel.invokeMethod<void>('setTitle', title);
    } on MissingPluginException {
      // No native window (widget tests, other platforms): nothing to title.
    }
  }
}

/// The window title seam.
final windowTitleProvider = Provider<WindowTitle>(
  (_) => const PlatformWindowTitle(),
);

/// Whether the app's exit is already confirmed (D3): a relaunch marks it
/// after its own quit guard, so the app root's quit handler lets the exit
/// through without asking again (req 23).
class ExitConfirmation {
  bool _confirmed = false;

  /// Whether [confirm] was called.
  bool get confirmed => _confirmed;

  /// Marks the exit as confirmed.
  void confirm() => _confirmed = true;
}

/// The app's [ExitConfirmation] (one per provider container).
final appExitConfirmationProvider = Provider<ExitConfirmation>(
  (_) => ExitConfirmation(),
);

/// Exits the process the way the platform does (D3).
typedef AppProcessExit = Future<AppExitResponse> Function(AppExitType type);

/// The process-exit seam. The default is
/// `ServicesBinding.instance.exitApplication(type)`; tests override it.
final appProcessExitProvider = Provider<AppProcessExit>(
  (_) =>
      (type) => ServicesBinding.instance.exitApplication(type),
);
