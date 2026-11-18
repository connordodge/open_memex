import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'appcast.dart';
import 'update_ports.dart';
import 'update_seams.dart';

// Skeleton (test author, #33). A1 #33 fills this file and keeps each
// `defaultX(Ref)`.

/// The permanent Appcast URL built into every Self-update build (req 1).
const permanentAppcastUrl =
    'https://connordodge.github.io/open_memex/appcast.xml';

/// The Appcast URL for the `SELF_UPDATE_APPCAST_URL` define value [define]:
/// [define] when it is non-empty, otherwise [permanentAppcastUrl] (D18).
Uri appcastUrlFor(String define) => Uri();

/// The [AppcastFetcher] over HTTP: GETs [url] with a client from
/// [clientFactory] and parses the body with `parseAppcast`.
class HttpAppcastFetcher implements AppcastFetcher {
  HttpAppcastFetcher({required this.clientFactory, required this.url});

  final UpdateHttpClientFactory clientFactory;
  final Uri url;

  @override
  Future<List<AppcastItem>> fetch() => Future.value(const <AppcastItem>[]);
}

/// The production [AppcastFetcher] behind `appcastFetcherProvider`.
AppcastFetcher defaultAppcastFetcher(Ref ref) => HttpAppcastFetcher(
  clientFactory: ref.watch(updateHttpClientFactoryProvider),
  url: Uri(),
);

/// The production client factory behind `updateHttpClientFactoryProvider`.
UpdateHttpClientFactory defaultUpdateHttpClientFactory(Ref ref) =>
    throw UnimplementedError();
