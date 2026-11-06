import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cli/excerpt_cli.dart';
import '../cli/feedback_cli.dart';
import '../cli/guide_cli.dart';
import '../db/feedback_reads.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// A note's Feedback through `VaultAccess`, newest first, stamped with the
/// vault it was loaded for (D14a). Empty (stamped) with no vault access and
/// below V6 (`vaultV6ReadyProvider`). Re-reads on every
/// `vaultRevisionProvider` bump.
final feedbackForNoteProvider =
    FutureProvider.family<VaultScoped<List<FeedbackRow>>, String>(
      (ref, noteId) async =>
          VaultScoped(ref.watch(currentVaultProvider), const <FeedbackRow>[]),
    );

/// Feedback with no note, stamped like [feedbackForNoteProvider].
final feedbackWithoutNoteProvider =
    FutureProvider<VaultScoped<List<FeedbackRow>>>(
      (ref) async =>
          VaultScoped(ref.watch(currentVaultProvider), const <FeedbackRow>[]),
    );

/// The Vault Guide's revisions, newest first, stamped like
/// [feedbackForNoteProvider].
final guideRevisionsProvider =
    FutureProvider<VaultScoped<List<GuideRevisionRow>>>(
      (ref) async => VaultScoped(
        ref.watch(currentVaultProvider),
        const <GuideRevisionRow>[],
      ),
    );

/// Where the blocks of the daily note for a date (`YYYY-MM-DD`) are filed,
/// stamped like [feedbackForNoteProvider]. Null with no vault access and
/// below V6.
final filingProvider = FutureProvider.family<VaultScoped<Filing?>, String>(
  (ref, date) async =>
      VaultScoped<Filing?>(ref.watch(currentVaultProvider), null),
);

/// The writes of `FeedbackAccess`, each followed by one bump of
/// `vaultRevisionProvider` after the write returns.
final feedbackActionsProvider = Provider<FeedbackActions>(FeedbackActions.new);

/// See [feedbackActionsProvider].
class FeedbackActions {
  FeedbackActions(this._ref);

  // ignore: unused_field
  final Ref _ref;

  Future<ExcerptEditResult> fileBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => const ExcerptEditResult(vaultId: '', topicNoteId: '', version: 0);

  Future<ExcerptMoveResult> moveBlock({
    required String fromTopicNoteId,
    required String toTopicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => const ExcerptMoveResult(
    vaultId: '',
    fromTopicNoteId: '',
    fromVersion: 0,
    toTopicNoteId: '',
    toVersion: 0,
  );

  Future<ExcerptEditResult> removeBlock({
    required String topicNoteId,
    required String date,
    required String blockId,
    String? note,
  }) async => const ExcerptEditResult(vaultId: '', topicNoteId: '', version: 0);

  Future<FeedbackRow> addComment({
    required String noteId,
    required String date,
    required String changeId,
    required String text,
  }) async => _neutralRow;

  Future<FeedbackRow> editComment({
    required String id,
    required String text,
  }) async => _neutralRow;

  Future<FeedbackRemoveResult> deleteComment({required String id}) async =>
      const FeedbackRemoveResult(vaultId: '', id: '');

  Future<GuideRestoreResult> restoreGuide(String revisionId) async =>
      const GuideRestoreResult(vaultId: '', noteId: '', version: 0);
}

const _neutralRow = FeedbackRow(
  id: '',
  kind: FeedbackKind.comment,
  source: FeedbackSource.person,
  status: FeedbackStatus.open,
  createdAt: 0,
  updatedAt: 0,
);
