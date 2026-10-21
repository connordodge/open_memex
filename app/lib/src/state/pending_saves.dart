import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One hosted note whose editor save couldn't reach the vault server
/// (unreachable, timed out or `401`; Req 50, L16). It stays queued, with
/// its latest text, until a retry saves it.
class PendingSave {
  const PendingSave({
    required this.noteId,
    required this.title,
    required this.text,
    required this.baseVersion,
    required this.since,
    required this.serverName,
  });

  /// The note's id; a virtual Today note's tab id (`virtual-today:<date>`)
  /// while its first-edit create is queued.
  final String noteId;

  /// The note's title, as the leave confirms list it (#103).
  final String title;

  /// The queued text: the latest text typed. Further edits replace it.
  final String text;

  /// The `expected_version` the retry sends; null for a virtual Today
  /// create.
  final int? baseVersion;

  /// When the text first failed to reach the server, from `clockProvider`.
  final DateTime since;

  /// The vault server's name, as the editor label shows it.
  final String serverName;
}

/// The hosted editor's pending-save queue (#102): every queued note, oldest
/// first. Empty on a local vault.
final pendingSavesProvider = Provider<List<PendingSave>>(
  (ref) => throw UnimplementedError('#102 pending-save queue'),
);

/// The open hosted vault's server name, for a queued save whose failure
/// doesn't name it (a `401`'s `MemexException`). Default: the
/// `HostedVaultRef`'s server id (#105 binds it to the saved server's name).
final hostedServerNameProvider = Provider<String>(
  (ref) => throw UnimplementedError('#102 hosted server name'),
);
