import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../db.dart';
import '../../db/agents_reads.dart';
import '../agents_access.dart';

/// Where [LocalAgentsAccess] gets the vault's presence records (#390 req 15):
/// the raw JSON text of each record file. Synchronous, so widget tests need
/// no `runAsync`.
abstract interface class PresenceReader {
  List<String> readAll();
}

/// The default [PresenceReader]: lists `<vault>/.memex/agents/` and reads
/// each `*.json` file. Ignores `*.tmp` and any non-`.json` file; a missing
/// directory is an empty list and a file that can't be read is skipped.
/// Never writes, deletes or sweeps a record (TD "App reads stay read-only").
class FilePresenceReader implements PresenceReader {
  FilePresenceReader(this.vaultPath);

  final String vaultPath;

  @override
  List<String> readAll() {
    final dir = Directory(p.join(vaultPath, '.memex', 'agents'));
    final List<FileSystemEntity> entries;
    try {
      // Never creates the directory: a missing one is an empty list.
      if (!dir.existsSync()) return const [];
      entries = dir.listSync();
    } on FileSystemException {
      // Removed between the check and the listing, or not listable.
      return const [];
    }
    final paths = [
      for (final e in entries)
        if (e is File && p.extension(e.path) == '.json') e.path,
    ]..sort();
    final texts = <String>[];
    for (final path in paths) {
      try {
        texts.add(File(path).readAsStringSync());
      } on FileSystemException {
        // Deleted since the listing, unreadable, or not UTF-8 (the SDK
        // reports decode errors as a FileSystemException): skip it.
      }
    }
    return texts;
  }
}

/// [AgentsAccess] for a local vault at [vaultPath] (#390 req 15). A2 (#453)
/// fills [activity]; it may add optional constructor arguments only.
class LocalAgentsAccess implements AgentsAccess {
  LocalAgentsAccess({
    required this.vaultPath,
    this.db,
    PresenceReader? presence,
  }) : _presence = presence ?? FilePresenceReader(vaultPath);

  final String vaultPath;
  final VaultDb? db;

  /// The presence records' source; [FilePresenceReader] by default.
  final PresenceReader _presence;

  /// Every presence record that parses, expired or not (expiry is the
  /// provider's job), by `lastRequestAt` descending, and the newest 20
  /// `agent_activity` rows. A record that doesn't parse is skipped (req 26).
  /// No [db], or a schema without `agent_activity`, gives an empty `recent`.
  /// Throws when the database read fails. Reads both afresh on every call,
  /// writes nothing, and uses only synchronous IO.
  @override
  Future<AgentActivity> activity() async {
    final agents = <AgentPresence>[
      for (final text in _presence.readAll()) ?_parsePresence(text),
    ]..sort((a, b) => b.lastRequestAt.compareTo(a.lastRequestAt));
    final recent = db?.recentAgentActivity() ?? const <AgentActivityEntry>[];
    return AgentActivity(agents: agents, recent: recent, available: true);
  }
}

/// [text] as an [AgentPresence], or null when it is not a JSON object or
/// does not hold a valid record.
AgentPresence? _parsePresence(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (json is! Map<String, Object?>) return null;
  try {
    return AgentPresence.fromJson(json);
  } on FormatException {
    return null;
  }
}
