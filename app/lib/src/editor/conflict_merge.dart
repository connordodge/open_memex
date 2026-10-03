// Req 60 conflict rebuild as a pure function (Spec #1, WI #20).

/// A server `blocks` row, as far as the conflict merge needs it.
class ServerBlock {
  const ServerBlock({
    required this.source,
    required this.createdVersion,
    required this.ord,
    required this.text,
  });

  /// `person`, `agent` or `quick-entry`.
  final String source;

  /// The notes.version of the write that created the block.
  final int createdVersion;
  final int ord;
  final String text;
}

/// Rebuilds a daily note body after a save conflict (Req 60).
///
/// Returns `assembleDailyBody(localPerson + appended,
/// splitDailyBody(serverBody).chips)`, where `appended` is every `agent` or
/// `quick-entry` block newer than [baseVersion] whose text isn't already in
/// [localPerson], in `ord` order, blank-line separated (C3.1).
String mergeConflict({
  required String localPerson,
  required int baseVersion,
  required String serverBody,
  required List<ServerBlock> serverBlocks,
}) => throw UnimplementedError();
