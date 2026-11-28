import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../memex_cli.dart';
import '../../state/clock.dart';
import '../../state/hosted_connection_state.dart';
import '../errors.dart';
import 'utc_offset.dart';

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

/// How long a request may take, headers and body, before it is unreachable
/// (req 50).
const _requestTimeout = Duration(seconds: 10);

/// A request that passed its own `timeout` to [HostedClient.vaultRequest] and
/// got no response in time (#425). Unlike [VaultUnreachableException] it does
/// not record `unreachable`: a slow run is not an outage. The request was
/// aborted; it may have reached the server.
class HostedRequestTimeout implements Exception {
  const HostedRequestTimeout();

  @override
  String toString() => 'HostedRequestTimeout';
}

/// 1 MB as R15 and the transfer timeout count it: 1,048,576 bytes.
const _bytesPerMb = 1024 * 1024;

/// The largest attachment (R15), 100 MB: a download of unknown size waits as
/// long as one of this size.
const _largestTransferBytes = 100 * _bytesPerMb;

/// How long a raw transfer of [bytes] may take, headers and body, before it
/// is unreachable (Spec #123 TD "Hosted client"): 60 s plus 1 s per started
/// MB (1,048,576 bytes).
Duration hostedTransferTimeout(int bytes) =>
    Duration(seconds: 60 + (bytes + _bytesPerMb - 1) ~/ _bytesPerMb);

/// A raw (not JSON) 2xx answer of [HostedClient.uploadBytes],
/// [HostedClient.downloadBytes] or [HostedClient.head].
class HostedBytes {
  const HostedBytes({
    required this.bytes,
    required this.contentType,
    required this.contentLength,
  });

  /// The body; empty for a HEAD.
  final Uint8List bytes;

  /// The `Content-Type` header, or null.
  final String? contentType;

  /// The `Content-Length` header (a HEAD answer's size of the GET body), or
  /// null when absent or not a number.
  final int? contentLength;
}

/// A raw request's non-2xx answer whose body is no C1 error (a HEAD answer
/// has no body). [statusCode] is the HTTP status.
class HostedStatusException extends MemexException {
  HostedStatusException(String operation, this.statusCode)
    : super('$operation failed: HTTP $statusCode');

  final int statusCode;
}

