import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ui_state_store.dart';

export 'ui_state_store.dart' show SidebarMode;

/// The sidebar mode of the current vault (Req 50, TD8): `Days` or `Topics`,
/// persisted per vault as `sidebar_mode` in `<vault>/.memex/ui_state.json`.
/// A vault with no stored (or an unknown) mode is in [SidebarMode.days].
final sidebarModeProvider = NotifierProvider<SidebarModeNotifier, SidebarMode>(
  SidebarModeNotifier.new,
);

class SidebarModeNotifier extends Notifier<SidebarMode> {
  @override
  SidebarMode build() => throw UnimplementedError();

  /// Switch to [mode] and persist it for the current vault. The returned
  /// future completes once `ui_state.json` holds the new mode.
  Future<void> select(SidebarMode mode) => throw UnimplementedError();
}
