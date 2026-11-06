// WI #263 (N0): the shared click-test pump for the navigation seam. Click
// tests assert where a click goes, never tab counts, so the behaviour flip in
// #266 (N3) can't break them.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';

/// Records what goes through `TabsNotifier`'s navigation seam while the real
/// notifier from `tabsProvider` keeps running, with all its wiring and state:
///
/// ```dart
/// final tabs = TabsRecorder();
/// // overrides: [tabs.override]
/// expect(tabs.followed, [const NoteTab('x')]);
/// ```
///
/// Don't also override `tabsProvider`: a notifier built by hand doesn't read
/// [override]. Pass [observer] to a `TabsNotifier` built directly instead.
class TabsRecorder {
  /// Every target passed to `follow`, and every target passed to a function
  /// that `followLater` returned.
  final followed = <WorkspaceTab>[];

  /// Every target that reached `navigate`, including through `follow`.
  final navigated = <WorkspaceTab>[];

  /// The observer that fills [followed] and [navigated].
  late final TabsNavigationObserver observer = _RecorderObserver(this);

  /// Add to a test's provider overrides to record `tabsProvider`'s notifier.
  Override get override =>
      tabsNavigationObserverProvider.overrideWithValue(observer);
}

// Separate from TabsRecorder: its `followed` and `navigated` lists can't share
// a name with the observer's methods on one class.
class _RecorderObserver implements TabsNavigationObserver {
  _RecorderObserver(this._recorder);

  final TabsRecorder _recorder;

  @override
  void followed(WorkspaceTab target) => _recorder.followed.add(target);

  @override
  void navigated(WorkspaceTab target) => _recorder.navigated.add(target);
}
