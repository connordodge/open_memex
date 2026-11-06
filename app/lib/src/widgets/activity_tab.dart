import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dates.dart';
import '../db.dart';
import '../db/activity_reads.dart';
import '../db/feedback_reads.dart';
import '../memex_cli.dart';
import '../state/activity_state.dart';
import '../state/editor_controller.dart' show editorControllerProvider;
import '../state/feedback_state.dart';
import '../state/note_state.dart';
import '../state/topic_actions.dart';
import '../state/vault_access_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_async_view.dart';
import 'activity/feedback_rows.dart';
import 'activity/filed_section.dart';
import 'atoms.dart';
import 'panel_placeholder_tab.dart';

const _activityEyebrow = 'agent activity · this note';
const _activitySubtitle =
    'every read and write by every connected agent. attaches to the audit log when a vault is shared with claude desktop.';
const _activityEmpty =
    'no activity yet.\nconnect an agent via the MCP server to see what they touch.';

/// The selected note's `agent_changes` log, newest first.
class ActivityTab extends ConsumerWidget {
  const ActivityTab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = watchVaultValue(ref, selectedNoteAsyncProvider, null);
    const emptyTab = PanelPlaceholderTab(
      eyebrow: _activityEyebrow,
      subtitle: _activitySubtitle,
      empty: _activityEmpty,
      emptyKey: Key('activity-empty'),
    );
    if (selected == null) return emptyTab;
    final feedback = ActivityFeedback.watch(ref, selected);
    return VaultAsyncView<List<AgentChangeRow>>(
      value: ref.watch(agentChangesAsyncProvider(selected.id)),
      empty: const <AgentChangeRow>[],
      builder: (context, entries) {
        final homes = feedback.homes(entries);
        final filed = watchFilingToShow(ref, selected);
        if (entries.isEmpty && homes.isEmpty && filed == null) {
          return emptyTab;
        }
        // Only the Vault Guide can be restored: its entries that a guide
        // revision names (by agent change) get a Restore button.
        final isGuide = selected.role == 'guide';
        final revisions = isGuide
            ? watchVaultValue(
                ref,
                guideRevisionsProvider,
                const <GuideRevisionRow>[],
              )
            : const <GuideRevisionRow>[];
        return ListView(
          children: [
            if (filed != null) FiledSection(note: selected),
            if (entries.isNotEmpty || !homes.isEmpty) ...[
              const PanelHeader(eyebrow: _activityEyebrow),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(_activitySubtitle, style: _activitySubtitleStyle),
              ),
              const OmHairline(),
              FeedbackAboveEntries(rows: homes.above),
              for (final entry in entries)
                _ActivityEntry(
                  entry: entry,
                  guide: selected,
                  revisionId: isGuide ? _revisionOf(revisions, entry.id) : null,
                  feedback: EntryFeedback(
                    entry: entry,
                    rows: homes.byEntry[entry.id] ?? const [],
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

String? _revisionOf(List<GuideRevisionRow> revisions, String agentChangeId) {
  for (final r in revisions) {
    if (r.agentChangeId == agentChangeId) return r.id;
  }
  return null;
}

final _activitySubtitleStyle = OmType.mono(
  size: 10.5,
  color: OmColors.fg3,
  height: 1.6,
);

class _ActivityEntry extends StatelessWidget {
  const _ActivityEntry({
    required this.entry,
    required this.guide,
    required this.revisionId,
    required this.feedback,
  });
  final AgentChangeRow entry;

  /// The note shown: the Vault Guide when [revisionId] is set.
  final Note guide;

  /// The guide revision this entry's change produced, or null (no Restore).
  final String? revisionId;
  final Widget feedback;
  @override
  Widget build(BuildContext context) {
    final at = DateTime.fromMillisecondsSinceEpoch(entry.createdAt);
    return Container(
      key: Key('activity-entry-${entry.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatDateTime(at),
            style: OmType.mono(size: 11, color: OmColors.agent),
          ),
          const SizedBox(height: 2),
          Text(entry.day, style: OmType.mono(size: 10.5, color: OmColors.fg3)),
          const SizedBox(height: 6),
          for (final bullet in entry.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '· $bullet',
                style: OmType.sans(size: 12, color: OmColors.fg1, height: 1.5),
              ),
            ),
          if (revisionId case final id?)
            Align(
              alignment: Alignment.centerLeft,
              child: OmButton(
                key: Key('guide-restore-${entry.id}'),
                kind: OmButtonKind.secondary,
                label: 'Restore',
                onPressed: () => _restore(context, guide, id),
              ),
            ),
          feedback,
        ],
      ),
    );
  }
}

const _restoreConfirmText =
    'Restore this version? The current text is kept as a version you can '
    'return to.';

/// Restore: asks, then `memex guide restore` for [revisionId] and rebases the
/// open editor on the restored text and version, so the next save is not a
/// conflict. Reads through a container taken before the awaits: the entry is
/// gone once the Activity tab shows another note. Text typed once the restore
/// is running is newer than the restored text, so the editor keeps it on the
/// restored version, and it saves over that version (which stays a revision).
Future<void> _restore(
  BuildContext context,
  Note guide,
  String revisionId,
) async {
  final container = ProviderScope.containerOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => const _RestoreDialog(),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await guardVaultWrite(context, () async {
      // An edit still waiting on the save debounce is stored first, so the
      // restore keeps it as a revision (the dialog promises the current text
      // is kept). A failed save stops the restore: nothing is replaced.
      final editor = container.read(editorControllerProvider.notifier);
      if (!await editor.flushPendingSaveAndWait()) {
        final message = container.read(editorControllerProvider).errorMessage;
        throw MemexException(message ?? 'Could not save your changes first.');
      }
      final flushed = container.read(editorControllerProvider).contentMd;
      // FeedbackActions bumps the vault revision once.
      final result = await container
          .read(feedbackActionsProvider)
          .restoreGuide(revisionId);
      final restored = await container
          .read(vaultAccessProvider)
          ?.notes
          .getNote(guide.id);
      if (restored == null) return;
      final now = container.read(editorControllerProvider).contentMd;
      await rebaseEditorOnVersionIn(
        container,
        fallback: guide,
        version: result.version,
        content: now == flushed ? restored.contentMd : now,
      );
    });
  } on Exception catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(e is MemexException ? e.message : '$e')),
    );
  }
}

class _RestoreDialog extends StatelessWidget {
  const _RestoreDialog();
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: const Text(_restoreConfirmText),
      actions: [
        TextButton(
          key: const Key('guide-restore-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('guide-restore-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
