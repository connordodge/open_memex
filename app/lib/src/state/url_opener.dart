import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runs [executable] with [arguments] (the shape of `Process.run`), so the
/// default [UrlOpener] can be tested without launching anything.
typedef UrlProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Opens a link's URL outside the app (D14). Live preview Cmd+click calls it
/// only for `http`, `https` and `mailto` URLs.
abstract interface class UrlOpener {
  /// Opens [url], exactly as written in the link.
  Future<void> open(String url);
}

/// The default [UrlOpener]: runs `/usr/bin/open <url>` (the macOS app isn't
/// sandboxed) through [run], `Process.run` by default.
class SystemUrlOpener implements UrlOpener {
  SystemUrlOpener({UrlProcessRunner? run}) : _run = run ?? Process.run;

  // ignore: unused_field
  final UrlProcessRunner _run;

  @override
  Future<void> open(String url) => throw UnimplementedError();
}

/// The app's [UrlOpener]. Tests override it with a fake.
final urlOpenerProvider = Provider<UrlOpener>((ref) => SystemUrlOpener());
