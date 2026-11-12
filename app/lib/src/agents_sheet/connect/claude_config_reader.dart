// WI #404 (Spec #394 req 29): the read-only seam over Claude Desktop's
// config file. Never writes, never logs the file's text.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The largest config file read, in bytes (1 MB). A larger file is
/// [ClaudeConfigOversized].
const int claudeConfigMaxBytes = 1024 * 1024;

/// One read of Claude Desktop's config file.
sealed class ClaudeConfigRead {
  const ClaudeConfigRead();
}

/// The file's text.
final class ClaudeConfigContents extends ClaudeConfigRead {
  const ClaudeConfigContents(this.contents);

  final String contents;
}

/// No file at the path.
final class ClaudeConfigMissing extends ClaudeConfigRead {
  const ClaudeConfigMissing();
}

/// The file exists but can't be read as UTF-8 text.
final class ClaudeConfigUnreadable extends ClaudeConfigRead {
  const ClaudeConfigUnreadable();
}

/// The file is over [claudeConfigMaxBytes]; it isn't read.
final class ClaudeConfigOversized extends ClaudeConfigRead {
  const ClaudeConfigOversized();
}

/// Reads Claude Desktop's config file. Tests use a fake
/// (`test/support/claude_config_reader_fakes.dart`).
abstract interface class ClaudeConfigReader {
  Future<ClaudeConfigRead> read();
}

/// The default reader, read-only:
/// `<home>/Library/Application Support/Claude/claude_desktop_config.json`.
class FileClaudeConfigReader implements ClaudeConfigReader {
  /// [homeDirectory] is the user's home; tests pass a temp directory so the
  /// real `~/Library` is never read.
  FileClaudeConfigReader({required this.homeDirectory});

  final String homeDirectory;

  /// The absolute path read.
  String get path => p.join(
    homeDirectory,
    'Library',
    'Application Support',
    'Claude',
    'claude_desktop_config.json',
  );

  /// Opens the file for reading only; never creates, writes or logs.
  @override
  Future<ClaudeConfigRead> read() async {
    final path = this.path;
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      return const ClaudeConfigMissing();
    }
    if (type != FileSystemEntityType.file) {
      return const ClaudeConfigUnreadable();
    }
    try {
      final file = File(path);
      if (await file.length() > claudeConfigMaxBytes) {
        return const ClaudeConfigOversized();
      }
      return ClaudeConfigContents(utf8.decode(await file.readAsBytes()));
    } on FileSystemException {
      return const ClaudeConfigUnreadable();
    } on FormatException {
      // Invalid UTF-8; the message holds file bytes, so it is dropped.
      return const ClaudeConfigUnreadable();
    }
  }
}

/// [path] with symlinks resolved, or [path] unchanged when it can't be
/// resolved (it doesn't exist). The default resolver for
/// `detectClaudeDesktopSetup`.
String resolveSymlinksOrSelf(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return path;
  }
}
