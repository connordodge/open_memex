import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_support_dir.dart';
import 'update_ports.dart';
import 'update_seams.dart';

/// The five fixed reasons the install helper writes to the marker (req 26),
/// verbatim. Any other marker text is cleared and ignored (D8).
const installFailureReasons = [
  "the disk image couldn't be opened",
  "the new app couldn't be copied",
  "the new app's signature didn't verify",
  "the new app couldn't be moved into place",
  "the app didn't quit in time",
];

/// The production [FailureMarkerStore] behind `failureMarkerStoreProvider`:
/// reads and clears the file at `failureMarkerFileProvider` (D8).
FailureMarkerStore defaultFailureMarkerStore(Ref ref) =>
    _FailureMarkerStore(ref);

/// The production marker path behind `failureMarkerFileProvider`
/// (`<appSupportDir>/self_update_failure`). Computing it must not touch the
/// file system.
String defaultFailureMarkerFile(Ref ref) =>
    '${ref.watch(appSupportDirProvider)}/self_update_failure';

class _FailureMarkerStore implements FailureMarkerStore {
  const _FailureMarkerStore(this._ref);

  final Ref _ref;

  @override
  Future<String?> take() async {
    final file = File(_ref.read(failureMarkerFileProvider));
    final String text;
    try {
      text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } on FileSystemException {
      // No marker: no failure.
      return null;
    }
    try {
      await file.delete();
    } on FileSystemException {
      // Best effort; the reason still shows this once.
    }
    final reason = text.trim();
    return installFailureReasons.contains(reason) ? reason : null;
  }
}
