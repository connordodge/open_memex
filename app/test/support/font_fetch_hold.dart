// Shared test seam: hold google_fonts' HTTP font fetches so they never
// answer. Used by #96's hosted open-path tests and #97's vault picker tests.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:google_fonts/src/google_fonts_base.dart' show assetManifest;

/// Keeps widget tests on the flutter_test fallback font. OmType's fonts are
/// bundled under `assets/google_fonts/` (#373), and google_fonts looks in the
/// asset manifest before it would fetch, so with the real manifest any test
/// that lets a font load finish would lay text out in the real Inter Tight,
/// JetBrains Mono or Newsreader, and every width tuned to the fallback font
/// would move. This hands google_fonts an empty asset manifest (its own
/// `assetManifest` test hook), so nothing resolves from the bundle, and
/// holds the HTTP request google_fonts then makes so it never answers: the
/// fallback font stays and no failure reaches a test zone. Call once at the
/// top of `main()`; both overrides are undone after the file's last test.
/// Tests of the bundled fonts themselves (`theme/font_setup_test.dart`) do
/// not call it. App HTTP goes through `hostedHttpClientProvider` (a
/// MockClient), never through `HttpClient`.
void holdFontFetches() {
  HttpOverrides? previous;
  AssetManifest? previousManifest;
  setUpAll(() {
    previous = HttpOverrides.current;
    HttpOverrides.global = _HeldFontHttpOverrides();
    previousManifest = assetManifest;
    assetManifest = _EmptyAssetManifest();
  });
  tearDownAll(() {
    HttpOverrides.global = previous;
    assetManifest = previousManifest;
  });
}

/// An asset manifest that lists nothing, so google_fonts finds no bundled font.
class _EmptyAssetManifest implements AssetManifest {
  @override
  List<String> listAssets() => const [];

  @override
  List<AssetMetadata>? getAssetVariants(String key) => null;
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
