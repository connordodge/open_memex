import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_open_controller.dart';
import 'vault_ref.dart';

/// The open outcome recorded for each recents entry (D19). The picker
/// records what its own opens (row tap, retry, launch) gave; #96 records
/// hosted outcomes it finds elsewhere (vault gone while open). A recent row
/// renders the outcome recorded for its entry. Null: nothing recorded.
final recordedOpenOutcomeProvider =
    StateProvider.family<VaultOpenOutcome?, VaultRef>(
      (ref, entry) => throw UnimplementedError(),
    );

/// Hosted open failures (#96 returns them; #97 renders them on the row).

/// The vault server could not be reached (refused, host lookup, no network,
/// no response within 10 s). Row: "can't reach `server`" + retry.
class HostedServerUnreachable extends VaultOpenFailure {
  const HostedServerUnreachable(super.message);
}

/// The server answered 401. Row: "`server` rejected the access token" +
/// "update token".
class HostedTokenRejected extends VaultOpenFailure {
  const HostedTokenRejected(super.message);
}

/// The server's `api_version` is not this app's. [serverVersion] is the
/// server's `server_version`, named in the L9 message. Row: no action.
class HostedApiMismatch extends VaultOpenFailure {
  const HostedApiMismatch(super.message, {required this.serverVersion});

  final String serverVersion;
}

/// The server has no vault by that name (`vault_not_found`). Row: "`vault`
/// is no longer on `server`" + "remove from recents".
class HostedVaultGone extends VaultOpenFailure {
  const HostedVaultGone(super.message);
}

/// The server refused the vault's schema; [message] is the server's error
/// text, which the row shows. Row: no action.
class HostedSchemaRefused extends VaultOpenFailure {
  const HostedSchemaRefused(super.message);
}
