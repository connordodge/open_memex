import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli/feedback_cli.dart';
import '../../db.dart';
import '../../memex_cli.dart';
import '../../state/editor_controller.dart';
import '../../state/feedback_state.dart';
import '../../state/note_state.dart';
import '../../state/topic_actions.dart';
import '../../state/vault_access_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/errors.dart';
import '../atoms.dart';
import '../inline_error.dart';
import 'topic_pick_dialog.dart';

/// The `Filing` the `Filed from this day` section shows for [note], or null
/// when the section is hidden: a note that is not a daily note, a vault below
/// V6 (no filing), a day that was never reviewed, or a day with nothing to
/// list. Watches `filingProvider`, so it follows every revision bump.
Filing? watchFilingToShow(WidgetRef ref, Note? note) {
  if (note == null || note.role != 'daily') return null;
  final filing = watchVaultValue<Filing?>(
    ref,
    filingProvider(note.title),
    null,
  );
  if (filing == null || !filing.reviewed) return null;
  final listed =
      filing.notFiled.isNotEmpty ||
      filing.topics.any((t) => t.blocks.isNotEmpty);
  return listed ? filing : null;
}

/// The `Filed from this day` section at the top of a daily note's Activity
/// tab (Spec #233, R6-R10): where the blocks of the day are filed, with
/// `Move to…`, `Remove` and `File in…` fixes. Renders nothing when
/// [watchFilingToShow] has nothing to show. Lays out in a non-scrolling
/// column, for any height.
class FiledSection extends ConsumerStatefulWidget {
  const FiledSection({super.key, required this.note});

  /// The selected note of the Activity tab.
  final Note note;

  @override
  ConsumerState<FiledSection> createState() => _FiledSectionState();
}

class _FiledSectionState extends ConsumerState<FiledSection> {
  /// Ids of the blocks whose fix is running.
  final Set<String> _inFlight = {};

  /// The inline error of each block whose last fix failed.
  final Map<String, String> _errors = {};

  Future<List<TopicChoice>> _loadTopics() async {
    final access = ref.read(vaultAccessProvider);
    if (access == null) return const [];
    final folders = await access.topics.smartFolders();
    final unsorted = await access.topics.unsortedNotes();
    final topics = <String, String>{
      for (final n in unsorted)
        if (n.role == 'topic') n.noteId: n.title,
    };
    // A Smart Folder member row has no role: read the note.
    final members = <String, String>{
      for (final m in folders.members)
        if (!topics.containsKey(m.noteId)) m.noteId: m.title,
    };
    final checked = await Future.wait(
      members.entries.map((e) async {
        final note = await access.notes.getNote(e.key);
        return note?.role == 'topic' ? e : null;
      }),
    );
    for (final e in checked) {
      if (e != null) topics[e.key] = e.value;
    }
    return [
      for (final e in topics.entries) TopicChoice(id: e.key, title: e.value),
    ];
  }

  Future<void> _moveTo(FilingTopic from, FilingBlock block) async {
    if (_inFlight.contains(block.id)) return;
    final picked = await showTopicPickDialog(
      context,
      title: 'Move to…',
      confirmLabel: 'Move',
      loadTopics: _loadTopics,
      excludeId: from.topicNoteId,
    );
    if (picked == null || !mounted) return;
    await _run(
      block.id,
      picked,
      (read, target) => read(feedbackActionsProvider).moveBlock(
        fromTopicNoteId: from.topicNoteId,
        toTopicNoteId: target!,
        date: widget.note.title,
        blockId: block.id,
        note: picked.why,
      ),
    );
  }

  Future<void> _remove(FilingTopic from, FilingBlock block) async {
    if (_inFlight.contains(block.id)) return;
    final picked = await showRemoveBlockDialog(context);
    if (picked == null || !mounted) return;
    await _run(
      block.id,
      null,
      (read, _) => read(feedbackActionsProvider).removeBlock(
        topicNoteId: from.topicNoteId,
        date: widget.note.title,
        blockId: block.id,
        note: picked.why,
      ),
    );
  }

  Future<void> _fileIn(FilingBlock block) async {
    if (_inFlight.contains(block.id)) return;
    final picked = await showTopicPickDialog(
      context,
      title: 'File in…',
      confirmLabel: 'File',
      loadTopics: _loadTopics,
    );
    if (picked == null || !mounted) return;
    await _run(
      block.id,
      picked,
      (read, target) => read(feedbackActionsProvider).fileBlock(
        topicNoteId: target!,
        date: widget.note.title,
        blockId: block.id,
        note: picked.why,
      ),
    );
  }

