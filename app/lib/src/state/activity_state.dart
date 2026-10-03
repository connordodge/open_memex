import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/activity_reads.dart';

/// A note's agent change log, newest first. Empty on a vault below V5 and for
/// a note with no entries; re-reads on every `vaultRevisionProvider` bump.
final agentChangesProvider = Provider.family<List<AgentChangeRow>, String>(
  (ref, noteId) => throw UnimplementedError(),
);
