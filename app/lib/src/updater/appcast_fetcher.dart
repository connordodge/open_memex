import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'appcast.dart';
import 'update_ports.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The permanent Appcast URL built into every Self-update build (req 1).
const permanentAppcastUrl =
    'https://connordodge.github.io/open_memex/appcast.xml';

/// The `--dart-define=SELF_UPDATE_APPCAST_URL=<url>` value; empty when the
/// build defines none (D18).
const _appcastUrlDefine = String.fromEnvironment('SELF_UPDATE_APPCAST_URL');

/// The Appcast URL for the `SELF_UPDATE_APPCAST_URL` define value [define]:
/// [define] when it is non-empty, otherwise [permanentAppcastUrl] (D18).
///
/// A [define] that is not a URI gives the empty URI, which the fetcher
/// refuses as [UpdateErrorCause.feedUnreadable] instead of throwing here.
Uri appcastUrlFor(String define) => define.isEmpty
    ? Uri.parse(permanentAppcastUrl)
    : Uri.tryParse(define) ?? Uri();

/// Whether [url] is one the HTTP client can GET: an http or https URL with a
/// host.
bool _fetchable(Uri url) =>
    (url.isScheme('http') || url.isScheme('https')) && url.host.isNotEmpty;

/// The [AppcastFetcher] over HTTP: GETs [url] with a client from
/// [clientFactory] and parses the body with `parseAppcast`.
///
/// Each fetch takes a new client from [clientFactory] and closes it when the
/// fetch ends. A fetch that has no full answer within [timeout] fails with
/// [UpdateErrorCause.offline]. A [url] that is not http or https with a host
/// (only reachable through the D18 override) fails with
/// [UpdateErrorCause.feedUnreadable] before any request.
class HttpAppcastFetcher implements AppcastFetcher {
  HttpAppcastFetcher({
    required this.clientFactory,
    required this.url,
    this.timeout = const Duration(seconds: 30),
  });

  final UpdateHttpClientFactory clientFactory;
  final Uri url;

  /// How long the request and its body may take before the fetch fails
  /// offline.
  final Duration timeout;

  @override
  Future<List<AppcastItem>> fetch() async {
    if (!_fetchable(url)) {
      throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
    }
    final client = clientFactory();
    try {
      final http.Response response;
      try {
        response = await client.get(url).timeout(timeout);
      } on IOException {
        throw const UpdateFailure(UpdateErrorCause.offline);
      } on http.ClientException {
        throw const UpdateFailure(UpdateErrorCause.offline);
      } on TimeoutException {
        throw const UpdateFailure(UpdateErrorCause.offline);
      } on ArgumentError {
        // A URL the HTTP client refuses to open; never a raw error (D1).
        throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
      }
      final status = response.statusCode;
      if (status == 404) {
        throw const UpdateFailure(UpdateErrorCause.noAppcast);
      }
      if (status < 200 || status > 299) {
        throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
      }
      return parseAppcast(_decodeUtf8(response.bodyBytes));
    } finally {
      client.close();
    }
  }
}

/// [bytes] as UTF-8, whatever charset the response names (the Appcast is
/// UTF-8 XML). Bytes that are not UTF-8 make the feed unreadable.
String _decodeUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw const UpdateFailure(UpdateErrorCause.feedUnreadable);
  }
}

/// The production [AppcastFetcher] behind `appcastFetcherProvider`.
AppcastFetcher defaultAppcastFetcher(Ref ref) => HttpAppcastFetcher(
  clientFactory: ref.watch(updateHttpClientFactoryProvider),
  url: appcastUrlFor(_appcastUrlDefine),
);

/// The production client factory behind `updateHttpClientFactoryProvider`:
/// a new [http.Client] on each call.
UpdateHttpClientFactory defaultUpdateHttpClientFactory(Ref ref) =>
    http.Client.new;
