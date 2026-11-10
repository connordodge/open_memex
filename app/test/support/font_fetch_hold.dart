// Shared test seam: hold google_fonts' HTTP font fetches so they never
// answer. Used by #96's hosted open-path tests and #97's vault picker tests.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// OmType's fonts are bundled under `assets/google_fonts/` (#373), and
/// google_fonts loads a bundled font before it would ever fetch, so tests
/// make no font request and this hold normally sees none. It stays as a
/// guard: if a font OmType asks for were ever missing from the bundle,
/// google_fonts would fetch it over HTTP, the test binding would answer
/// with a 400, and the failure would land in whichever test is running when
/// a `runAsync` or a real-async test lets that request finish. Call once at
/// the top of `main()`: font requests then never answer and no error reaches
/// a test zone. App HTTP goes through `hostedHttpClientProvider` (a
/// MockClient), never through `HttpClient`.
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
