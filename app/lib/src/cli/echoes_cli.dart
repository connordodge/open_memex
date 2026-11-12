// WI #425 (391-A1): `memex echoes` through [MemexCli] and its answer's
// mapping to an [EchoesResult].
import 'dart:convert';

import '../memex_cli.dart';
import '../vault_access/echoes_access.dart';

/// How long `memex echoes` (and the hosted echoes route) may run (req 21).
const echoesTimeout = Duration(seconds: 60);

/// How long `memex echoes --allow-download` may run: it fetches the model
/// (req 22).
const echoesDownloadTimeout = Duration(minutes: 10);

extension EchoesCli on MemexCli {
  /// `memex echoes --vault <vaultPath> --note-id <noteId>`, plus
  /// `--allow-download` when [allowDownload] (no `--limit`: the CLI's default
  /// of 8 applies). Exit 0 is [EchoesReady]; a timeout is
  /// `EmbedderUnavailable('timed out')`; a C1 failure is mapped by its code
  /// (see [localEchoesUnavailableFor]); exit 2 with non-JSON stderr is [Outdated]
  /// (a `memex` that predates the subcommand). Every other failure throws
  /// [MemexException], so does an exit-0 answer that is not an echoes answer.
  Future<EchoesResult> echoes({
    required String vaultPath,
    required String noteId,
    bool allowDownload = false,
  }) async {
    final MemexResult r;
    try {
      r = await run([
        'echoes',
        '--vault',
        vaultPath,
        '--note-id',
        noteId,
        if (allowDownload) '--allow-download',
      ], timeout: allowDownload ? echoesDownloadTimeout : echoesTimeout);
    } on MemexCliTimeout {
      return const EchoesUnavailable(EmbedderUnavailable('timed out'));
    }
    if (r.exitCode == 0) {
      final Object? decoded;
      try {
        decoded = jsonDecode(r.stdout);
      } on FormatException {
        throw MemexException(
          'echoes failed: memex echoes printed output the app cannot read',
        );
      }
      return echoesReadyFromJson(decoded);
    }
    final failure = MemexException.fromCliFailure('echoes', r);
    if (failure.code == null && r.exitCode == 2) {
      return const EchoesUnavailable(Outdated());
    }
    final unavailable = localEchoesUnavailableFor(failure);
    if (unavailable != null) return unavailable;
    throw failure;
  }
}
