import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/daily_reads.dart';

/// Today's local ISO date; moves to the next date at local midnight.
final todayDateProvider = Provider<String>((ref) => throw UnimplementedError());

/// Daily notes, newest first. Empty on a vault below V5.
final dailyNotesProvider = Provider<List<DailyNoteRow>>(
  (ref) => throw UnimplementedError(),
);

/// Today's daily note, or null when it does not exist yet.
final todayNoteProvider = Provider<DailyNoteRow?>(
  (ref) => throw UnimplementedError(),
);

/// A note's review state; null on a vault below V5.
final reviewStateProvider = Provider.family<ReviewInfo?, String>(
  (ref, noteId) => throw UnimplementedError(),
);

/// A note's blocks in `ord` order.
final blocksForNoteProvider = Provider.family<List<BlockRow>, String>(
  (ref, noteId) => throw UnimplementedError(),
);

/// A daily note's footer chips in insertion order.
final footerChipsProvider = Provider.family<List<FooterChipRow>, String>(
  (ref, dailyNoteId) => throw UnimplementedError(),
);
