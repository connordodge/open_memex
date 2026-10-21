import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/hosted/hosted_client.dart';
import '../vault_access/hosted/hosted_vault_access.dart';
import 'app_focus.dart';
import 'hosted_connection_state.dart';
import 'settings.dart';
import 'token_store.dart';

/// The last `GET /api/v1/info` result for each saved server id; null until a
/// probe of that server returns. The picker reads it for the notMemex and
/// apiMismatch row text (the dot comes from `hostedConnectionStatusProvider`).
final serverProbeResultProvider = StateProvider.family<ServerProbe?, String>(
  (ref, serverId) => null,
);

/// Picker probes (WI #97): while watched, sends one `GET /api/v1/info` to
/// each saved server when first watched and once more to each whenever the
/// window regains focus (`appFocusProvider` false → true). Requests go
/// through #96's `hostedHttpClientProvider`; the access token comes from
/// `tokenStoreProvider`. Disposed with the picker, so reopening the
/// picker probes again.
final serverProbesProvider = Provider.autoDispose<void>((ref) {
  var disposed = false;
  ref.onDispose(() => disposed = true);

  Future<void> probe(SavedServer server) async {
    final token = await ref.read(tokenStoreProvider).read(server.id);
    if (disposed) return;
    final ServerProbe result;
    if (token == null) {
      // No access token saved: nothing to send, the server would refuse it.
      ref.read(hostedConnectionStatusProvider(server.id).notifier).state =
          HostedConnectionStatus.tokenRejected;
      result = const ServerProbe(ServerProbeKind.unauthorized);
    } else {
      result = await HostedClient(
        ref,
        serverId: server.id,
        serverName: server.name,
        serverUrl: server.url,
        accessToken: token,
        httpClient: ref.read(hostedHttpClientProvider),
      ).probeServer();
      if (disposed) return;
    }
    ref.read(serverProbeResultProvider(server.id).notifier).state = result;
  }

  void probeAll() {
    for (final server in ref.read(settingsProvider).savedServers) {
      unawaited(probe(server));
    }
  }

  ref.listen<bool>(appFocusProvider, (previous, next) {
    if (previous == false && next) probeAll();
  });
  probeAll();
});
