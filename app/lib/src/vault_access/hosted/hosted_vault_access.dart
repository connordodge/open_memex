import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../memex_cli.dart';
import '../vault_access.dart';
import 'agents.dart';
import 'canvas.dart';
import 'daily.dart';
import 'feedback.dart';
import 'graph.dart';
import 'hosted_client.dart';
import 'notes.dart';
import 'revision.dart';
import 'tags.dart';
import 'topics.dart';
import 'words.dart';

/// The HTTP client every hosted vault request goes through (D17): a real
/// client, closed when the provider is disposed. Tests override it with a
/// fake vault server's client; no test reaches the network.
final hostedHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// The C1 code a vault server answers for a vault it no longer serves.
const vaultNotFoundCode = 'vault_not_found';

/// The [VaultAccess] of one hosted vault (D13, D19): V1–V5's hosted domain
/// classes and #94's hosted revision, all over [client] for [vaultName].
/// `vaultAccessProvider` gives it for a `HostedVaultRef` and disposes it when
/// the open vault changes; a disposed composite sends no request.
///
/// [onVaultGone] runs when a request of a live composite fails with C1
/// `vault_not_found` (Req 53a); the error still reaches the caller.
class HostedVaultAccess implements VaultAccess {
  HostedVaultAccess({
    required HostedClient client,
    required String vaultName,
    void Function()? onVaultGone,
  }) : this._(_ComposedClient(client, onVaultGone), vaultName);

  HostedVaultAccess._(_ComposedClient client, this.vaultName)
    : _client = client,
      notes = HostedNotesAccess(client: client, vaultName: vaultName),
      agents = HostedAgentsAccess(client: client, vaultName: vaultName),
      daily = HostedDailyAccess(client: client, vaultName: vaultName),
      feedback = HostedFeedbackAccess(client: client, vaultName: vaultName),
      topics = HostedTopicsAccess(client: client, vaultName: vaultName),
      echoes = HostedEchoesAccess(client: client, vaultName: vaultName),
      canvas = HostedCanvasAccess(client: client, vaultName: vaultName),
      graph = HostedGraphAccess(client: client, vaultName: vaultName),
      tags = HostedTagsAccess(client: client, vaultName: vaultName),
      words = HostedWordsAccess(client: client, vaultName: vaultName),
      _revision = HostedRevision(client, vaultName);

  final _ComposedClient _client;

  /// The served vault's name on the vault server.
  final String vaultName;

  @override
  final HostedNotesAccess notes;

  @override
  final HostedAgentsAccess agents;

  @override
  final HostedDailyAccess daily;

  @override
  final HostedFeedbackAccess feedback;

  @override
  final HostedTopicsAccess topics;

  @override
  final HostedEchoesAccess echoes;

  @override
  final HostedCanvasAccess canvas;

  @override
  final HostedGraphAccess graph;

  @override
  final HostedTagsAccess tags;

  @override
  final HostedWordsAccess words;

  final HostedRevision _revision;

  @override
  Future<String> revision() => _revision.revision();

  /// The vault info route's `schema_version`, unchecked (Req 53).
  @override
  Future<int> schemaVersion() => graph.schemaVersion();

  /// A hosted vault writes through the server: never needs a `memex` binary
  /// (Req 34).
  @override
  bool get canWrite => true;

  /// Closes the composite: every later request fails with a [StateError]
  /// and sends nothing.
  void dispose() => _client.disposed = true;
}

/// The [HostedClient] the domains of one composite share: forwards to the
/// open's client until the composite is disposed, then refuses every request
/// without sending it. Reports `vault_not_found` to the composite's owner.
class _ComposedClient implements HostedClient {
  _ComposedClient(this._inner, this._onVaultGone);

  final HostedClient _inner;
  final void Function()? _onVaultGone;

  bool disposed = false;

  @override
  String get serverId => _inner.serverId;

  @override
  String get serverName => _inner.serverName;

  @override
  void useAccessToken(String token) => _inner.useAccessToken(token);

  @override
  Future<ServerProbe> probeServer() =>
      _guard(() => _inner.probeServer(), 'probeServer');

  @override
  Future<Map<String, Object?>> serverRequest(
    String method,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
  }) => _guard(
    () => _inner.serverRequest(
      method,
      path,
      operation: operation,
      query: query,
      body: body,
    ),
    operation,
  );

  @override
  Future<Map<String, Object?>> vaultRequest(
    String method,
    String vaultName,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
    Duration? timeout,
  }) => _guard(
    () => _inner.vaultRequest(
      method,
      vaultName,
      path,
      operation: operation,
      query: query,
      body: body,
      timeout: timeout,
    ),
    operation,
  );

  Future<T> _guard<T>(Future<T> Function() send, String operation) async {
    if (disposed) {
      throw StateError('$operation: this hosted vault is no longer open');
    }
    try {
      return await send();
    } on MemexException catch (e) {
      if (e.code == vaultNotFoundCode && !disposed) _onVaultGone?.call();
      rethrow;
    }
  }
}
