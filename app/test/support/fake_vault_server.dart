// A fake vault server for Dart tests (WI #77, D17). It is a `MockClient`
// (`package:http/testing.dart`): no real network. Hand [FakeVaultServer.client]
// to `HostedClient`.
//
// It serves the rows of any `test/fixtures/api_v1/<domain>/index.json`
// ([FakeVaultServer.serveDomain]) and can simulate a refused connection, a
// failed host lookup, an unreachable network, a request that never answers,
// a connection dropped after sending, a wrong access token (401), a vault
// that is gone (`vault_not_found`), a server that isn't a memex vault server
// (HTML), and a held (gated) response.
//
// Like the real server, every request needs `Authorization: Bearer <token>`;
// a missing or wrong token gets 401 with the `errors/unauthorized.json` body.
//
// WI #140 (Spec #123 R40, R42, D19) adds the attachment routes
// ([FakeVaultServer.serveAttachments]): `POST /attachments?name=`, `GET|HEAD
// /attachments/{*path}`, an old server without them
// ([FakeVaultServer.attachmentRoutesMissing]), the 8 MiB body limit of every
// other route, and held uploads or downloads. Like the real server, a HEAD
// answer never has a body (a HEAD 404 can't say which 404 it is).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:open_memex_app/src/editor/attachment_ref.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:path/path.dart' as p;

import 'api_fixtures.dart';

/// The fake's default base URL (a saved server URL, no trailing slash).
const fakeServerUrl = 'http://nas.local:7878';

/// The fake's default access token.
const fakeServerToken = 'fake-access-token-77';

/// The saved-server id and name [FakeVaultServer.connect] uses by default.
const fakeServerId = 'srv-nas';
const fakeServerName = 'nas';

/// The body of a fake non-memex server (a router admin page).
const fakeHtmlBody =
    '<!doctype html><html><head><title>router</title></head>'
    '<body><h1>admin login</h1></body></html>';

/// A transport failure the fake applies to every request while set.
enum FakeServerFailure {
  /// Nothing listens on the port: ECONNREFUSED before anything is sent.
  refused,

  /// The host name does not resolve.
  hostLookup,

  /// The network is unreachable (ENETUNREACH) before anything is sent.
  networkUnreachable,

  /// The request was sent and no response ever comes.
  timeout,

  /// The request was sent and the connection closed before a response.
  drop,
}

/// What `IOClient` throws for a socket failure: a [http.ClientException]
/// that also implements [SocketException] (package:http 1.x).
class FakeClientSocketException extends http.ClientException
    implements SocketException {
  FakeClientSocketException(this.cause, Uri uri) : super(cause.message, uri);

  final SocketException cause;

  @override
  InternetAddress? get address => cause.address;

  @override
  OSError? get osError => cause.osError;

  @override
  int? get port => cause.port;

  @override
  String toString() => 'ClientException with $cause, uri=$uri';
}

/// The exception `IOClient` gives for [failure] on a request to [uri], or
/// null for [FakeServerFailure.timeout] (which never completes).
Exception? fakeTransportException(FakeServerFailure failure, Uri uri) {
  SocketException socket(String message, OSError os) => SocketException(
    message,
    osError: os,
    address: InternetAddress('192.168.1.20'),
    port: uri.hasPort ? uri.port : 80,
  );
  return switch (failure) {
    FakeServerFailure.refused => FakeClientSocketException(
      socket('Connection refused', const OSError('Connection refused', 61)),
      uri,
    ),
    FakeServerFailure.hostLookup => FakeClientSocketException(
      SocketException(
        "Failed host lookup: '${uri.host}'",
        osError: const OSError(
          'nodename nor servname provided, or not known',
          8,
        ),
      ),
      uri,
    ),
    FakeServerFailure.networkUnreachable => FakeClientSocketException(
      socket(
        'Network is unreachable',
        const OSError('Network is unreachable', 51),
      ),
      uri,
    ),
    FakeServerFailure.drop => http.ClientException(
      'Connection closed before full header was received',
      uri,
    ),
    FakeServerFailure.timeout => null,
  };
}

class _Wi77Route {
  _Wi77Route(this.status, this.body, this.contentType);

  final int status;
  final String body;
  final String contentType;
}

/// Request headers that never decide which row answers. (A row's
/// `Authorization` header must match; a wrong token never reaches the rows.)
const _transportHeaders = {'content-type', 'content-length'};

class FakeVaultServer {
  FakeVaultServer({this.token = fakeServerToken, String url = fakeServerUrl})
    : url = Uri.parse(url);

  /// The server's access token. Change it to make the client's token wrong.
  String token;

  /// The saved server URL the fake answers under.
  final Uri url;

  /// While set, every request fails this way (recorded first).
  FakeServerFailure? failure;

