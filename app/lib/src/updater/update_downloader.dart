import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'appcast.dart';
import 'update_ports.dart';
import 'update_seams.dart';

// Skeleton (test author, #33). A1 #33 fills this file and keeps each
// `defaultX(Ref)`.

/// The [UpdateDownloader] over HTTP: streams an item's enclosure with a
/// client from [clientFactory] into [directory], which it creates with mode
/// 0700.
class HttpUpdateDownloader implements UpdateDownloader {
  HttpUpdateDownloader({required this.clientFactory, required this.directory});

  final UpdateHttpClientFactory clientFactory;

  /// The update download directory.
  final String directory;

  @override
  Future<String> download(
    AppcastItem item, {
    void Function(double? progress)? onProgress,
  }) => Future.value('');

  @override
  Future<void> deleteLeftovers() => Future.value();
}

/// The production [UpdateDownloader] behind `updateDownloaderProvider`.
UpdateDownloader defaultUpdateDownloader(Ref ref) => HttpUpdateDownloader(
  clientFactory: ref.watch(updateHttpClientFactoryProvider),
  directory: ref.watch(updateDownloadDirProvider),
);

/// The production update download directory behind
/// `updateDownloadDirProvider`. Computing it must not touch the file system.
String defaultUpdateDownloadDir(Ref ref) => '';
