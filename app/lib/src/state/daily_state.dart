import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dates.dart';
import '../db/daily_reads.dart';
import '../vault_access/daily_access.dart';
import '../vault_access/vault_scoped.dart';
import 'clock.dart';
import 'vault_access_state.dart';
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

// Each daily read goes through `VaultAccess.daily` and carries the vault it
// was loaded for (D14a); the provider of the same name without `Async` is its
// synchronous facade. A vault below V5 (or no vault) reads as today's empty
// values.

/// The open vault's daily domain when it is V5-ready, else null.
DailyAccess? _daily(Ref<Object?> ref) {
  final access = ref.watch(vaultAccessProvider);
  if (access == null || !ref.watch(vaultV5ReadyProvider)) return null;
  return access.daily;
}

/// `VaultAccess.daily.dailyNotes`, newest first; facade [dailyNotesProvider].
final dailyNotesAsyncProvider = FutureProvider<VaultScoped<List<DailyNoteRow>>>(
  (ref) async {
    ref.watch(vaultRevisionProvider);
    final vault = ref.watch(currentVaultProvider);
    final daily = _daily(ref);
    if (daily == null) return VaultScoped(vault, const []);
    return VaultScoped(vault, await daily.dailyNotes());
  },
);

/// Today's daily note for [todayDateProvider]'s date, or null, from
/// [dailyNotesAsyncProvider]'s rows (stamped with their vault); facade
/// [todayNoteProvider].
final todayNoteAsyncProvider = FutureProvider<VaultScoped<DailyNoteRow?>>((
  ref,
) async {
  final today = ref.watch(todayDateProvider);
  final notes = await ref.watch(dailyNotesAsyncProvider.future);
  for (final row in notes.value) {
    if (row.date == today) return VaultScoped(notes.vault, row);
  }
  return VaultScoped(notes.vault, null);
});

/// `VaultAccess.daily.reviewState`; facade [reviewStateProvider].
final reviewStateAsyncProvider =
    FutureProvider.family<VaultScoped<ReviewInfo?>, String>((
      ref,
      noteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final daily = _daily(ref);
      if (daily == null) return VaultScoped(vault, null);
      return VaultScoped(vault, await daily.reviewState(noteId));
    });

/// `VaultAccess.daily.blocksForNote`, in `ord` order; facade
/// [blocksForNoteProvider].
final blocksForNoteAsyncProvider =
    FutureProvider.family<VaultScoped<List<BlockRow>>, String>((
      ref,
      noteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final daily = _daily(ref);
      if (daily == null) return VaultScoped(vault, const []);
      return VaultScoped(vault, await daily.blocksForNote(noteId));
    });

/// `VaultAccess.daily.footerChips`, in insertion order; facade
/// [footerChipsProvider].
final footerChipsAsyncProvider =
    FutureProvider.family<VaultScoped<List<FooterChipRow>>, String>((
      ref,
      dailyNoteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final daily = _daily(ref);
      if (daily == null) return VaultScoped(vault, const []);
      return VaultScoped(vault, await daily.footerChips(dailyNoteId));
    });

/// Daily notes, newest first. Empty on a vault below V5. Facade of
/// [dailyNotesAsyncProvider].
final dailyNotesProvider = Provider<List<DailyNoteRow>>(
  (ref) => vaultFacadeValue(
    ref,
    ref.watch(dailyNotesAsyncProvider),
    const <DailyNoteRow>[],
  ),
);

/// Today's daily note, or null when it does not exist yet. Facade of
/// [todayNoteAsyncProvider].
final todayNoteProvider = Provider<DailyNoteRow?>(
  (ref) => vaultFacadeValue(ref, ref.watch(todayNoteAsyncProvider), null),
);

/// A note's review state; null on a vault below V5. Facade of
/// [reviewStateAsyncProvider].
final reviewStateProvider = Provider.family<ReviewInfo?, String>(
  (ref, noteId) =>
      vaultFacadeValue(ref, ref.watch(reviewStateAsyncProvider(noteId)), null),
);

/// A note's blocks in `ord` order. Facade of [blocksForNoteAsyncProvider].
final blocksForNoteProvider = Provider.family<List<BlockRow>, String>(
  (ref, noteId) => vaultFacadeValue(
    ref,
    ref.watch(blocksForNoteAsyncProvider(noteId)),
    const <BlockRow>[],
  ),
);

/// A daily note's footer chips in insertion order. Facade of
/// [footerChipsAsyncProvider].
final footerChipsProvider = Provider.family<List<FooterChipRow>, String>(
  (ref, dailyNoteId) => vaultFacadeValue(
    ref,
    ref.watch(footerChipsAsyncProvider(dailyNoteId)),
    const <FooterChipRow>[],
  ),
);
