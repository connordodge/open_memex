import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'appcast.dart';
import 'update_ports.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The update download directory's name under the system temp directory.
const updateDownloadDirName = 'open-memex-update';

/// The downloaded DMG's file name in the update download directory.
const updateDmgFileName = 'Open-Memex-update.dmg';

/// The [UpdateDownloader] over HTTP: streams an item's enclosure with a
/// client from [clientFactory] into [directory], which it creates with mode
/// 0700.
///
/// Each download takes a new client from [clientFactory] and closes it when
/// the download ends. A download that receives no bytes for [idleTimeout]
/// fails like a connection lost mid-stream.
class HttpUpdateDownloader implements UpdateDownloader {
  HttpUpdateDownloader({
    required this.clientFactory,
    required this.directory,
    this.idleTimeout = const Duration(seconds: 60),
  });

  final UpdateHttpClientFactory clientFactory;

  /// The update download directory.
  final String directory;

  /// How long the download may go without receiving a byte (reset on every
  /// chunk; not a limit on the whole download).
  final Duration idleTimeout;

  @override
  Future<String> download(
    AppcastItem item, {
    void Function(double? progress)? onProgress,
  }) async {
    http.Client? client;
    File? file;
    IOSink? sink;
    try {
      await _prepareDirectory();
      client = clientFactory();
      final request = http.Request('GET', Uri.parse(item.url));
      final response = await client.send(request).timeout(idleTimeout);
      final status = response.statusCode;
      if (status < 200 || status > 299) {
        throw const UpdateFailure(UpdateErrorCause.downloadFailed);
      }
      final contentLength = _positive(response.contentLength);
      final total = contentLength ?? _positive(item.length);
      file = File(p.join(directory, updateDmgFileName));
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(total == null ? null : min(1.0, received / total));
      }
      await sink.close();
      sink = null;
      if (contentLength != null && received != contentLength) {
        throw const UpdateFailure(UpdateErrorCause.downloadFailed);
      }
      return file.path;
    } on UpdateFailure {
      await _discard(sink, file);
      rethrow;
    } on Exception {
      await _discard(sink, file);
      throw const UpdateFailure(UpdateErrorCause.downloadFailed);
    } on ArgumentError {
      // An enclosure URL the HTTP client can't send (e.g. no http scheme).
      await _discard(sink, file);
      throw const UpdateFailure(UpdateErrorCause.downloadFailed);
    } finally {
      client?.close();
    }
  }

  /// Creates [directory] when missing and sets its mode to 0700, also when
  /// it already existed.
  ///
  /// Refuses (as [UpdateErrorCause.downloadFailed]) a [directory] directly
  /// under the shared `/tmp`, and a [directory] that is a symbolic link,
  /// whose target another user could swap between the check and the write.
  Future<void> _prepareDirectory() async {
    if (_isSharedTemp(p.dirname(p.normalize(p.absolute(directory))))) {
      throw const UpdateFailure(UpdateErrorCause.downloadFailed);
    }
    await Directory(directory).create(recursive: true);
    final type = await FileSystemEntity.type(directory, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const UpdateFailure(UpdateErrorCause.downloadFailed);
    }
    final chmod = await Process.run('/bin/chmod', ['700', directory]);
    if (chmod.exitCode != 0) {
      throw const UpdateFailure(UpdateErrorCause.downloadFailed);
    }
  }

  @override
  Future<void> deleteLeftovers() async {
    final dir = Directory(directory);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort: a directory that can't be deleted now is retried at
      // the next launch, and never blocks it.
    }
  }
}

/// [n] when it is a positive length; null for none, zero or negative.
int? _positive(int? n) => n != null && n > 0 ? n : null;

/// Closes [sink] and deletes [file], ignoring IO errors: a failed download
/// leaves no partial file behind.
Future<void> _discard(IOSink? sink, File? file) async {
  try {
    await sink?.close();
  } on Exception {
    // The sink already failed; the file is deleted below.
  }
  if (file == null) return;
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Nothing more to do; the next launch deletes the directory.
  }
}

/// The production [UpdateDownloader] behind `updateDownloaderProvider`.
UpdateDownloader defaultUpdateDownloader(Ref ref) => HttpUpdateDownloader(
  clientFactory: ref.watch(updateHttpClientFactoryProvider),
  directory: ref.watch(updateDownloadDirProvider),
);

/// The production update download directory behind
/// `updateDownloadDirProvider`: `<Directory.systemTemp>/open-memex-update`
/// (the per-user temp directory, never `/tmp`; see [updateDownloadDirFor]).
/// Computing it does not touch the file system; it runs `getconf` only when
/// the system temp directory is `/tmp`.
String defaultUpdateDownloadDir(Ref ref) => updateDownloadDirFor(
  Directory.systemTemp.path,
  userTempDir: _darwinUserTempDir,
);

/// The update download directory for the system temp directory [systemTemp]:
/// `<systemTemp>/open-memex-update`, unless [systemTemp] is the shared `/tmp`
/// (TMPDIR unset). Then it is `<userTempDir()>/open-memex-update`, the
/// per-user temp directory, when [userTempDir] gives one; otherwise it stays
/// under `/tmp`, which the downloader refuses.
String updateDownloadDirFor(
  String systemTemp, {
  required String? Function() userTempDir,
}) {
  if (_isSharedTemp(systemTemp)) {
    final user = userTempDir();
    if (user != null && user.isNotEmpty && !_isSharedTemp(user)) {
      return p.join(p.normalize(user), updateDownloadDirName);
    }
  }
  return p.join(systemTemp, updateDownloadDirName);
}

/// Whether [path] is the shared, world-writable `/tmp` (or its macOS target
/// `/private/tmp`).
bool _isSharedTemp(String path) {
  final normal = p.normalize(path);
  return normal == '/tmp' || normal == '/private/tmp';
}

/// The per-user temp directory from `getconf DARWIN_USER_TEMP_DIR`; null
/// when it can't be read.
String? _darwinUserTempDir() {
  try {
    final result = Process.runSync('/usr/bin/getconf', [
      'DARWIN_USER_TEMP_DIR',
    ]);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  } on ProcessException {
    return null;
  }
}
