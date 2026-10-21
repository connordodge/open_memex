import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/hosted/hosted_client.dart';
import 'vault_ref.dart';

/// Display name of a saved vault server, by server id. Defaults to the id; #105 binds it to the saved server's name.
final hostedServerNameProvider = Provider.family<String, String>(
  (ref, serverId) => serverId,
);

/// Opens the edit-server dialog for the saved server `serverId` so its access
/// token can be replaced (H7 seam, #105 binds it to #98). Defaults to doing
/// nothing.
final hostedUpdateTokenProvider = Provider<void Function(String serverId)>(
  (ref) => (serverId) {},
);

/// The `HostedClient` of saved server `serverId` for the "retry now" button
/// (H7 seam, #105 binds it). Null until bound: "retry now" then sends
/// nothing.
final hostedClientForServerProvider = Provider.family<HostedClient?, String>(
  (ref, serverId) => null,
);

/// True once a request found the hosted vault gone from its server
/// (`vault_not_found`, Req 53a). The poller or opener that sees the error
/// sets it; the banner slot reads it.
final hostedVaultGoneProvider = StateProvider.family<bool, HostedVaultRef>(
  (ref, vault) => false,
);
