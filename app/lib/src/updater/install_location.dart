import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';

// Skeleton (#34 red): A2 #34 fills this file and keeps each `defaultX(Ref)`.

/// The production [InstallLocationCheck] behind
/// `installLocationCheckProvider`: resolves the enclosing `.app` bundle from
/// `resolvedExecutableProvider` and probes its parent folder with
/// `folderWritableProvider` (req 24).
InstallLocationCheck defaultInstallLocationCheck(Ref ref) =>
    const _InstallLocationCheck();

/// The production executable path behind `resolvedExecutableProvider`
/// (`Platform.resolvedExecutable`).
String defaultResolvedExecutable(Ref ref) => '';

/// The production writability probe behind `folderWritableProvider`: creates
/// and deletes a file in the folder; false when either fails (D6).
FolderWritable defaultFolderWritable(Ref ref) => _neverWritable;

Future<bool> _neverWritable(String folder) async => false;

class _InstallLocationCheck implements InstallLocationCheck {
  const _InstallLocationCheck();

  @override
  Future<String> check() async => '';
}