/// macOS errno values of socket failures that happen before the request is
/// written, so the server cannot have committed anything: ECONNREFUSED (61),
/// EAI_NONAME from a failed host lookup (8), ENETUNREACH (51) and
/// EHOSTUNREACH (65). Every other transport failure may have committed.
const _notSentErrnos = {61, 8, 51, 65};

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
    required this._serverUrl,
    required this._accessToken,
    required http.Client httpClient,
  }) : _http = httpClient;

  final Ref _ref;

  /// The saved server's id: the `hostedConnectionStatusProvider` key.
  final String serverId;

  /// The saved server's name, as `VaultUnreachableException` carries it.
  final String serverName;

  final String _serverUrl;
  String _accessToken;
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
  }) => _request(
    method,
    _uri('/api/v1$path', query),
    operation: operation,
    body: body,
  );

  /// A vault route: `<server url>/vaults/<vaultName>/api/v1<path>`. [timeout]
  /// replaces the 10 s default for this request; when it fires the request
  /// is aborted and [HostedRequestTimeout] is thrown (#425).
  Future<Map<String, Object?>> vaultRequest(
    String method,
    String vaultName,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
    Duration? timeout,
  }) => _request(
    method,
    _vaultUri(vaultName, path, query),
    operation: operation,
    body: body,
    timeout: timeout,
  );

  /// Whether this server has the attachment routes (Spec #123 R42), once
  /// known in this server session (this client's life): the attachments
  /// domain sets it from a check or from any attachment route's answer, and
  /// clears it when the check could not reach the server. Shared by every
  /// vault of this client.
  Future<bool>? attachmentRoutesCheck;

  /// A raw upload to a vault route: a `POST` of [bytes] as an
  /// `application/octet-stream` body to
  /// `<server url>/vaults/<vaultName>/api/v1<path>` ([path] already
  /// percent-encoded). Waits
  /// [hostedTransferTimeout] of the body size, then is unreachable. Answers
  /// the raw 2xx body; throws `MemexException` (C1), [HostedStatusException]
  /// or `VaultUnreachableException` like [vaultRequest].
  Future<HostedBytes> uploadBytes(
    String vaultName,
    String path,
    Uint8List bytes, {
    required String operation,
    Map<String, String>? query,
  }) => _rawRequest(
    'POST',
    _vaultUri(vaultName, path, query),
    operation: operation,
    bytes: bytes,
    timeout: hostedTransferTimeout(bytes.length),
  );

  /// A raw `GET` of a vault route ([path] already percent-encoded): the body
  /// bytes, never decoded. Waits [hostedTransferTimeout] of
  /// [expectedBytes] (100 MB, the largest attachment, when unknown).
  Future<HostedBytes> downloadBytes(
    String vaultName,
    String path, {
    required String operation,
    int? expectedBytes,
  }) => _rawRequest(
    'GET',
    _vaultUri(vaultName, path, null),
    operation: operation,
    timeout: hostedTransferTimeout(expectedBytes ?? _largestTransferBytes),
  );

  /// A `HEAD` of a vault route ([path] already percent-encoded): its
  /// headers, no body. Waits [hostedTransferTimeout] of 0 bytes (60 s). A
  /// non-2xx answer has no body, so it throws [HostedStatusException].
  Future<HostedBytes> head(
    String vaultName,
    String path, {
    required String operation,
  }) => _rawRequest(
    'HEAD',
    _vaultUri(vaultName, path, null),
    operation: operation,
    timeout: hostedTransferTimeout(0),
  );

  /// `GET /api/v1/info`: the app's only `api_version` check. Never throws.
  Future<ServerProbe> probeServer() async {
    final http.Response response;
    try {
      response = await _exchange('GET', _uri('/api/v1/info', null), null);
    } on VaultUnreachableException {
      return const ServerProbe(ServerProbeKind.unreachable);
    }
    if (response.statusCode == HttpStatus.unauthorized) {
      _record(HostedConnectionStatus.tokenRejected);
      return const ServerProbe(ServerProbeKind.unauthorized);
    }
    final probe = _readInfo(response);
    _record(
      probe.kind == ServerProbeKind.connected
          ? HostedConnectionStatus.connected
          : HostedConnectionStatus.incompatible,
    );
    return probe;
  }

  /// What an info [response] (not a 401) says: notMemex unless it is a 2xx
  /// JSON object with a string `server_version` and an integer
  /// `api_version`; apiMismatch when that version isn't [kApiVersion].
  static ServerProbe _readInfo(http.Response response) {
    const notMemex = ServerProbe(ServerProbeKind.notMemex);
    if (!_isSuccess(response.statusCode)) return notMemex;
    final info = _decodeJson(response);
    if (info is! Map<String, Object?>) return notMemex;
    final serverVersion = info['server_version'];
    final apiVersion = info['api_version'];
    if (serverVersion is! String || apiVersion is! int) return notMemex;
    return ServerProbe(
      apiVersion == kApiVersion
          ? ServerProbeKind.connected
          : ServerProbeKind.apiMismatch,
      serverVersion: serverVersion,
    );
  }

  Future<Map<String, Object?>> _request(
    String method,
    Uri uri, {
    required String operation,
    required Object? body,
    Duration? timeout,
  }) async {
    final response = await _exchange(method, uri, body, timeout: timeout);
    final decoded = _decodeJson(response);
    final error = _c1ErrorOf(decoded);
    if (response.statusCode == HttpStatus.unauthorized) {
      _record(HostedConnectionStatus.tokenRejected);
      throw MemexException.fromC1(operation, {
        ...?error,
        'code': 'unauthorized',
      });
    }
    _record(HostedConnectionStatus.connected);
    if (!_isSuccess(response.statusCode)) {
      if (error != null) throw MemexException.fromC1(operation, error);
      // Never the body: a proxy page may echo the request headers.
      throw MemexException('$operation failed: HTTP ${response.statusCode}');
    }
    if (decoded is! Map<String, Object?>) {
      throw MemexException(
        '$operation failed: the server response is not a JSON object',
      );
    }
    return decoded;
  }

  Uri _vaultUri(String vaultName, String path, Map<String, String>? query) =>
      _uri('/vaults/${Uri.encodeComponent(vaultName)}/api/v1$path', query);

  Future<HostedBytes> _rawRequest(
    String method,
    Uri uri, {
    required String operation,
    required Duration timeout,
    Uint8List? bytes,
  }) async {
    final response = await _exchange(
      method,
      uri,
      null,
      bytes: bytes,
      unreachableAfter: timeout,
    );
    final error = _isSuccess(response.statusCode)
        ? null
        : _c1ErrorOf(_decodeJson(response));
    if (response.statusCode == HttpStatus.unauthorized) {
      _record(HostedConnectionStatus.tokenRejected);
      throw MemexException.fromC1(operation, {
        ...?error,
        'code': 'unauthorized',
      });
    }
    _record(HostedConnectionStatus.connected);
    if (!_isSuccess(response.statusCode)) {
      if (error != null) throw MemexException.fromC1(operation, error);
      throw HostedStatusException(operation, response.statusCode);
    }
    return HostedBytes(
      bytes: response.bodyBytes,
      contentType: response.headers['content-type'],
      contentLength: int.tryParse(response.headers['content-length'] ?? ''),
    );
  }

  /// Sends one request and reads the whole response, or throws
  /// [VaultUnreachableException] after recording `unreachable`. Once the
  /// timeout fires, a late response or failure is ignored. Without a caller
  /// [timeout] it is 10 s and records `unreachable`; with one, it throws
  /// [HostedRequestTimeout] and records nothing. [unreachableAfter] replaces
  /// the 10 s and keeps its `unreachable` outcome (raw transfers). [bytes],
  /// when given, is sent as an `application/octet-stream` body.
  Future<http.Response> _exchange(
    String method,
    Uri uri,
    Object? body, {
    Duration? timeout,
    Duration? unreachableAfter,
    Uint8List? bytes,
  }) {
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      uri,
      abortTrigger: abort.future,
    );
    request.headers['Authorization'] = 'Bearer $_accessToken';
    request.headers['X-Memex-UTC-Offset'] = formatUtcOffset(
      _ref.read(utcOffsetProvider)(),
    );
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (bytes != null) {
      request.headers['Content-Type'] = 'application/octet-stream';
      request.bodyBytes = bytes;
    }

    final outcome = Completer<http.Response>();
    void unreachable({required bool mayHaveCommitted}) {
      _record(HostedConnectionStatus.unreachable);
      outcome.completeError(
        VaultUnreachableException(
          serverName: serverName,
          mayHaveCommitted: mayHaveCommitted,
        ),
      );
    }

    final timer = _ref.read(clockProvider).after(
      timeout ?? unreachableAfter ?? _requestTimeout,
      () {
        if (outcome.isCompleted) return;
        if (timeout == null) {
          unreachable(mayHaveCommitted: true);
        } else {
          outcome.completeError(const HostedRequestTimeout());
        }
        abort.complete();
      },
    );

    unawaited(() async {
      try {
        final streamed = await _http.send(request);
        final response = await http.Response.fromStream(streamed);
        if (outcome.isCompleted) return;
        timer.cancel();
        outcome.complete(response);
      } catch (e) {
        if (outcome.isCompleted) return;
        timer.cancel();
        unreachable(mayHaveCommitted: !_failedBeforeSending(e));
      }
    }());
    return outcome.future;
  }

  /// Sends every later request with [token]: the saved server's access token
  /// was replaced (the edit-server dialog) while this client is in use.
  void useAccessToken(String token) => _accessToken = token;

  /// The response hook: records each request's outcome as this server's
  /// status.
  void _record(HostedConnectionStatus status) =>
      _ref.read(hostedConnectionStatusProvider(serverId).notifier).state =
          status;

  /// `<server url><path>`, keeping any path prefix of the saved URL and
  /// dropping its trailing slashes.
  Uri _uri(String path, Map<String, String>? query) {
    var base = _serverUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.parse('$base$path');
    return query == null || query.isEmpty
        ? uri
        : uri.replace(queryParameters: query);
  }

  static bool _isSuccess(int status) => status >= 200 && status < 300;

  /// The response body decoded as UTF-8 JSON, or null when it isn't JSON.
  static Object? _decodeJson(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  /// The C1 error object of a decoded body `{"error":{"code":"…",…}}`, or
  /// null.
  static Map<String, Object?>? _c1ErrorOf(Object? decoded) {
    if (decoded is! Map<String, Object?>) return null;
    final error = decoded['error'];
    return error is Map<String, Object?> && error['code'] is String
        ? error
        : null;
  }

  /// True for a socket failure known to happen before the request is sent
  /// (refused, host lookup, no network, no route); anything else may have
  /// reached the server.
  static bool _failedBeforeSending(Object error) =>
      error is SocketException &&
      _notSentErrnos.contains(error.osError?.errorCode);
}
