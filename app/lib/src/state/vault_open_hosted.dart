import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../memex_cli.dart';
import '../vault_access/errors.dart';
import '../vault_access/hosted/hosted_client.dart';
import '../vault_access/hosted/hosted_vault_access.dart';
import 'hosted_identity.dart';
import 'settings.dart';
import 'token_store.dart';
import 'vault_open_controller.dart';
import 'vault_state.dart';

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
/// failed open's "update token"). The app root binds it to the edit-server
/// dialog (`appRootOverrides` in main.dart); the default does nothing.
final updateTokenSeamProvider = Provider<void Function(String serverId)>(
  (_) => (_) {},
);

/// A hosted vault's identity, `<vault> · <server>` (Req 49): its pill label
/// and its window title.
String hostedVaultLabel(String vaultName, String serverName) =>
    '$vaultName · $serverName';

/// `can't reach <server>` (Req 47).
String hostedUnreachableMessage(String serverName) => "can't reach $serverName";

/// `<server> rejected the access token` (Req 47).
String hostedTokenRejectedMessage(String serverName) =>
    '$serverName rejected the access token';

/// `<url> isn't a memex vault server` (#97 ruling).
String hostedNotMemexMessage(String url) => "$url isn't a memex vault server";

/// The L9 message: the server runs a memex this app can't use.
String hostedApiMismatchMessage(String serverName, String serverVersion) =>
    "$serverName runs memex $serverVersion, which this app can't use. update "
    'the app or memex on the server so both are the same release.';

/// `<vault> is no longer on <server>` (Req 53a).
String hostedVaultGoneMessage(String vaultName, String serverName) =>
    '$vaultName is no longer on $serverName';

/// The number of the newest hosted open; one per container.
class _HostedOpenSequence {
  int latest = 0;
}

final _hostedOpenSequenceProvider = Provider<_HostedOpenSequence>(
  (_) => _HostedOpenSequence(),
);

/// Marks every hosted open still running as superseded, so none of them
/// changes the open vault when it finishes (the later open wins). Returns
/// the new sequence number. A local open calls it before it becomes current.
int supersedeHostedOpens(Ref ref) =>
    ++ref.read(_hostedOpenSequenceProvider).latest;

/// The open hosted vault's client (D19): set by a successful hosted open,
/// which read the access token, so `vaultAccessProvider` can build the
/// composite synchronously. Memory only: the token is never persisted.
class HostedSession {
  const HostedSession(this.vault, this.client);

  final HostedVaultRef vault;
  final HostedClient client;

  @override
  String toString() => 'HostedSession($vault)';
}

/// The session of the last successful hosted open; null before one.
final hostedSessionProvider = StateProvider<HostedSession?>((_) => null);

/// The native window title (L21): `<vault> · <server>` for a hosted vault,
/// the folder name for a local vault, "memex" with no vault open (picker).
final windowTitleTextProvider = Provider<String>((ref) {
  final vault = ref.watch(currentVaultProvider);
  return switch (vault) {
    null => 'memex',
    LocalVaultRef(:final path) => p.basename(path),
    HostedVaultRef(:final serverId, :final vaultName) => () {
      final servers = ref.watch(settingsProvider).savedServers;
      for (final s in servers) {
        if (s.id == serverId) return hostedVaultLabel(vaultName, s.name);
      }
      return vaultName;
    }(),
  };
});

/// The hosted branch of the open path (D19, D17). Probes the saved server
/// (`GET /api/v1/info`), then reads the vault info
/// (`GET /vaults/<name>/api/v1/info`); only then is [vault] remembered (when
/// [remember]) and made current. Records [recentRowOutcomeProvider] for
/// [vault]: [RecentRowOpening] while it runs, then [RecentRowFailed] or null
/// on success. Any failure leaves the open vault, the last vault and the
/// recents as they were. Runs no `memex` CLI and checks no schema (Req 34,
/// Req 53).
///
/// The later open wins (lead ruling): an open that is superseded by a newer
/// one (see [supersedeHostedOpens]) before it finishes changes nothing more:
/// no current vault, last vault, recents or session, and it records no
/// failure. It clears its own [RecentRowOpening] (so the row does not stay
/// "connecting" forever), but only while the row still holds the marker
/// this open wrote: a newer open's state of the same vault is kept. It
/// returns [VaultOpenCancelled].
Future<VaultOpenOutcome> openHostedVault(
  Ref ref,
  HostedVaultRef vault, {
  required bool remember,
}) async {
  final ticket = supersedeHostedOpens(ref);
  final row = ref.read(recentRowOutcomeProvider(vault).notifier);
  final settings = ref.read(settingsProvider);
  SavedServer? server;
  for (final s in settings.savedServers) {
    if (s.id == vault.serverId) server = s;
  }
  if (server == null) {
    const failure = VaultOpenFailure(
      'this vault server is no longer saved. add it again to open its vaults.',
    );
    row.state = const RecentRowFailed(failure);
    return failure;
  }
  // A fresh instance, not the const one: a superseded open clears the row
  // only while it still holds this open's own marker (identity check).
  // ignore: prefer_const_constructors
  final opening = RecentRowOpening();
  row.state = opening;
  final outcome = await _probeAndOpen(
    ref,
    vault,
    server,
    remember: remember,
    superseded: () => ref.read(_hostedOpenSequenceProvider).latest != ticket,
  );
  if (outcome is VaultOpenCancelled ||
      ref.read(_hostedOpenSequenceProvider).latest != ticket) {
    // Superseded: clear this open's own opening marker, never a newer
    // open's state of the same vault.
    if (identical(row.state, opening)) row.state = null;
    return const VaultOpenCancelled();
  }
  if (outcome is VaultOpenFailure) {
    row.state = RecentRowFailed(outcome);
  } else {
    row.state = null;
  }
  return outcome;
}

