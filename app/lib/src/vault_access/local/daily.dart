import '../../cli/excerpt_cli.dart';
import '../../cli/footer_cli.dart';
import '../../db.dart';
import '../../db/daily_reads.dart';
import '../../memex_cli.dart';
import '../daily_access.dart';

/// [DailyAccess] for a local vault: reads from [db], writes through [cli]
/// with `--vault` [vaultPath] (D13). Either may be null (see `DailyAccess`).
class LocalDailyAccess implements DailyAccess {
  LocalDailyAccess({required this.vaultPath, this.db, this.cli});

  final String vaultPath;
  final VaultDb? db;
  final MemexCli? cli;

  // RED SKELETON (#70 test author): bodies are placeholders; the implementer
  // replaces every one with the delegation to [db] / [cli].

  @override
  Future<List<DailyNoteRow>> dailyNotes() async => const [];

  @override
  Future<DailyNoteRow?> dailyNoteForDate(String isoDate) async => null;

  @override
  Future<ReviewInfo?> reviewState(String noteId) async => null;

  @override
  Future<List<BlockRow>> blocksForNote(String noteId) async => const [];

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) async => const [];

  @override
  Future<FooterAddResult> addFooterChip({
    required String dailyNoteId,
    required String topicNoteId,
  }) async => const FooterAddResult(
    vaultId: '',
    dailyNoteId: '',
    topicNoteId: '',
    origin: '',
    version: 0,
  );

  @override
  Future<ExcerptRemoveResult> removeExcerpt({
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  }) async =>
      const ExcerptRemoveResult(vaultId: '', topicNoteId: '', version: 0);
}
