import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';

// Stub (A0 #32). A1 #33 fills this file and keeps each `defaultX(Ref)`.

/// The production [UpdateDownloader] behind `updateDownloaderProvider`.
UpdateDownloader defaultUpdateDownloader(Ref ref) => throw UnimplementedError();

/// The production update download directory behind
/// `updateDownloadDirProvider`. Computing it must not touch the file system.
String defaultUpdateDownloadDir(Ref ref) => '';
