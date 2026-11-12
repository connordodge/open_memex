import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent_activity.dart';

/// The Live tab chip's suffix, such as `2 connected`, or null for none
/// (Spec #394 req 9, RULINGS 6). The shell shows no suffix for null.
///
/// It reads [agentActivityAsyncProvider] and branches on `isLoading` first,
/// because Riverpod keeps the previous vault's view in `value` while the
/// next read loads (D31). Null while loading, on an error, on an unavailable
/// (older) server and with no agent connected; `<n> connected` for n >= 1.
final liveTabBadgeProvider = Provider.autoDispose<String?>((ref) {
  final activity = ref.watch(agentActivityAsyncProvider);
  if (activity.isLoading || activity.hasError) return null;
  final view = activity.valueOrNull;
  if (view == null || !view.available) return null;
  final n = view.connected.length;
  return n >= 1 ? '$n connected' : null;
});
