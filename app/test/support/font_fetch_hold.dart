// Shared test seam: hold google_fonts' HTTP font fetches so they never
// answer. Used by #96's hosted open-path tests and #97's vault picker tests.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// google_fonts fetches OmType's fonts over HTTP. The test binding answers
/// every request with a 400, and the font load's failure lands in whichever
/// test is running when a `runAsync` or a real-async test lets that request
/// finish (e.g. a test that renders the editor). Call once at the top of
/// `main()`: font requests then never answer, the fallback test font stays,
/// and no error reaches a test zone. Setting
/// `GoogleFonts.config.allowRuntimeFetching = false` does not help: it throws
/// in the same place instead. App HTTP goes through
/// `hostedHttpClientProvider` (a MockClient), never through `HttpClient`.
void holdFontFetches() {
  HttpOverrides? previous;
  setUpAll(() {
    previous = HttpOverrides.current;
    HttpOverrides.global = _HeldFontHttpOverrides();
  });
  tearDownAll(() => HttpOverrides.global = previous);
}

class _HeldFontHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _HeldHttpClient();
}

/// An [HttpClient] whose requests never open.
class _HeldHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Completer<HttpClientRequest>().future;

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
