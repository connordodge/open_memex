import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/poll_reads.dart';
import 'vault_state.dart';

/// The poller's one read of a note's `updated_at` ([PollReads.noteUpdatedAt]
/// on the current vault). The `notePollerProvider` (TD8) reads through this
/// provider, never the database directly, so tests can count its reads.
final noteUpdatedAtReaderProvider = Provider<int? Function(String noteId)>((
  ref,
) {
  final db = ref.watch(vaultDbProvider);
  return (noteId) => db?.noteUpdatedAt(noteId);
});
