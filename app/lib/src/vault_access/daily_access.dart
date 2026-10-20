import '../cli/excerpt_cli.dart';
import '../cli/footer_cli.dart';
import '../db/daily_reads.dart';

/// Daily notes, review state, blocks, the Topics footer and excerpts of the
/// open vault (D13, D11 V2). Same rules as `NotesAccess`: async mirrors of
/// today's `DailyReads` / CLI wrappers, today's empty values without a
/// database, today's exceptions from writes, [StateError] from a write when
/// `VaultAccess.canWrite` is false.
///
/// Frozen at merge (D13). Test doubles `extends LocalDailyAccess` (D21).
abstract interface class DailyAccess {
  // ---------- reads ----------

  /// `DailyReads.dailyNotes`: newest date first.
  Future<List<DailyNoteRow>> dailyNotes();

  /// `DailyReads.dailyNoteForDate`: the daily note titled [isoDate], or null.
  Future<DailyNoteRow?> dailyNoteForDate(String isoDate);

  /// `DailyReads.reviewState`.
  Future<ReviewInfo?> reviewState(String noteId);

  /// `DailyReads.blocksForNote`: blocks by `ord`.
  Future<List<BlockRow>> blocksForNote(String noteId);

  /// `DailyReads.footerChips`: the daily note's Topics footer chips.
  Future<List<FooterChipRow>> footerChips(String dailyNoteId);

  // ---------- writes ----------

  /// `memex footer add` (`FooterCli.addFooterChip`).
  Future<FooterAddResult> addFooterChip({
    required String dailyNoteId,
    required String topicNoteId,
  });

  /// `memex excerpt rm` (`ExcerptCli.removeExcerpt`).
  Future<ExcerptRemoveResult> removeExcerpt({
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  });
}
