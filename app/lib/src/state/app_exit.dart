import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's window method channel (macOS `MainFlutterWindow.swift`).
///
/// - native → Dart `windowShouldClose` (no arguments): the window delegate
///   asks before the window closes; Dart replies a bool, true to close.
/// - Dart → native `setTitle` (argument: the title `String`): sets the
///   native window title.
const appWindowChannel = MethodChannel('open_memex/window');

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

  @override
  void attach({
    required WindowCloseHandler onWindowClose,
    required QuitHandler onQuit,
  }) {
    appWindowChannel.setMethodCallHandler((call) async {
      if (call.method == 'windowShouldClose') return onWindowClose();
      throw MissingPluginException('open_memex/window: ${call.method}');
    });
    _listener = AppLifecycleListener(onExitRequested: onQuit);
  }

  @override
  void detach() {
    appWindowChannel.setMethodCallHandler(null);
    _listener?.dispose();
    _listener = null;
  }
}

/// The app-exit seam the app root attaches to.
final appExitHostProvider = Provider<AppExitHost>((_) => PlatformAppExitHost());

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
