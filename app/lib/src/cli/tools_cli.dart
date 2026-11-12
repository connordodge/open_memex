// WI #412 (Spec #394 req 15, 35; D22): `memex tools` as a wrapper in
// `lib/src/cli/`. Skeleton: the signature is frozen.
import 'dart:convert';
import 'dart:io';

import '../agents_sheet/tools/tool_catalog.dart';
import '../memex_cli.dart';

/// Runs `memex tools` (arguments exactly `['tools']`: no `--vault`, no
/// `--json`) and classifies the outcome. A null [cli] (no `memex`
/// configured) answers [ToolCatalogBinaryNotFound], as does a
/// `ProcessException`; exit 2 whatever stderr says is [ToolCatalogTooOld];
/// any other failure is [ToolCatalogError] with the C1 message (the stderr
/// text when it is not a C1 line); stdout that is not the wire shape is a
/// [ToolCatalogError] too.
class ToolsCli {
  const ToolsCli(this.cli);

  final MemexCli? cli;

  Future<ToolCatalogResult> list() async {
    final cli = this.cli;
    if (cli == null) return const ToolCatalogBinaryNotFound();
    final MemexResult r;
    try {
      r = await cli.run(const ['tools']);
    } on ProcessException {
      return const ToolCatalogBinaryNotFound();
    }
    if (r.exitCode == 2) return const ToolCatalogTooOld();
    if (r.exitCode != 0) {
      final error = MemexException.fromCliFailure('tools', r);
      const prefix = 'tools failed: ';
      return ToolCatalogError(
        error.message.startsWith(prefix)
            ? error.message.substring(prefix.length)
            : error.message,
      );
    }
    try {
      return ToolCatalogOk(ToolCatalog.fromJson(jsonDecode(r.stdout.trim())));
    } on FormatException catch (e) {
      return ToolCatalogError(
        'memex tools printed output the app cannot read: ${e.message}',
      );
    }
  }
}
