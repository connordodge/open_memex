import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// The app API version this app speaks (req 14, req 21). `probeServer()` is
/// the only place that compares a server's `api_version` with it (D17).
const kApiVersion = 1;

/// What `GET /api/v1/info` said about a vault server.
enum ServerProbeKind {
  connected,
  unreachable,
  unauthorized,
  notMemex,
  apiMismatch,
}

/// A [HostedClient.probeServer] result. [serverVersion] is the server's
/// `server_version` for [ServerProbeKind.connected] and
/// [ServerProbeKind.apiMismatch] (the L9 message names it), else null.
class ServerProbe {
  const ServerProbe(this.kind, {this.serverVersion});

  final ServerProbeKind kind;
  final String? serverVersion;
}

/// The app's one HTTP client for a saved vault server (D17).
///
/// Every request carries `Authorization: Bearer <access token>` and
/// `X-Memex-UTC-Offset` (from `utcOffsetProvider`, read per request), and
/// times out after 10 s through `clockProvider`. A request returns the
/// decoded JSON object or throws `MemexException` (C1) or
/// `VaultUnreachableException`; its outcome is written to
/// `hostedConnectionStatusProvider([serverId])`.
class HostedClient {
  HostedClient(
    this._ref, {
    required this.serverId,
    required this.serverName,
    required String serverUrl,
    required String accessToken,
    required http.Client httpClient,
  }) : _serverUrl = serverUrl,
       _accessToken = accessToken,
       _http = httpClient;

  // ignore: unused_field
  final Ref _ref;

  /// The saved server's id: the `hostedConnectionStatusProvider` key.
  final String serverId;

  /// The saved server's name, as `VaultUnreachableException` carries it.
  final String serverName;

  // ignore: unused_field
  final String _serverUrl;
  // ignore: unused_field
  final String _accessToken;
  // ignore: unused_field
  final http.Client _http;

  /// A server route: `<server url>/api/v1<path>` ([path] starts with `/`).
  /// [operation] labels errors: `'<operation> failed: …'`. [body], when
  /// given, is sent as JSON.
  Future<Map<String, Object?>> serverRequest(
    String method,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
  }) => throw UnimplementedError();

  /// A vault route: `<server url>/vaults/<vaultName>/api/v1<path>`.
  Future<Map<String, Object?>> vaultRequest(
    String method,
    String vaultName,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
  }) => throw UnimplementedError();

  /// `GET /api/v1/info`: the app's only `api_version` check. Never throws.
  Future<ServerProbe> probeServer() => throw UnimplementedError();
}
