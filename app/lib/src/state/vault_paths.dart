import 'dart:io';

import 'package:path/path.dart' as p;

/// Whether the folder paths [a] and [b] name the same vault folder.
///
/// Recents store a vault's path as it was opened (from the folder chooser,
/// the create dialog's join or a restore), so one folder can have more than
/// one spelling. Both paths are made absolute and normalized (`.` and `..`
/// segments and a trailing separator go), symlinks are resolved when the
/// folder exists (a path that can't be resolved stays as normalized), and
/// the result is compared ignoring case: the default macOS volume is
/// case-insensitive.
bool isSameVaultFolder(String a, String b) =>
    _canonicalFolder(a) == _canonicalFolder(b);

String _canonicalFolder(String path) {
  var normalized = p.normalize(p.absolute(path));
  if (normalized.length > 1 && normalized.endsWith(p.separator)) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  var resolved = normalized;
  try {
    final dir = Directory(normalized);
    if (dir.existsSync()) resolved = dir.resolveSymbolicLinksSync();
  } on FileSystemException {
    resolved = normalized;
  }
  return resolved.toLowerCase();
}
