import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Agents sheet's tabs, in their on-screen order (Spec #394 req 9).
enum AgentsTab { live, connect, tools, recall }

/// The open sheet's active tab (sheet-scoped: it lives while a sheet is
/// open). A tab switches to another with [AgentsSheetTabNotifier.select]
/// (Live's `Set up an agent`, Recall's `its command`).
///
/// It starts on [AgentsTab.connect], the opening-tab fallback (req 10); the
/// sheet shows no tab as active until it has made its opening-tab choice.
class AgentsSheetTabNotifier extends AutoDisposeNotifier<AgentsTab> {
  @override
  AgentsTab build() => AgentsTab.connect;

  /// Makes [tab] the active tab.
  void select(AgentsTab tab) => state = tab;
}

/// The open Agents sheet's active tab.
final agentsSheetTabProvider =
    AutoDisposeNotifierProvider<AgentsSheetTabNotifier, AgentsTab>(
      AgentsSheetTabNotifier.new,
    );
