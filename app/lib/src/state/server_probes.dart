import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/hosted/hosted_client.dart';

/// The last `GET /api/v1/info` result for each saved server id; null until a
/// probe of that server returns. The picker reads it for the notMemex and
/// apiMismatch row text (the dot comes from `hostedConnectionStatusProvider`).
final serverProbeResultProvider = StateProvider.family<ServerProbe?, String>(
  (ref, serverId) => throw UnimplementedError(),
);

/// Picker probes (WI #97): while watched, sends one `GET /api/v1/info` to
/// each saved server when first watched and once more to each whenever the
/// window regains focus (`appFocusProvider` false → true). Requests go
/// through #96's `hostedHttpClientProvider`; the access token comes from
/// `tokenStoreProvider`. Disposed with the picker, so reopening the
/// picker probes again.
final serverProbesProvider = Provider.autoDispose<void>(
  (ref) => throw UnimplementedError(),
);