  /// While true, the fake is not a memex server: every request answers
  /// 200 `text/html` [fakeHtmlBody], whatever the token.
  bool servesHtml = false;

  /// Every request the client sent, in order, failed ones included.
  final List<http.Request> requests = [];

  /// The client to hand to `HostedClient`.
  late final http.Client client = MockClient(_handle);

  /// WI #140: while true the server is an older `memex` (v0.6.0) without
  /// attachment routes: every `/attachments` request of a vault given to
  /// [serveAttachments] is the no-route 404, a body over 8 MiB is the 8 MiB
  /// 413 on every route (the upload included), and `/api/v1/info` reports
  /// `server_version` 0.6.0 (else 0.7.0).
  bool attachmentRoutesMissing = false;

  /// WI #140: the largest upload body; a larger one is the C1 413
  /// `payload_too_large` with the R15 text. 104,857,600 like the server;
  /// tests lower it instead of sending 100 MB.
  int attachmentUploadLimit = wi140UploadLimit;

  /// WI #140: while true an upload (`POST /attachments`) is recorded and
  /// never answered. Other requests answer.
  bool holdAttachmentUploads = false;

  /// WI #140: while true a `GET /attachments/…` is recorded and never
  /// answered. HEAD and other requests answer.
  bool holdAttachmentDownloads = false;

  final Map<String, Map<String, Uint8List>> _wi140Vaults = {};

  final List<FixtureRow> _rows = [];
  final Map<FixtureRow, int> _served = {};
  final Map<String, _Wi77Route> _routes = {};
  final Set<String> _goneVaults = {};
  Completer<void>? _gate;

  /// Serves every row of `test/fixtures/api_v1/<domain>/index.json`.
  void serveDomain(String domain) =>
      serveRows(loadFixtureRows(p.join(apiV1FixturesDir, domain)));

  /// Serves [rows]. A request takes the most specific matching row: same
  /// method, path and query, the row's request body (JSON compared decoded)
  /// and its headers other than `Content-Type` and `Content-Length`. Rows
  /// that match equally are served in order, the last one repeating. A
  /// `/vaults/<name>/…` request no row answers gets `vault_not_found` unless
  /// a 2xx row names that vault.
  void serveRows(Iterable<FixtureRow> rows) => _rows.addAll(rows);

  /// Answers [method] [path] (path and query, relative to [url]) with
  /// [status] and [json] (encoded) or [body]. Wins over fixture rows; a
  /// later call for the same route replaces it.
  void route(
    String method,
    String path, {
    int status = 200,
    Object? json,
    String? body,
    String contentType = 'application/json',
  }) {
    _routes['$method $path'] = _Wi77Route(
      status,
      body ?? jsonEncode(json),
      contentType,
    );
  }

  /// A `HostedClient` for this server in [container], whose overrides give
  /// `clockProvider` and `utcOffsetProvider`. [accessToken] defaults to the
  /// server's [token], [serverUrl] to [url].
  HostedClient connect(
    ProviderContainer container, {
    String serverId = fakeServerId,
    String serverName = fakeServerName,
    String? accessToken,
    String? serverUrl,
  }) {
    final provider = Provider<HostedClient>(
      (ref) => HostedClient(
        ref,
        serverId: serverId,
        serverName: serverName,
        serverUrl: serverUrl ?? url.toString(),
        accessToken: accessToken ?? token,
        httpClient: client,
      ),
    );
    return container.read(provider);
  }

  /// WI #140: [vault] serves the attachment routes (R40) from an in-memory
  /// store, empty at first. An upload stores its body under
  /// `objects/<h2>/<hash>/<name>` (a fake content hash: the same bytes give
  /// the same path) and answers `{markdown, path, name, size, type}`.
  void serveAttachments(String vault) =>
      _wi140Vaults.putIfAbsent(vault.toLowerCase(), () => {});

  /// WI #140: stores [bytes] at the decoded vault-relative [path] of
  /// [vault] (which then serves the attachment routes).
  void putAttachment(String vault, String path, List<int> bytes) {
    serveAttachments(vault);
    _wi140Vaults[vault.toLowerCase()]![path] = Uint8List.fromList(bytes);
  }

  /// WI #140: the bytes stored at [path] of [vault], or null.
  Uint8List? storedAttachment(String vault, String path) =>
      _wi140Vaults[vault.toLowerCase()]?[path];

  /// Every `/vaults/<name>/…` request answers 404 `vault_not_found`.
  void removeVault(String name) => _goneVaults.add(name.toLowerCase());

  /// Holds every later response until [release].
  void hold() => _gate ??= Completer<void>();

