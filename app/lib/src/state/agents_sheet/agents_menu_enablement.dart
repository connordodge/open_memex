// WI #408 (EP; Spec #394 req 5; D24): Window ▸ Agents… enablement.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_exit.dart';
import '../vault_state.dart';

/// Attached once for the app's life (one appended line in main.dart): sends
/// `setAgentsMenuEnabled(false)` through `windowMenuHostProvider` at launch
/// while no vault is open, `true` on every vault open and `false` on every
/// close, by listening to `currentVaultProvider`. A switch straight from one
/// open vault to another never sends false. A native error is logged and
/// swallowed: the item keeps its last state and later changes still send.
final agentsMenuEnablementProvider = Provider<void>((ref) {
  final host = ref.watch(windowMenuHostProvider);
  ref.listen<bool>(
    currentVaultProvider.select((vault) => vault != null),
    (_, open) => unawaited(_send(host, open)),
    fireImmediately: true,
  );
});

Future<void> _send(WindowMenuHost host, bool enabled) async {
  try {
    await host.setAgentsMenuEnabled(enabled);
  } on PlatformException catch (e) {
    debugPrint('setAgentsMenuEnabled($enabled) failed: $e');
  }
}
