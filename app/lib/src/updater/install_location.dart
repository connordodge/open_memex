import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_ports.dart';
import 'update_seams.dart';
import 'update_state.dart';

/// The production [InstallLocationCheck] behind
/// `installLocationCheckProvider`: resolves the enclosing `.app` bundle from
/// `resolvedExecutableProvider` and probes its parent folder with
/// `folderWritableProvider` (req 24).
InstallLocationCheck defaultInstallLocationCheck(Ref ref) =>
    _InstallLocationCheck(ref);

/// The production executable path behind `resolvedExecutableProvider`
/// (`Platform.resolvedExecutable`).
String defaultResolvedExecutable(Ref ref) => Platform.resolvedExecutable;

/// The production writability probe behind `folderWritableProvider`: creates
/// and deletes a file in the folder; false when either fails (D6).
FolderWritable defaultFolderWritable(Ref ref) => _probeWritable;

Future<bool> _probeWritable(String folder) async {
  final probe = File('$folder/.open-memex-write-probe-$pid');
  try {
    await probe.writeAsString('', flush: true);
    await probe.delete();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// The innermost `.app` bundle enclosing [executable], or null when no path
/// segment ends in `.app`.
String? _enclosingBundle(String executable) {
  final segments = executable.split('/');
  for (var i = segments.length - 1; i >= 0; i--) {
    if (segments[i].endsWith('.app')) {
      return segments.sublist(0, i + 1).join('/');
    }
  }
  return null;
}

/// The folder holding [path] (`/` for a top-level entry).
String _parentOf(String path) {
  final cut = path.lastIndexOf('/');
  return cut <= 0 ? '/' : path.substring(0, cut);
}

class _InstallLocationCheck implements InstallLocationCheck {
  const _InstallLocationCheck(this._ref);

  final Ref _ref;

  @override
  Future<String> check() async {
    final executable = _ref.read(resolvedExecutableProvider);
    final bundle = _enclosingBundle(executable);
    if (bundle == null) {
      // Not inside an app bundle: nothing the helper could replace.
      throw UpdateFailure(
        UpdateErrorCause.folderNotWritable,
        folder: _parentOf(executable),
      );
    }
    if (bundle.startsWith('/Volumes/') ||
        bundle.contains('/AppTranslocation/')) {
      throw const UpdateFailure(UpdateErrorCause.diskImage);
    }
    final folder = _parentOf(bundle);
    if (!await _ref.read(folderWritableProvider)(folder)) {
      throw UpdateFailure(UpdateErrorCause.folderNotWritable, folder: folder);
    }
    return bundle;
  }
}
