import '../../cli/excerpt_cli.dart';
import '../../cli/footer_cli.dart';
import '../../db/daily_reads.dart';
import '../../memex_cli.dart';
import '../daily_access.dart';
import 'hosted_client.dart';

/// [DailyAccess] for a hosted vault (D11 V2, D13): every read and write is
/// one `/vaults/<vaultName>/api/v1` route through [client] (D17).
///
/// Writes label their errors with the CLI wrapper's operation (`footer add`,
/// `excerpt rm`), so a hosted failure reads like the CLI's; reads use `get`.
/// Unknown response keys are ignored. Writes leave `vaultRevisionProvider`
/// to their call sites.
class HostedDailyAccess implements DailyAccess {
  HostedDailyAccess({required this.client, required this.vaultName});

  final HostedClient client;

  /// The served vault's name on the vault server.
  final String vaultName;

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    required String operation,
    Map<String, String>? query,
    Object? body,
  }) => client.vaultRequest(
    method,
    vaultName,
    path,
    operation: operation,
    query: query,
    body: body,
  );

  static String _note(String id) => '/notes/${Uri.encodeComponent(id)}';

  static List<Map<String, Object?>> _rows(Object? list) =>
      (list as List).cast<Map<String, Object?>>();

  static int _int(Object? n) => (n as num).toInt();

  /// The [ReviewState] whose label is exactly [label].
  static ReviewState _state(Object? label) {
    for (final s in ReviewState.values) {
      if (s.label == label) return s;
    }
    throw MemexException('get: unknown review state: $label');
  }

  static DailyNoteRow _dailyRow(Map<String, Object?> r) => DailyNoteRow(
    date: r['date'] as String,
    noteId: r['note_id'] as String,
    preview: r['preview'] as String,
    reviewState: _state(r['review_state']),
  );

  // ---------- reads ----------

  @override
  Future<List<DailyNoteRow>> dailyNotes() async {
    final json = await _call('GET', '/daily-notes', operation: 'get');
    return [for (final r in _rows(json['daily_notes'])) _dailyRow(r)];
  }

  /// [isoDate] goes as one encoded path segment and is never validated: a
  /// title no daily note has is null, like the local read.
  @override
  Future<DailyNoteRow?> dailyNoteForDate(String isoDate) async {
    final json = await _call(
      'GET',
      '/daily-notes/${Uri.encodeComponent(isoDate)}',
      operation: 'get',
    );
    final row = json['daily_note'];
    return row == null ? null : _dailyRow(row as Map<String, Object?>);
  }

  @override
  Future<ReviewInfo?> reviewState(String noteId) async {
    final json = await _call(
      'GET',
      '${_note(noteId)}/review',
      operation: 'get',
    );
    final at = json['reviewed_at'];
    return ReviewInfo(
      state: _state(json['state']),
      reviewedAt: at == null ? null : _int(at),
    );
  }

  @override
  Future<List<BlockRow>> blocksForNote(String noteId) async {
    final json = await _call(
      'GET',
      '${_note(noteId)}/blocks',
      operation: 'get',
    );
    return [
      for (final r in _rows(json['blocks']))
        BlockRow(
          blockId: r['block_id'] as String,
          ord: _int(r['ord']),
          text: r['text'] as String,
          source: r['source'] as String,
          createdVersion: _int(r['created_version']),
          createdAt: _int(r['created_at']),
          startByte: _int(r['start_byte']),
          endByte: _int(r['end_byte']),
        ),
    ];
  }

  @override
  Future<List<FooterChipRow>> footerChips(String dailyNoteId) async {
    final json = await _call(
      'GET',
      '${_note(dailyNoteId)}/footer-chips',
      operation: 'get',
    );
    return [
      for (final r in _rows(json['chips']))
        FooterChipRow(
          topicNoteId: r['topic_note_id'] as String,
          topicTitle: r['topic_title'] as String,
          origin: r['origin'] as String,
        ),
    ];
  }

  // ---------- writes ----------

  @override
  Future<FooterAddResult> addFooterChip({
    required String dailyNoteId,
    required String topicNoteId,
  }) async {
    final json = await _call(
      'POST',
      '${_note(dailyNoteId)}/footer-chips',
      operation: 'footer add',
      body: {'topic_note_id': topicNoteId},
    );
    return FooterAddResult(
      vaultId: json['vault_id'] as String,
      dailyNoteId: json['daily_note_id'] as String,
      topicNoteId: json['topic_note_id'] as String,
      origin: json['origin'] as String,
      version: _int(json['version']),
    );
  }

  /// `block_ids` is what `ExcerptCli.removeExcerpt` passes to `--block-ids`:
  /// [fromBlockId] alone, or `from,to` whenever [toBlockId] is non-null.
  @override
  Future<ExcerptRemoveResult> removeExcerpt({
    required String topicNoteId,
    required String date,
    required String fromBlockId,
    String? toBlockId,
  }) async {
    final json = await _call(
      'DELETE',
      '${_note(topicNoteId)}/excerpts',
      operation: 'excerpt rm',
      query: {
        'date': date,
        'block_ids': toBlockId == null
            ? fromBlockId
            : '$fromBlockId,$toBlockId',
      },
    );
    return ExcerptRemoveResult(
      vaultId: json['vault_id'] as String,
      topicNoteId: json['topic_note_id'] as String,
      version: _int(json['version']),
    );
  }
}
