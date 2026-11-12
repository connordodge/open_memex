// The Connect tab's state (#411). The Connect chip has no badge, so the
// shell needs nothing from this file; #411 owns it.
//
// Nothing here holds an access token (Spec #394 req 27): the token lives
// only in the Connect tab's State while revealed.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../agents_sheet/connect/claude_config_reader.dart';
import '../vault_ref.dart';

/// The user's home directory (`$HOME`), or `''` when it is unset. Claude
/// Desktop's config file lives under it, and the detection line expands a
/// `~` path against it (Spec #394 req 29).
String claudeHomeDirectory() => Platform.environment['HOME'] ?? '';

/// Reads Claude Desktop's config file for the Connect tab's detection line
/// (Spec #394 req 13, 29). The default reads, read-only, under the real home
/// directory; tests override it with `FakeClaudeConfigReader`.
final claudeConfigReaderProvider = Provider<ClaudeConfigReader>(
  (ref) => FileClaudeConfigReader(homeDirectory: claudeHomeDirectory()),
);

/// One Claude Desktop config read at a time across every Connect tab
/// (Spec #394 req 13, AC 12). The config file is the same for every vault,
/// so a read asked for while one is in flight, by this tab or a remounted
/// one (another tab shown and Connect shown again, or the sheet closed and
/// reopened), joins that read instead of starting a second.
class ClaudeConfigReads {
  ClaudeConfigReads(this._reader);

  final ClaudeConfigReader _reader;
  Future<ClaudeConfigRead>? _inFlight;

  /// The in-flight read, or a new one when none is in flight.
  Future<ClaudeConfigRead> read() {
    if (_inFlight case final pending?) return pending;
    final started = _reader.read();
    _inFlight = started;
    // Clear on either outcome; the callers see the error, this does not.
    started.then<void>(
      (_) => _clear(started),
      onError: (Object _) => _clear(started),
    );
    return started;
  }

  void _clear(Future<ClaudeConfigRead> finished) {
    if (identical(_inFlight, finished)) _inFlight = null;
  }
}

/// The shared [ClaudeConfigReads] over [claudeConfigReaderProvider].
final claudeConfigReadsProvider = Provider<ClaudeConfigReads>(
  (ref) => ClaudeConfigReads(ref.watch(claudeConfigReaderProvider)),
);

/// Whether the memex binary at [path] sits on a path that changes between
/// launches: one containing `/AppTranslocation/` or starting with
/// `/Volumes/` (Spec #394 req 15).
bool isUnstableMemexPath(String path) =>
    path.contains('/AppTranslocation/') || path.startsWith('/Volumes/');

/// Whether [path] is the Bundled memex,
/// `<Open Memex.app>/Contents/MacOS/memex` (Spec #394 req 23): a `memex`
/// file in the `Contents/MacOS` folder of an `.app` bundle.
bool isBundledMemexPath(String path) {
  final parts = p.posix.split(path);
  if (parts.length < 4) return false;
  final [..., app, contents, macOs, binary] = parts;
  return binary == 'memex' &&
      macOs == 'MacOS' &&
      contents == 'Contents' &&
      app.endsWith('.app');
}

/// The Connect tab's two clients (Spec #394 req 22).
enum ConnectClient { claudeDesktop, claudeCode }

/// The client the Connect tab shows for each vault, remembered for the
/// session in memory only (never SharedPreferences). Starts on
/// [ConnectClient.claudeDesktop].
final connectClientProvider = StateProvider.family<ConnectClient, VaultRef>(
  (ref, _) => ConnectClient.claudeDesktop,
);
