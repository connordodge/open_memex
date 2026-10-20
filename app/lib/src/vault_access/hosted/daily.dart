import '../../cli/excerpt_cli.dart';
import '../../cli/footer_cli.dart';
import '../../db/daily_reads.dart';
import '../daily_access.dart';
import 'hosted_client.dart';

/// [DailyAccess] for a hosted vault (D11 V2, D13): every read and write is
/// one `/vaults/<vaultName>/api/v1` route through [client] (D17).
class HostedDailyAccess implements DailyAccess {
  HostedDailyAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  // ---------- reads ----------

  @override
  Future<List<DailyNoteRow>> dailyNotes() => throw UnimplementedError('#82');

  @override
  Future<DailyNoteRow?> dailyNoteForDate(String isoDate) =>
      throw UnimplementedError('#82');

  @override
  Future<ReviewInfo?> reviewState(String noteId) =>
      throw UnimplementedError('#82');

  @override
  Future<List<BlockRow>> blocksForNote(String noteId) =>
      throw UnimplementedError('#82');

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) =>
      throw UnimplementedError('#82');

  // ---------- writes ----------

  @override
  Future<FooterAddResult> addFooterChip({
    required String dailyNoteId,
    required String topicNoteId,
  }) => throw UnimplementedError('#82');

  @override
  Future<ExcerptRemoveResult> removeExcerpt({
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  }) => throw UnimplementedError('#82');
}
