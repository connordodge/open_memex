// Req 60 conflict rebuild as a pure function (Spec #1, WI #20).

import 'segments.dart';

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
}) {
  final appended =
      serverBlocks
          .where(
            (block) =>
                _appendableSources.contains(block.source) &&
                block.createdVersion > baseVersion &&
                !localPerson.contains(block.text),
          )
          .toList()
        ..sort((a, b) => a.ord.compareTo(b.ord));
  var person = localPerson;
  for (final block in appended) {
    person = appendToPerson(person, block.text);
  }
  return assembleDailyBody(person, splitDailyBody(serverBody).chips);
}

/// Block sources whose newer blocks are re-appended on conflict (Req 60).
const Set<String> _appendableSources = {'agent', 'quick-entry'};

/// Appends [text] to a daily person section with the C3.1 separator: when
/// [person] is non-empty it is first padded to end with a blank line (`\n\n`),
/// then `text + "\n"` is appended.
///
/// The app's one C3.1 append: the conflict merge (Req 60) and the virtual
/// Today note's `daily_note_exists` path (#22) both use it.
String appendToPerson(String person, String text) {
  final String padded;
  if (person.isEmpty || person.endsWith('\n\n')) {
    padded = person;
  } else if (person.endsWith('\n')) {
    padded = '$person\n';
  } else {
    padded = '$person\n\n';
  }
  return '$padded$text\n';
}