Future<VaultOpenOutcome> _probeAndOpen(
  Ref ref,
  HostedVaultRef vault,
  SavedServer server, {
  required bool remember,
  required bool Function() superseded,
}) async {
  final name = server.name;
  String? token;
  try {
    token = await ref.read(tokenStoreProvider).read(server.id);
  } on Object {
    token = null;
  }
  if (token == null || token.isEmpty) {
    return HostedTokenRejected(vault, name, hostedTokenRejectedMessage(name));
  }
  final client = HostedClient(
    ref,
    serverId: server.id,
    serverName: name,
    serverUrl: server.url,
    accessToken: token,
    httpClient: ref.read(hostedHttpClientProvider),
  );

  final probe = await client.probeServer();
  switch (probe.kind) {
    case ServerProbeKind.connected:
      break;
    case ServerProbeKind.unreachable:
      return HostedServerUnreachable(
        vault,
        name,
        hostedUnreachableMessage(name),
      );
    case ServerProbeKind.unauthorized:
      return HostedTokenRejected(vault, name, hostedTokenRejectedMessage(name));
    case ServerProbeKind.notMemex:
      return HostedNotMemexServer(
        vault,
        name,
        hostedNotMemexMessage(server.url),
      );
    case ServerProbeKind.apiMismatch:
      final version = probe.serverVersion ?? '';
      return HostedApiMismatch(
        vault,
        name,
        hostedApiMismatchMessage(name, version),
        serverVersion: version,
      );
  }

  const operation = 'info';
  try {
    await client.vaultRequest(
      'GET',
      vault.vaultName,
      '/info',
      operation: operation,
    );
  } on VaultUnreachableException {
    return HostedServerUnreachable(vault, name, hostedUnreachableMessage(name));
  } on MemexException catch (e) {
    return switch (e.code) {
      'unauthorized' => HostedTokenRejected(
        vault,
        name,
        hostedTokenRejectedMessage(name),
      ),
      vaultNotFoundCode => _gone(ref, vault, name),
      // Any other refusal of the vault: the server's own error text.
      _ => HostedSchemaRefused(vault, name, _serverText(e, operation)),
    };
  }

  if (superseded()) return const VaultOpenCancelled();
  if (remember) {
    await ref.read(settingsProvider.notifier).rememberRef(vault);
    if (superseded()) return const VaultOpenCancelled();
  }
  ref.read(hostedSessionProvider.notifier).state = HostedSession(vault, client);
  ref.read(hostedVaultGoneProvider(vault).notifier).state = false;
  final current = ref.read(currentVaultProvider.notifier);
  if (current.state != vault) current.state = vault;
  return VaultOpened(vault);
}

/// The open path found [vault] gone from its server: sets
/// [hostedVaultGoneProvider] for it and returns the failure.
HostedVaultGone _gone(Ref ref, HostedVaultRef vault, String serverName) {
  ref.read(hostedVaultGoneProvider(vault).notifier).state = true;
  return HostedVaultGone(
    vault,
    serverName,
    hostedVaultGoneMessage(vault.vaultName, serverName),
  );
}

/// The server's error text of [e]: its message without the
/// `'<operation> failed: '` label `MemexException.fromC1` adds.
String _serverText(MemexException e, String operation) {
  final label = '$operation failed: ';
  return e.message.startsWith(label)
      ? e.message.substring(label.length)
      : e.message;
}

/// The saved server [serverId]'s access token was replaced (the edit-server
/// dialog saved): the open hosted vault's session, when it is on that
/// server, sends its later requests (polls, reads, saves) with the token now
/// in the token store, starting with one `probeServer` so the server's
/// status reflects the new token. The dialog's own probe already set the
/// status to connected, and a poll the revision poller resumed on that may
/// have gone out with the old token and been refused (401 stops the poller
/// again); this probe's answer resumes it.
Future<void> hostedServerTokenChanged(Ref ref, String serverId) async {
  final session = ref.read(hostedSessionProvider);
  if (session == null || session.vault.serverId != serverId) return;
  final token = await ref.read(tokenStoreProvider).read(serverId);
  if (token == null || token.isEmpty) return;
  if (ref.read(hostedSessionProvider) != session) return;
  session.client.useAccessToken(token);
  await session.client.probeServer();
}

/// The open hosted [vault] went away (a `vault_not_found` on any request,
/// Req 53a): sets [hostedVaultGoneProvider], records its row as vault gone
/// and returns to the picker at once (no timer). The last vault is cleared so
/// the picker does not reopen it.
/// Does nothing once another vault is open.
Future<void> hostedVaultGone(Ref ref, HostedVaultRef vault) async {
  if (ref.read(currentVaultProvider) != vault) return;
  ref.read(hostedVaultGoneProvider(vault).notifier).state = true;
  final settings = ref.read(settingsProvider);
  var serverName = vault.serverId;
  for (final s in settings.savedServers) {
    if (s.id == vault.serverId) serverName = s.name;
  }
  ref.read(recentRowOutcomeProvider(vault).notifier).state = RecentRowFailed(
    HostedVaultGone(
      vault,
      serverName,
      hostedVaultGoneMessage(vault.vaultName, serverName),
    ),
  );
  if (settings.lastVaultRef == vault) {
    await ref.read(settingsProvider.notifier).clearLastVault();
  }
  if (ref.read(currentVaultProvider) != vault) return;
  ref.read(currentVaultProvider.notifier).state = null;
  ref.read(selectedNoteIdProvider.notifier).state = null;
}
