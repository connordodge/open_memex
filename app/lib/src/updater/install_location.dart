import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';

// Stub (A0 #32). A2 #34 fills this file and keeps each `defaultX(Ref)`.

/// The production [InstallLocationCheck] behind
/// `installLocationCheckProvider`.
InstallLocationCheck defaultInstallLocationCheck(Ref ref) =>
    throw UnimplementedError();

/// The production executable path behind `resolvedExecutableProvider`.
String defaultResolvedExecutable(Ref ref) => '';

/// The production writability probe behind `folderWritableProvider`.
FolderWritable defaultFolderWritable(Ref ref) => throw UnimplementedError();
