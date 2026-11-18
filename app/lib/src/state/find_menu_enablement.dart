// WI #81 (Spec #61 F5; Reqs 11, 17; D13): Edit ▸ Find enablement and the
// native `find` route into `findMenuActionsProvider`.
import 'package:flutter/widgets.dart' show NavigatorObserver;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The observer the app root adds to its `navigatorObservers`: it tracks the
/// modal (popup and dialog) routes over the workspace, so Find is disabled
/// while one shows (D13).
///
/// WI #81 skeleton: a plain observer, tracking nothing yet.
final findMenuModalObserverProvider = Provider<NavigatorObserver>(
  (_) => NavigatorObserver(),
);

/// Attached once for the app's life (one line in main.dart): routes the
/// native `find` method to `findMenuActionsProvider`, and sends
/// `setFindMenuEnabled` through `windowMenuHostProvider` whenever "a note
/// editor is showing and no modal route is over the workspace" changes.
///
/// WI #81 skeleton: does nothing yet.
final findMenuEnablementProvider = Provider<void>((_) {});
