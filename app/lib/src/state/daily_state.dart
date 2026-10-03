import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dates.dart';
import '../db/daily_reads.dart';
import 'clock.dart';
import 'vault_state.dart';

/// Today's local ISO date; moves to the next date at local midnight.
///
/// A notifier rather than a plain provider so the date changes (and listeners
/// hear it) the moment the midnight timer fires.
final todayDateProvider = NotifierProvider<TodayDateNotifier, String>(
  TodayDateNotifier.new,
);

class TodayDateNotifier extends Notifier<String> {
  Timer? _timer;

  @override
  String build() {
    ref.onDispose(() => _timer?.cancel());
    return _schedule();
  }

  /// Arms the timer for the next local midnight and returns today's date.
  String _schedule() {
    final clock = ref.read(clockProvider);
    final now = clock.now();
    _timer = clock.after(
      startOfNextLocalDay(now).difference(now),
      () => state = _schedule(),
    );
    return isoDate(now);
  }
}

/// Daily notes, newest first. Empty on a vault below V5.
final dailyNotesProvider = Provider<List<DailyNoteRow>>((ref) {
  ref.watch(vaultRevisionProvider);
  if (!ref.watch(vaultV5ReadyProvider)) return const [];
  return ref.watch(vaultDbProvider)?.dailyNotes() ?? const [];
});

/// Today's daily note, or null when it does not exist yet.
final todayNoteProvider = Provider<DailyNoteRow?>((ref) {
  final today = ref.watch(todayDateProvider);
  for (final row in ref.watch(dailyNotesProvider)) {
    if (row.date == today) return row;
  }
  return null;
});

/// A note's review state; null on a vault below V5.
final reviewStateProvider = Provider.family<ReviewInfo?, String>((ref, noteId) {
  ref.watch(vaultRevisionProvider);
  if (!ref.watch(vaultV5ReadyProvider)) return null;
  return ref.watch(vaultDbProvider)?.reviewState(noteId);
});

/// A note's blocks in `ord` order.
final blocksForNoteProvider = Provider.family<List<BlockRow>, String>((
  ref,
  noteId,
) {
  ref.watch(vaultRevisionProvider);
  if (!ref.watch(vaultV5ReadyProvider)) return const [];
  return ref.watch(vaultDbProvider)?.blocksForNote(noteId) ?? const [];
});

/// A daily note's footer chips in insertion order.
final footerChipsProvider = Provider.family<List<FooterChipRow>, String>((
  ref,
  dailyNoteId,
) {
  ref.watch(vaultRevisionProvider);
  if (!ref.watch(vaultV5ReadyProvider)) return const [];
  return ref.watch(vaultDbProvider)?.footerChips(dailyNoteId) ?? const [];
});