  /// Runs a fix for the block [id]: its row is in flight meanwhile, a failure
  /// becomes the row's inline error, and a fix that worked on the open daily
  /// note rebases the editor on the note's new version (D23).
  ///
  /// With a [picked] `Create "<name>"`, the topic note is created first (and
  /// stays when [write] then fails); [write] gets a reader and the target
  /// topic note id (null without [picked]). The write bumps
  /// `vaultRevisionProvider` itself (`FeedbackActions`): nothing here bumps.
  ///
  /// Everything after the first await reads through a container taken up
  /// front: the right-panel tab can change while the fix runs, and the
  /// rebase must still happen (the pending edit would else hit a version
  /// conflict on its next save).
  Future<void> _run(
    String id,
    TopicPickResult? picked,
    Future<Object?> Function(
      T Function<T>(ProviderListenable<T> provider) read,
      String? target,
    )
    write,
  ) async {
    if (!_inFlight.add(id)) return;
    final container = ProviderScope.containerOf(context);
    final daily = widget.note;
    setState(() => _errors.remove(id));
    var worked = false;
    try {
      var target = picked?.topicNoteId;
      final createTitle = picked?.createTitle;
      if (createTitle != null) {
        target = await _guarded(
          () => container
              .read(vaultAccessProvider)!
              .notes
              .addNote(
                title: createTitle,
                contentMd: topicNoteBody(createTitle),
                role: 'topic',
              ),
        );
      }
      if (picked == null || target != null) {
        final result = await _guarded(() => write(container.read, target));
        worked = result != null;
      }
    } on MemexException catch (e) {
      // `block_not_found`: the block was fixed elsewhere meanwhile. The bump
      // after the write refreshes the section; nothing else to say.
      if (e.code != 'block_not_found' && mounted) {
        setState(() => _errors[id] = e.message);
      }
    } catch (e) {
      if (mounted) setState(() => _errors[id] = e.toString());
    }
    if (worked) await _rebaseDaily(container, daily);
    _inFlight.remove(id);
    if (mounted) setState(() {});
  }

  /// [guardVaultWrite] while mounted (its snackbar needs the context); a bare
  /// run once the section is gone.
  Future<T?> _guarded<T>(Future<T> Function() write) =>
      mounted ? guardVaultWrite(context, write) : write();

  @override
  Widget build(BuildContext context) {
    final filing = watchFilingToShow(ref, widget.note);
    if (filing == null) return const SizedBox.shrink();
    return Column(
      key: const Key('filed-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(),
        for (final topic in filing.topics)
          if (topic.blocks.isNotEmpty) ...[
            _GroupTitle(topic.title),
            for (final block in topic.blocks)
              _BlockRow(
                key: Key('filed-row-${topic.topicNoteId}-${block.id}'),
                text: block.text,
                error: _errors[block.id],
                onDismissError: () => setState(() => _errors.remove(block.id)),
                buttons: [
                  OmButton(
                    key: Key('filed-move-${topic.topicNoteId}-${block.id}'),
                    size: 24,
                    dense: true,
                    label: 'Move to…',
                    onPressed: _inFlight.contains(block.id)
                        ? null
                        : () => _moveTo(topic, block),
                  ),
                  OmButton(
                    key: Key('filed-remove-${topic.topicNoteId}-${block.id}'),
                    size: 24,
                    dense: true,
                    kind: OmButtonKind.ghost,
                    label: 'Remove',
                    onPressed: _inFlight.contains(block.id)
                        ? null
                        : () => _remove(topic, block),
                  ),
                ],
              ),
          ],
        if (filing.notFiled.isNotEmpty) ...[
          const _GroupTitle('Not filed'),
          for (final block in filing.notFiled)
            _BlockRow(
              key: Key('not-filed-row-${block.id}'),
              text: block.text,
              error: _errors[block.id],
              onDismissError: () => setState(() => _errors.remove(block.id)),
              buttons: [
                OmButton(
                  key: Key('file-in-${block.id}'),
                  size: 24,
                  dense: true,
                  label: 'File in…',
                  onPressed: _inFlight.contains(block.id)
                      ? null
                      : () => _fileIn(block),
                ),
              ],
            ),
        ],
        const SizedBox(height: 8),
        const OmHairline(),
      ],
    );
  }
}

/// The section's eyebrow. Wraps instead of overflowing (the shared
/// `PanelHeader` is a one-line row).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Text('Filed from this day'.toUpperCase(), style: OmType.eyebrow()),
  );
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
    child: Text(
      title,
      style: OmType.sans(
        size: 13,
        weight: FontWeight.w600,
        color: OmColors.fg0,
      ),
    ),
  );
}

/// One block: its preview on one line (full text in a tooltip), then the
/// fix buttons, which wrap under the preview at a narrow width.
class _BlockRow extends StatelessWidget {
  const _BlockRow({
    super.key,
    required this.text,
    required this.buttons,
    required this.error,
    required this.onDismissError,
  });

  final String text;
  final List<Widget> buttons;
  final String? error;
  final VoidCallback onDismissError;

  @override
  Widget build(BuildContext context) {
    final quoted = '"$text"';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: quoted,
            child: Text(
              quoted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.sans(size: 12, color: OmColors.fg1),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 6, children: buttons),
          if (error != null) ...[
            const SizedBox(height: 6),
            InlineError(message: error!, onDismiss: onDismissError),
          ],
        ],
      ),
    );
  }
}

/// Rebases the editor on [daily]'s new version after a fix changed the note
/// on the server, when [daily] is the editor's active note and its stored
/// version moved past the last one the editor saved (D23). Over [container]
/// so it still runs after the section unmounted.
Future<void> _rebaseDaily(ProviderContainer container, Note daily) async {
  final editor = container.read(editorControllerProvider.notifier);
  if (editor.activeNoteId != daily.id) return;
  final stored = await container
      .read(vaultAccessProvider)
      ?.notes
      .getNote(daily.id);
  if (stored == null || editor.activeNoteId != daily.id) return;
  final state = container.read(editorControllerProvider);
  if (stored.version <= (state.lastSavedVersion ?? stored.version)) return;
  await rebaseEditorOnVersionIn(
    container,
    fallback: daily,
    version: stored.version,
    content: state.contentMd,
  );
}
