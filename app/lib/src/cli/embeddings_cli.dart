// WI #413 (Spec #394 req 15, 43): `memex embeddings status` as a wrapper in
// `lib/src/cli/`.
import 'dart:convert';
import 'dart:io';

import '../agents_sheet/recall/embeddings_status.dart';
import '../memex_cli.dart';

/// Runs `memex embeddings status --vault <vaultPath>` (arguments exactly
/// `['embeddings', 'status', '--vault', vaultPath]`, no `--json`) and
/// classifies the outcome. A null [cli] (no `memex` configured) answers
/// [EmbeddingsBinaryNotFound], as does a `ProcessException`; exit 2 whatever
/// stderr says is [EmbeddingsTooOld]; any other failure is
/// [EmbeddingsStatusError] with the C1 message (the stderr text when it is
/// not a C1 line); stdout that is not the wire shape is an
/// [EmbeddingsStatusError] too. Each call runs the binary once.
class EmbeddingsCli {
  const EmbeddingsCli(this.cli);

  final MemexCli? cli;

  static const _operation = 'embeddings status';

  Future<EmbeddingsStatusResult> status({required String vaultPath}) async {
    final cli = this.cli;
    if (cli == null) return const EmbeddingsBinaryNotFound();
    final MemexResult r;
    try {
      r = await cli.run(['embeddings', 'status', '--vault', vaultPath]);
    } on ProcessException {
      return const EmbeddingsBinaryNotFound();
    }
    if (r.exitCode == 2) return const EmbeddingsTooOld();
    if (r.exitCode != 0) {
      final error = MemexException.fromCliFailure(_operation, r);
      const prefix = '$_operation failed: ';
      return EmbeddingsStatusError(
        error.message.startsWith(prefix)
            ? error.message.substring(prefix.length)
            : error.message,
      );
    }
    try {
      return EmbeddingsStatusOk(
        EmbeddingsStatus.fromJson(jsonDecode(r.stdout.trim())),
      );
    } on FormatException catch (e) {
      return EmbeddingsStatusError(
        'memex embeddings status printed output the app cannot read: '
        '${e.message}',
      );
    }
  }
}
