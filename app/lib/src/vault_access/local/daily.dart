import '../../cli/excerpt_cli.dart';
import '../../cli/footer_cli.dart';
import '../../db.dart';
import '../../db/daily_reads.dart';
import '../../memex_cli.dart';
import '../daily_access.dart';
import 'write_guard.dart';

/// [DailyAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `DailyAccess`).
class LocalDailyAccess implements DailyAccess {
  LocalDailyAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  MemexCli get _cli => requireLocalCli(cli);

  // ---------- reads ----------

  @override
  Future<List<DailyNoteRow>> dailyNotes() async => db?.dailyNotes() ?? const [];

  @override
  Future<DailyNoteRow?> dailyNoteForDate(String isoDate) async =>
      db?.dailyNoteForDate(isoDate);

  @override
  Future<ReviewInfo?> reviewState(String noteId) async =>
      db?.reviewState(noteId);

  @override
  Future<List<BlockRow>> blocksForNote(String noteId) async =>
      db?.blocksForNote(noteId) ?? const [];

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) async =>
      db?.footerChips(dailyNoteId) ?? const [];

  // ---------- writes ----------

  @override
  Future<FooterAddResult> addFooterChip({
    required String dailyNoteId,
    required String topicNoteId,
  }) async => _cli.addFooterChip(
    vaultPath: vaultPath,
    dailyNoteId: dailyNoteId,
    topicNoteId: topicNoteId,
  );

  @override
  Future<ExcerptRemoveResult> removeExcerpt({
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  }) async => _cli.removeExcerpt(
    vaultPath: vaultPath,
    topicNoteId: topicNoteId,
    date: date,
    fromBlockId: fromBlockId,
    toBlockId: toBlockId,
  );
}
