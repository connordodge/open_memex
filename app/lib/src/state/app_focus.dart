import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app window is focused (WI #79, D15), over
/// `AppLifecycleListener`: true on `AppLifecycleState.resumed`, false on
/// `AppLifecycleState.inactive` (and on every other non-resumed state, so
/// `hidden` stays false). Before any lifecycle state is known the window
/// counts as focused. The revision poller reads it to pick its interval; #97
/// reuses it for probes.
final appFocusProvider = NotifierProvider<AppFocus, bool>(AppFocus.new);

/// The app-focus seam. Tests override [appFocusProvider] with a subclass
/// that attaches no lifecycle listener.
class AppFocus extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(
      onStateChange: (s) => state = s == AppLifecycleState.resumed,
    );
    ref.onDispose(listener.dispose);
    final current = WidgetsBinding.instance.lifecycleState;
    return current == null || current == AppLifecycleState.resumed;
  }
}
