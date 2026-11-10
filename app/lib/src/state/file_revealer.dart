import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Runs [executable] with [arguments] (the shape of `Process.run`), so the
/// default [FileRevealer] can be tested without launching anything.
typedef FileProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Shows a file or folder in Finder, selected (Spec #357 TD4).
abstract interface class FileRevealer {
  /// Reveals [path] in Finder.
  Future<void> reveal(String path);
}

/// The default [FileRevealer]: runs `/usr/bin/open -R <path>` (the macOS
/// app isn't sandboxed) through [run], `Process.run` by default.
class SystemFileRevealer implements FileRevealer {
  SystemFileRevealer({FileProcessRunner? run}) : _run = run ?? Process.run;

  final FileProcessRunner _run;

  @override
  Future<void> reveal(String path) async {
    await _run('/usr/bin/open', ['-R', path]);
  }
}

/// The app's [FileRevealer]. Tests override it with a fake.
final fileRevealerProvider = Provider<FileRevealer>(
  (ref) => SystemFileRevealer(),
);
