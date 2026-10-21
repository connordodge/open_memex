import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_open_controller.dart';
import 'vault_ref.dart';

/// A hosted open that failed (Req 47, D19): nothing opened. [message] is the
/// copy a recent row and a failed pill's snackbar show.
abstract class HostedVaultOpenFailure extends VaultOpenFailure {
  const HostedVaultOpenFailure(this.vault, this.serverName, super.message);

  /// The hosted vault that did not open.
  final HostedVaultRef vault;

  /// The saved server's name, as the copy names it.
  final String serverName;
}

/// Connection refused, or no response within 10 s.
class HostedServerUnreachable extends HostedVaultOpenFailure {
  const HostedServerUnreachable(super.vault, super.serverName, super.message);
}

/// The server answered 401, or no access token is saved for it.
class HostedTokenRejected extends HostedVaultOpenFailure {
  const HostedTokenRejected(super.vault, super.serverName, super.message);
}

/// The URL does not answer as a memex vault server.
class HostedNotMemexServer extends HostedVaultOpenFailure {
  const HostedNotMemexServer(super.vault, super.serverName, super.message);
}

/// The server's `api_version` is not this app's; [serverVersion] is its
/// `server_version`, which the L9 message names.
class HostedApiMismatch extends HostedVaultOpenFailure {
  const HostedApiMismatch(
    super.vault,
    super.serverName,
    super.message, {
    required this.serverVersion,
  });

  final String serverVersion;
}

/// `404 vault_not_found`: the vault is no longer on the server.
class HostedVaultGone extends HostedVaultOpenFailure {
  const HostedVaultGone(super.vault, super.serverName, super.message);
}

/// The server refused to open the vault (its schema); [message] is the
/// server's error text.
class HostedSchemaRefused extends HostedVaultOpenFailure {
  const HostedSchemaRefused(super.vault, super.serverName, super.message);
}

/// What a recent row's entry shows (D19); #97 renders it.
sealed class RecentRowOutcome {
  const RecentRowOutcome();
}

/// The open path is running for the entry.
final class RecentRowOpening extends RecentRowOutcome {
  const RecentRowOpening();
}

/// The entry's last open failed with [failure].
final class RecentRowFailed extends RecentRowOutcome {
  const RecentRowFailed(this.failure);

  final VaultOpenFailure failure;
}

/// The recorded outcome of each recent entry: null when nothing is recorded
/// (or the last open succeeded), [RecentRowOpening] while an open runs, else
/// [RecentRowFailed].
final recentRowOutcomeProvider =
    StateProvider.family<RecentRowOutcome?, VaultRef>((ref, _) => null);

/// Asks for a new access token for the saved server with the given id (a
/// failed open's "update token"). #105 binds it to the edit-server dialog;
/// the default does nothing.
final updateTokenSeamProvider = Provider<void Function(String serverId)>(
  (_) => (_) {},
);
