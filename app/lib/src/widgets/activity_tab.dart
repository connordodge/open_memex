import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dates.dart';
import '../db.dart';
import '../db/activity_reads.dart';
import '../db/feedback_reads.dart';
import '../memex_cli.dart';
import '../state/activity_state.dart';
import '../state/feedback_state.dart';
import '../state/note_edits_state.dart';
import '../state/note_state.dart';
import '../state/topic_actions.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_async_view.dart';
import 'activity/feedback_rows.dart';
import 'activity/filed_section.dart';
import 'agent_edits_keys.dart';
import 'atoms.dart';
import 'panel_placeholder_tab.dart';

const _activityEyebrow = 'agent activity · this note';
const _activitySubtitle =
    'every read and write by every connected agent. attaches to the audit log when a vault is shared with claude desktop.';
const _activityEmpty =
    'no activity yet.\nconnect an agent via the MCP server to see what they touch.';

/// The selected note's `agent_changes` log, newest first.
///
/// An entry whose change produced a revision that still exists gets a
/// Restore button: on the Vault Guide its guide revision (`guide-restore-*`),
/// on any other note its agent-edit revision (`note-restore-*`, D19), only
/// while [agentEditsAvailableProvider] is true (D17).
class ActivityTab extends ConsumerStatefulWidget {
  const ActivityTab({super.key});
  @override
  ConsumerState<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends ConsumerState<ActivityTab> {
  /// Set from an agent-edit Restore press until its dialog closes unconfirmed
  /// or its restore ends (any outcome), so two presses in one frame, or one
  /// while a restore runs, start one restore. Read and set synchronously: a
  /// `setState` would disable the button only from the next frame.
  bool _noteRestoreBusy = false;

  @override
  Widget build(BuildContext context) {
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
        final restoreOf = _restoresOf(selected);
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
                  restore: restoreOf(entry.id),
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

  /// The Restore of each entry of [note], by agent change id (null: none).
  /// The Vault Guide restores its guide revisions; any other note its
  /// agent-edit revisions, and only while the vault supports them (D17).
  _EntryRestore? Function(String agentChangeId) _restoresOf(Note note) {
    if (note.role == 'guide') {
      final revisions = _revisionsByChange([
        for (final r in watchVaultValue(
          ref,
          guideRevisionsProvider,
          const <GuideRevisionRow>[],
        ))
          (r.agentChangeId, r.id),
      ]);
      return (changeId) => switch (revisions[changeId]) {
        final id? => (
          key: Key('guide-restore-$changeId'),
          onPressed: (context) => _restoreGuide(context, note, id),
        ),
        null => null,
      };
    }
    if (!ref.watch(agentEditsAvailableProvider)) return (_) => null;
    final revisions = _revisionsByChange([
      for (final r in watchVaultValue(
        ref,
        noteRevisionsProvider(note.id),
        const <NoteRevision>[],
      ))
        (r.agentChangeId, r.id),
    ]);
    return (changeId) => switch (revisions[changeId]) {
      final id? => (
        key: noteRestoreKey(changeId),
        onPressed: (context) => _restoreNote(context, note, id),
      ),
      null => null,
    };
  }

  /// Agent-edit Restore of revision [revisionId] of [note], behind
  /// [_noteRestoreBusy]: `NoteEditsActions.restoreNoteRevision` stores the
  /// pending edit first, restores once and bumps the vault revision once
  /// (D18).
  Future<void> _restoreNote(
    BuildContext context,
    Note note,
    String revisionId,
  ) async {
    if (_noteRestoreBusy) return;
    _noteRestoreBusy = true;
    try {
      await _restore(
        context,
        cancelKey: noteRestoreCancelKey,
        confirmKey: noteRestoreConfirmKey,
        write: (container) => container
            .read(noteEditsActionsProvider)
            .restoreNoteRevision(note: note, revisionId: revisionId),
      );
    } finally {
      _noteRestoreBusy = false;
    }
  }
}

/// An entry's Restore button: its Key, and what a press does (given the
/// entry's context).
typedef _EntryRestore = ({Key key, void Function(BuildContext) onPressed});

/// Each agent change id to the newest of [revisions] (newest first, as
/// `(agentChangeId, revisionId)`) it produced. A revision whose change is
/// gone (null) maps to nothing.
Map<String, String> _revisionsByChange(Iterable<(String?, String)> revisions) {
  final out = <String, String>{};
  for (final (changeId, id) in revisions) {
    if (changeId != null) out.putIfAbsent(changeId, () => id);
  }
  return out;
}

final _activitySubtitleStyle = OmType.mono(
  size: 10.5,
  color: OmColors.fg2,
  height: 1.6,
);

class _ActivityEntry extends StatelessWidget {
  const _ActivityEntry({
    required this.entry,
    required this.restore,
    required this.feedback,
  });
  final AgentChangeRow entry;

  /// The entry's Restore button, or null (no revision of it is left, or the
  /// vault cannot restore it).
  final _EntryRestore? restore;
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
          Text(entry.day, style: OmType.mono(size: 10.5, color: OmColors.fg2)),
          const SizedBox(height: 6),
          for (final bullet in entry.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '· $bullet',
                style: OmType.sans(size: 12, color: OmColors.fg1, height: 1.5),
              ),
            ),
          if (restore case final r?)
            Align(
              alignment: Alignment.centerLeft,
              child: OmButton(
                key: r.key,
                kind: OmButtonKind.secondary,
                label: 'Restore',
                onPressed: () => r.onPressed(context),
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

/// Vault Guide Restore: `memex guide restore` for [revisionId] through
/// [flushThenWrite], which rebases the open editor on the restored text and
/// version, so the next save is not a conflict. Text typed once the restore
/// is running is newer than the restored text, so the editor keeps it on the
/// restored version, and it saves over that version (which stays a revision).
Future<void> _restoreGuide(
  BuildContext context,
  Note guide,
  String revisionId,
) => _restore(
  context,
  cancelKey: const Key('guide-restore-cancel'),
  confirmKey: const Key('guide-restore-confirm'),
  write: (container) => flushThenWrite(
    container,
    note: guide,
    // FeedbackActions bumps the vault revision once.
    write: () async =>
        (await container.read(feedbackActionsProvider).restoreGuide(revisionId))
            .version,
  ),
);

/// Restore: asks (dialog buttons [cancelKey] and [confirmKey]), then runs
/// [write], which stores the edit waiting on the save debounce, restores, and
/// rebases the open editor on the restored version (`flushThenWrite`). Reads
/// through a container taken before the awaits: the entry is gone once the
/// Activity tab shows another note. A failure shows its message in a
/// SnackBar.
Future<void> _restore(
  BuildContext context, {
  required Key cancelKey,
  required Key confirmKey,
  required Future<void> Function(ProviderContainer container) write,
}) async {
  final container = ProviderScope.containerOf(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) =>
        _RestoreDialog(cancelKey: cancelKey, confirmKey: confirmKey),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await guardVaultWrite(context, () async {
      // An edit still waiting on the save debounce is stored first, so the
      // restore keeps it as a revision (the dialog promises the current text
      // is kept). A failed save stops the restore: nothing is replaced, and
      // the editor's save error shows when it has one.
      try {
        await write(container);
      } on SaveFirstFailedException catch (e) {
        throw MemexException(e.saveError ?? e.message);
      }
    });
  } on Exception catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(e is MemexException ? e.message : '$e')),
    );
  }
}

class _RestoreDialog extends StatelessWidget {
  const _RestoreDialog({required this.cancelKey, required this.confirmKey});
  final Key cancelKey;
  final Key confirmKey;
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: const Text(_restoreConfirmText),
      actions: [
        TextButton(
          key: cancelKey,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: confirmKey,
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}
