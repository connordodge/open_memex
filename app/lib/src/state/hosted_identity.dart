import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/hosted/hosted_client.dart';
import 'settings.dart';
import 'vault_open_hosted.dart';
import 'vault_ref.dart';

/// Display name of a saved vault server, by server id: the saved server's
/// name (#91 `SavedServer.name`, so it follows a rename), or the id when no
/// saved server has it.
final hostedServerNameProvider = Provider.family<String, String>((
  ref,
  serverId,
) {
  for (final s in ref.watch(settingsProvider).savedServers) {
    if (s.id == serverId) return s.name;
  }
  return serverId;
});

/// Opens the edit-server dialog for the saved server `serverId` so its access
/// token can be replaced (H7 seam). The app root binds it to #98's
/// edit-server dialog (`appRootOverrides` in main.dart, so state/ imports no
/// widget); the default does nothing.
final hostedUpdateTokenProvider = Provider<void Function(String serverId)>(
  (ref) => (serverId) {},
);

/// The `HostedClient` of saved server `serverId` for the "retry now" button
/// (H7 seam): the open hosted vault's client when that vault is on
/// `serverId`, which carries the server's saved access token. Null for an id
/// with no saved server, and for a saved server with no open hosted vault
/// (its token is only read by an open): "retry now" then sends nothing.
final hostedClientForServerProvider = Provider.family<HostedClient?, String>((
  ref,
  serverId,
) {
  final session = ref.watch(hostedSessionProvider);
  if (session == null || session.vault.serverId != serverId) return null;
  final saved = ref
      .watch(settingsProvider)
      .savedServers
      .any((s) => s.id == serverId);
  return saved ? session.client : null;
});

/// True once a request found the hosted vault gone from its server
/// (`vault_not_found`, Req 53a). The poller or opener that sees the error
/// sets it (`hostedVaultGone`, the open path); a successful open of the
/// vault clears it. The banner slot reads it.
final hostedVaultGoneProvider = StateProvider.family<bool, HostedVaultRef>(
  (ref, vault) => false,
);
