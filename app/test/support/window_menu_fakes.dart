// WI #407 (SH, D18): the Window menu seam's test double. #408 (menu
// enablement) and the #394 journeys share it. WI #81 (Spec #61 F5) adds the
// Edit ▸ Find enablement calls.
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:open_memex_app/src/state/app_exit.dart';

/// A fake [WindowMenuHost]: [simulateOpenAgents] plays Window ▸ Agents…
/// (or ⇧⌘A reaching the menu), and every `setAgentsMenuEnabled` call is
/// recorded in order.
class FakeWindowMenuHost implements WindowMenuHost {
  VoidCallback? _onOpenAgents;

  /// How many times the app attached its callback.
  int attachCount = 0;

  /// How many times the app detached.
  int detachCount = 0;

  /// How many `openAgents` calls reached an attached callback.
  int openAgentsDelivered = 0;

  /// Every `setAgentsMenuEnabled` argument, oldest first.
  final List<bool> enabledCalls = [];

  /// Every `setFindMenuEnabled` argument, oldest first.
  final List<bool> findEnabledCalls = [];

  bool get isAttached => _onOpenAgents != null;

  /// The last pushed enablement, or null before any call (the native item
  /// starts disabled).
  bool? get enabled => enabledCalls.isEmpty ? null : enabledCalls.last;

  /// The last pushed Find items enablement, or null before any call (the
  /// native items start disabled).
  bool? get findEnabled =>
      findEnabledCalls.isEmpty ? null : findEnabledCalls.last;

  @override
  void attach({required VoidCallback onOpenAgents}) {
    attachCount++;
    _onOpenAgents = onOpenAgents;
  }

  @override
  void detach() {
    detachCount++;
    _onOpenAgents = null;
  }

  @override
  Future<void> setAgentsMenuEnabled(bool enabled) async {
    enabledCalls.add(enabled);
  }

  @override
  Future<void> setFindMenuEnabled(bool enabled) async {
    findEnabledCalls.add(enabled);
  }

  /// The person picks Window ▸ Agents… (or presses ⇧⌘A). Throws when no
  /// callback is attached, so a test cannot pass by delivering nowhere.
  void simulateOpenAgents() {
    final callback = _onOpenAgents;
    if (callback == null) {
      throw StateError(
        'no openAgents callback attached: the workspace did not attach to '
        'windowMenuHostProvider',
      );
    }
    openAgentsDelivered++;
    callback();
  }
}