  /// Lets held responses through.
  void release() {
    _gate?.complete();
    _gate = null;
  }

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    final f = failure;
    if (f != null) {
      final e = fakeTransportException(f, request.url);
      if (e == null) return Completer<http.Response>().future;
      throw e;
    }
    final gate = _gate;
    if (gate != null) await gate.future;

    if (servesHtml) {
      return _response(request, 200, fakeHtmlBody, 'text/html');
    }
    if (request.headers['authorization'] != 'Bearer $token') {
      return _response(request, 401, _errorsFile('unauthorized.json'));
    }

    final path = _relativePath(request.url);
    final query = request.url.query;
    final key = '${request.method} $path${query.isEmpty ? '' : '?$query'}';
    final custom = _routes[key];
    if (custom != null) {
      return _response(request, custom.status, custom.body, custom.contentType);
    }

    final attachments = _wi140Handle(request, path);
    if (attachments != null) return attachments;

    final vault = _vaultName(path);
    if (vault != null && _goneVaults.contains(vault.toLowerCase())) {
      return _vaultNotFound(request, vault);
    }

    final row = _pickRow(request, path);
    if (row != null) {
      return _response(
        request,
        row.status,
        File(p.join(row.domainDir, row.response)).readAsStringSync(),
      );
    }
    if (vault != null && !_knownVaults().contains(vault.toLowerCase())) {
      return _vaultNotFound(request, vault);
    }
    return _response(request, 404, _errorsFile('not_found.json'));
  }

  String _relativePath(Uri requestUrl) {
    final base = url.path.endsWith('/')
        ? url.path.substring(0, url.path.length - 1)
        : url.path;
    final path = requestUrl.path;
    return path.startsWith(base) ? path.substring(base.length) : path;
  }

  static String? _vaultName(String path) {
    final segments = Uri(path: path).pathSegments;
    return segments.length >= 2 && segments.first == 'vaults'
        ? segments[1]
        : null;
  }

  Set<String> _knownVaults() => {
    for (final row in _rows)
      if (row.status ~/ 100 == 2)
        if (_vaultName(Uri.parse(row.path).path) case final name?)
          name.toLowerCase(),
  };

  FixtureRow? _pickRow(http.Request request, String path) {
    final candidates = <FixtureRow>[];
    var best = -1;
    for (final row in _rows) {
      final score = _matchScore(row, request, path);
      if (score == null) continue;
      if (score > best) {
        best = score;
        candidates.clear();
      }
      if (score == best) candidates.add(row);
    }
    if (candidates.isEmpty) return null;
    final row = candidates.firstWhere(
      (r) => (_served[r] ?? 0) == 0,
      orElse: () => candidates.last,
    );
    _served[row] = (_served[row] ?? 0) + 1;
    return row;
  }

  /// Null when [row] doesn't answer [request]; else how specific it is.
  int? _matchScore(FixtureRow row, http.Request request, String path) {
    if (row.method != request.method) return null;
    final rowUri = Uri.parse(row.path);
    if (rowUri.path != path) return null;
    if (!_sameQuery(rowUri.queryParameters, request.url.queryParameters)) {
      return null;
    }
    var score = 0;
    final expectedBody = row.readRequestBytes();
    if (expectedBody != null) {
      if (!_sameBody(expectedBody, request.bodyBytes, row.request!)) {
        return null;
      }
      score += 1;
    }
    for (final MapEntry(:key, :value) in row.headers.entries) {
      final name = key.toLowerCase();
      if (_transportHeaders.contains(name)) continue;
      if (request.headers[name] != value) return null;
      score += 1;
    }
    return score;
  }

  static bool _sameQuery(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  static bool _sameBody(List<int> expected, List<int> actual, String file) {
    if (file.endsWith('.json')) {
      try {
        return jsonEncode(_canonical(jsonDecode(utf8.decode(actual)))) ==
            jsonEncode(_canonical(jsonDecode(utf8.decode(expected))));
      } on FormatException {
        return false;
      }
    }
    if (expected.length != actual.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != actual[i]) return false;
    }
    return true;
  }

  /// [json] with every object's keys sorted, so key order never matters.
  static Object? _canonical(Object? json) => switch (json) {
    final Map<String, Object?> m => {
      for (final k in m.keys.toList()..sort()) k: _canonical(m[k]),
    },
    final List<Object?> l => [for (final e in l) _canonical(e)],
    _ => json,
  };

  http.Response _vaultNotFound(http.Request request, String vault) => _response(
    request,
    404,
    jsonEncode({
      'error': {'code': 'vault_not_found', 'message': 'no vault named $vault'},
    }),
  );

  static String _errorsFile(String name) =>
      File(p.join(apiV1FixturesDir, 'errors', name)).readAsStringSync();

  /// WI #140: the attachment routes, the 8 MiB body limit and the built-in
  /// `/api/v1/info`, or null when none of them answers [request].
  Future<http.Response>? _wi140Handle(http.Request request, String path) {
    if (_wi140Vaults.isEmpty && !attachmentRoutesMissing) return null;
    final segments = Uri(path: path).pathSegments;
    final vault = _vaultName(path)?.toLowerCase();
    final isAttachmentRoute =
        segments.length >= 5 &&
        segments[2] == 'api' &&
        segments[3] == 'v1' &&
        segments[4] == 'attachments' &&
        vault != null &&
        _wi140Vaults.containsKey(vault);
    final isUpload =
        isAttachmentRoute && segments.length == 5 && request.method == 'POST';
    final size = request.bodyBytes.length;
    if (size > wi140BodyLimit && (attachmentRoutesMissing || !isUpload)) {
      return Future.value(
        _response(request, 413, _errorsFile('payload_too_large.json')),
      );
    }
    if (request.method == 'GET' && path == '/api/v1/info') {
      return Future.value(
        _response(
          request,
          200,
          jsonEncode({
            'api_version': kApiVersion,
            'server_version': attachmentRoutesMissing ? '0.6.0' : '0.7.0',
          }),
        ),
      );
    }
    if (!isAttachmentRoute) return null;
    if (attachmentRoutesMissing) {
      return Future.value(
        _response(request, 404, _errorsFile('not_found.json')),
      );
    }
    final store = _wi140Vaults[vault]!;
    if (isUpload) {
      final name = request.url.queryParameters['name'] ?? '';
      if (size > attachmentUploadLimit) {
        return Future.value(
          _wi140Error(
            request,
            413,
            'payload_too_large',
            "$name is larger than 100 MB and wasn't attached.",
          ),
        );
      }
      if (holdAttachmentUploads) return Completer<http.Response>().future;
      final hash = _wi140Hash(request.bodyBytes);
      final stored = 'objects/${hash.substring(0, 2)}/$hash/$name';
      store[stored] = Uint8List.fromList(request.bodyBytes);
      return Future.value(
        _response(
          request,
          200,
          jsonEncode({
            'markdown': attachmentMarkdown(name, hash),
            'path': stored,
            'name': name,
            'size': size,
            'type': _wi140Mime(name),
          }),
        ),
      );
    }
    if (segments.length == 5 ||
        (request.method != 'GET' && request.method != 'HEAD')) {
      return Future.value(
        _response(request, 404, _errorsFile('not_found.json')),
      );
    }
    final rest = segments.sublist(5).join('/');
    final target =
        parseAttachmentPath(rest) ?? parseAttachmentDestination(rest);
    if (target == null) {
      return Future.value(
        _wi140Error(
          request,
          400,
          'invalid_argument',
          '$rest is not an attachment path',
        ),
      );
    }
    if (request.method == 'GET' && holdAttachmentDownloads) {
      return Completer<http.Response>().future;
    }
    final bytes = store[target.path];
    if (bytes == null) {
      return Future.value(
        _wi140Error(
          request,
          404,
          'not_found',
          'not found: attachment ${target.path}',
        ),
      );
    }
    return Future.value(
      _bytesResponse(request, 200, bytes, _wi140Mime(target.name)),
    );
  }

  http.Response _wi140Error(
    http.Request request,
    int status,
    String code,
    String message,
  ) => _response(
    request,
    status,
    jsonEncode({
      'error': {'code': code, 'message': message},
    }),
  );

  /// A fake content hash of [bytes]: 64 lowercase hex characters (FNV-1a
  /// repeated), the same for the same bytes.
  static String _wi140Hash(List<int> bytes) {
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h ^= b;
      h *= 0x100000001b3;
    }
    String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
    final hex = half(h >> 32) + half(h);
    return hex * 4;
  }

  static String _wi140Mime(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'pdf' => 'application/pdf',
      'txt' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  static http.Response _response(
    http.Request request,
    int status,
    String body, [
    String contentType = 'application/json',
  ]) => _bytesResponse(request, status, utf8.encode(body), contentType);

  /// [body] with its `Content-Type` and `Content-Length`. A HEAD answer keeps
  /// the headers and drops the body, as a real server does.
  static http.Response _bytesResponse(
    http.Request request,
    int status,
    List<int> body,
    String contentType,
  ) => http.Response.bytes(
    request.method == 'HEAD' ? const <int>[] : body,
    status,
    request: request,
    headers: {'content-type': contentType, 'content-length': '${body.length}'},
  );
}

/// WI #140: the upload route's body limit (R15), 104,857,600 bytes.
const wi140UploadLimit = 104857600;

/// WI #140: every other route's body limit, 8 MiB (8,388,608 bytes).
const wi140BodyLimit = 8388608;
