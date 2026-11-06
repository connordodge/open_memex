import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/excerpt_cli.dart';
import '../cli/feedback_cli.dart';
import '../cli/guide_cli.dart';
import '../db/feedback_reads.dart';
import '../vault_access/feedback_access.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Whether the V6 tables are missing: only a local vault with an open
/// database can lack them (a hosted vault has none, the server answers for
/// itself). Watches `vaultRevisionProvider` through [vaultV6ReadyProvider].
bool _belowV6(Ref ref) =>
    ref.watch(vaultDbProvider) != null && !ref.watch(vaultV6ReadyProvider);

/// A note's Feedback through `VaultAccess`, newest first, stamped with the
/// vault it was loaded for (D14a). Empty (stamped) with no vault access and
/// below V6 (`vaultV6ReadyProvider`). Re-reads on every
/// `vaultRevisionProvider` bump.
final feedbackForNoteProvider =
    FutureProvider.family<VaultScoped<List<FeedbackRow>>, String>((
      ref,
      noteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null || _belowV6(ref)) {
        return VaultScoped(vault, const <FeedbackRow>[]);
      }
      return VaultScoped(vault, await access.feedback.feedbackForNote(noteId));
    });

/// Feedback with no note, stamped like [feedbackForNoteProvider].
final feedbackWithoutNoteProvider =
    FutureProvider<VaultScoped<List<FeedbackRow>>>((ref) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null || _belowV6(ref)) {
        return VaultScoped(vault, const <FeedbackRow>[]);
      }
      return VaultScoped(vault, await access.feedback.feedbackWithoutNote());
    });

/// The Vault Guide's revisions, newest first, stamped like
/// [feedbackForNoteProvider].
final guideRevisionsProvider =
    FutureProvider<VaultScoped<List<GuideRevisionRow>>>((ref) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null || _belowV6(ref)) {
        return VaultScoped(vault, const <GuideRevisionRow>[]);
      }
      return VaultScoped(vault, await access.feedback.guideRevisions());
    });

/// Where the blocks of the daily note for a date (`YYYY-MM-DD`) are filed,
/// stamped like [feedbackForNoteProvider]. Null with no vault access and
/// below V6.
final filingProvider = FutureProvider.family<VaultScoped<Filing?>, String>((
  ref,
  date,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  if (access == null || _belowV6(ref)) {
    return VaultScoped<Filing?>(vault, null);
  }
  return VaultScoped<Filing?>(vault, await access.feedback.filing(date));
});

/// The writes of `FeedbackAccess`, each followed by one bump of
/// `vaultRevisionProvider` after the write returns.
final feedbackActionsProvider = Provider<FeedbackActions>(FeedbackActions.new);

/// See [feedbackActionsProvider]. Each method returns what the access call
/// returns. The revision is bumped once, after the call returns or throws a
/// failure the vault may have seen (a [MemexException] such as
/// `feedback_handled`, so the reads refresh). A [StateError] (no open vault,
/// or no CLI: nothing ran) does not bump. Callers must not bump again.
class FeedbackActions {
  FeedbackActions(this._ref);

  final Ref _ref;

  Future<T> _write<T>(Future<T> Function(FeedbackAccess feedback) write) async {
    final access = _ref.read(vaultAccessProvider);
    if (access == null) throw StateError('No vault is open.');
    var ran = true;
    try {
      return await write(access.feedback);
    } on StateError {
      ran = false;
      rethrow;
    } finally {
      if (ran) _ref.read(vaultRevisionProvider.notifier).state++;
    }
  }

  /// `memex excerpt add`: see `FeedbackAccess.fileBlock`.
  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _write(
    (f) => f.fileBlock(
      topicNoteId: topicNoteId,
      date: date,
      blockId: blockId,
      note: note,
    ),
  );

  /// `memex excerpt move`: see `FeedbackAccess.moveBlock`.
  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _write(
    (f) => f.moveBlock(
      fromTopicNoteId: fromTopicNoteId,
      toTopicNoteId: toTopicNoteId,
      date: date,
      blockId: blockId,
      note: note,
    ),
  );

  /// `memex excerpt remove-block`: see `FeedbackAccess.removeBlock`.
  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) => _write(
    (f) => f.removeBlock(
      topicNoteId: topicNoteId,
      date: date,
      blockId: blockId,
      note: note,
    ),
  );

  /// `memex feedback add`: see `FeedbackAccess.addComment`.
  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) => _write(
    (f) => f.addComment(
      noteId: noteId,
      date: date,
      changeId: changeId,
      text: text,
    ),
  );

  /// `memex feedback edit`: see `FeedbackAccess.editComment`.
  Future<FeedbackRow> editComment({required String id, required String text}) =>
      _write((f) => f.editComment(id: id, text: text));

  /// `memex feedback rm`: see `FeedbackAccess.deleteComment`.
  Future<FeedbackRemoveResult> deleteComment({required String id}) =>
      _write((f) => f.deleteComment(id: id));

  /// `memex guide restore`: see `FeedbackAccess.restoreGuide`.
  Future<GuideRestoreResult> restoreGuide(String revisionId) =>
      _write((f) => f.restoreGuide(revisionId));
}
