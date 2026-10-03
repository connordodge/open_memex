import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../cli/prompt_cli.dart';
import '../../memex_cli.dart';
import '../../state/tabs_state.dart';
import '../../state/topic_actions.dart';
import '../../state/topics_state.dart';
import '../../state/topics_tree.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../inline_error.dart';

/// Req 53: the Topics empty-state copy.
const _emptyCopy =
    "Your agent hasn't reviewed anything yet. "
    'Run the review prompt from your agent to build Topics.';

/// Horizontal step per nesting level.
const _indentStep = 14.0;

/// The sidebar's Topics mode (Key `topics-pane`): a header action row
/// (`topics-actions`), the Smart Folder tree, and the implicit `Unsorted`
/// group last.
///
/// Folders start collapsed; the expansion state lives in memory only (see
/// `expandedTopicFoldersProvider`). Tapping a topic or an Unsorted note opens
/// its tab. With no Smart Folders and no topic notes the empty state
/// (`topics-empty`) shows above Unsorted, with a `Copy review prompt` button.
///
/// Fills the bounded height its parent gives it.
class TopicsPane extends ConsumerWidget {
  const TopicsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tree = ref.watch(smartFolderTreeProvider);
    final expanded = ref.watch(expandedTopicFoldersProvider);
    final activeTab = ref.watch(activeTabProvider);
    final activeNoteId = activeTab is NoteTab ? activeTab.id : null;

    void open(String noteId) =>
        ref.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));

    final rows = <Widget>[];
    void addFolder(FolderNode folder) {
      final isOpen = expanded.contains(folder.id);
      rows.add(
        _FolderRow(
          folder: folder,
          expanded: isOpen,
          onToggle: () =>
              ref.read(expandedTopicFoldersProvider.notifier).toggle(folder.id),
        ),
      );
      if (!isOpen) return;
      folder.children.forEach(addFolder);
      for (final topic in folder.topics) {
        rows.add(
          _NoteRow(
            key: Key('topics-topic-${folder.id}-${topic.noteId}'),
            title: topic.title,
            level: folder.depth + 1,
            active: topic.noteId == activeNoteId,
            pinGlyphKey: topic.pinned
                ? Key('pinned-glyph-member-${folder.id}-${topic.noteId}')
                : null,
            onTap: () => open(topic.noteId),
          ),
        );
      }
    }

    if (tree.isEmpty) rows.add(const _EmptyTopics());
    tree.folders.forEach(addFolder);
    if (tree.unsorted.notes.isNotEmpty) {
      rows.add(const _UnsortedRow());
      for (final note in tree.unsorted.notes) {
        rows.add(
          _NoteRow(
            key: Key('topics-unsorted-${note.noteId}'),
            title: note.title,
            level: 1,
            active: note.noteId == activeNoteId,
            onTap: () => open(note.noteId),
          ),
        );
      }
    }

    return Column(
      key: const Key('topics-pane'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ActionsRow(),
        const _NewTopicForm(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 12),
            children: rows,
          ),
        ),
      ],
    );
  }
}

/// The header action row. #25 adds `+ New Smart Folder` and `Graph`, and #26
/// added `+ New topic`, to [children].
class _ActionsRow extends StatelessWidget {
  const _ActionsRow();

  static const List<Widget> children = [_NewTopicButton()];

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('topics-actions'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        children: [const Eyebrow('topics'), const Spacer(), ...children],
      ),
    );
  }
}

/// Whether the `+ New topic` title form is showing.
final _newTopicOpenProvider = StateProvider<bool>((ref) => false);

/// `+ New topic` (Key `topics-new-topic`): shows or hides the title form.
class _NewTopicButton extends ConsumerWidget {
  const _NewTopicButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return OmButton(
      key: const Key('topics-new-topic'),
      kind: OmButtonKind.ghost,
      size: 24,
      icon: LucideIcons.plus,
      label: 'New topic',
      onPressed: () => ref.read(_newTopicOpenProvider.notifier).state = !ref
          .read(_newTopicOpenProvider),
    );
  }
}

/// The `+ New topic` title form (Req 17): a title field
/// (`new-topic-title-field`) and a confirm button (`new-topic-confirm`).
/// Confirming creates the topic note and links it from today's daily note
/// (see [createTopicFromSidebar]); a blank title does nothing. A failure
/// keeps the form open with the CLI message in a dismissible inline error.
class _NewTopicForm extends ConsumerStatefulWidget {
  const _NewTopicForm();

  @override
  ConsumerState<_NewTopicForm> createState() => _NewTopicFormState();
}

class _NewTopicFormState extends ConsumerState<_NewTopicForm> {
  final _title = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final title = _title.text.trim();
    if (title.isEmpty || _busy) return;
    final open = ref.read(_newTopicOpenProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await createTopicFromSidebar(ref, title);
      _title.clear();
      open.state = false;
    } catch (e) {
      // The note was created, only its link failed: a retry must not create
      // it again.
      if (e is TopicNotLinkedException) _title.clear();
      if (mounted) {
        setState(
          () => _error = switch (e) {
            MemexException() => e.message,
            TopicNotLinkedException() => e.message,
            _ => e.toString(),
          },
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(_newTopicOpenProvider)) return const SizedBox.shrink();
    final error = _error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null)
            InlineError(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('new-topic-title-field'),
                  controller: _title,
                  autofocus: true,
                  style: OmType.sans(size: 13, color: OmColors.fg0),
                  cursorColor: OmColors.accent,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Topic title',
                    hintStyle: OmType.sans(size: 13, color: OmColors.fg3),
                  ),
                  onSubmitted: (_) => _confirm(),
                ),
              ),
              const SizedBox(width: 8),
              OmButton(
                key: const Key('new-topic-confirm'),
                kind: OmButtonKind.primary,
                size: 26,
                label: 'Add',
                onPressed: _busy ? null : _confirm,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.expanded,
    required this.onToggle,
  });

  final FolderNode folder;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: Key('topics-folder-${folder.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            10 + folder.depth * _indentStep,
            6,
            10,
            6,
          ),
          child: Row(
            children: [
              Icon(
                expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                key: Key('topics-folder-toggle-${folder.id}'),
                size: 13,
                color: OmColors.fg2,
              ),
              const SizedBox(width: 6),
              const Icon(LucideIcons.folder, size: 13, color: OmColors.fg2),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(size: 13, color: OmColors.fg0),
                ),
              ),
              if (folder.pinned)
                Icon(
                  LucideIcons.pin,
                  key: Key('pinned-glyph-folder-${folder.id}'),
                  size: 11,
                  color: OmColors.fg2,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A topic row under a Smart Folder or a note row under Unsorted.
class _NoteRow extends StatelessWidget {
  const _NoteRow({
    super.key,
    required this.title,
    required this.level,
    required this.active,
    required this.onTap,
    this.pinGlyphKey,
  });

  final String title;

  /// Nesting level: 1 under a root folder or under Unsorted.
  final int level;
  final bool active;
  final VoidCallback onTap;

  /// Set when the membership is pinned; the glyph then carries this Key.
  final Key? pinGlyphKey;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(10 + level * _indentStep, 5, 10, 5),
          decoration: BoxDecoration(
            color: active ? OmColors.surface4 : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              const SizedBox(width: 11),
              const Icon(LucideIcons.fileText, size: 13, color: OmColors.fg1),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(
                    size: 13,
                    color: active ? OmColors.fg0 : OmColors.fg1,
                  ),
                ),
              ),
              if (pinGlyphKey != null)
                Icon(
                  LucideIcons.pin,
                  key: pinGlyphKey,
                  size: 11,
                  color: OmColors.fg2,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The implicit `Unsorted` group header (Req 39): not a Smart Folder, so it
/// has no toggle, no pin glyph and no menu. Its notes always show below it.
class _UnsortedRow extends StatelessWidget {
  const _UnsortedRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('topics-unsorted'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Row(
        children: [
          const Icon(LucideIcons.inbox, size: 13, color: OmColors.fg2),
          const SizedBox(width: 7),
          Text(
            'Unsorted',
            style: OmType.sans(
              size: 13,
              weight: FontWeight.w500,
              color: OmColors.fg2,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Topics empty state (Req 53, Key `topics-empty`): the message, the
/// `Copy review prompt` button and, after a failed copy, the CLI error.
class _EmptyTopics extends ConsumerStatefulWidget {
  const _EmptyTopics();

  @override
  ConsumerState<_EmptyTopics> createState() => _EmptyTopicsState();
}

class _EmptyTopicsState extends ConsumerState<_EmptyTopics> {
  String? _error;

  Future<void> _copy() async {
    setState(() => _error = null);
    final cli = ref.read(memexCliProvider);
    String? error;
    if (cli == null) {
      error = 'The memex CLI is not available.';
    } else {
      try {
        final text = await cli.reviewPrompt();
        await Clipboard.setData(ClipboardData(text: text));
      } on MemexException catch (e) {
        error = e.message;
      } catch (e) {
        error = e.toString();
      }
    }
    if (mounted) setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Padding(
      key: const Key('topics-empty'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _emptyCopy,
            style: OmType.sans(size: 12.5, color: OmColors.fg2, height: 1.5),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OmButton(
              key: const Key('copy-review-prompt'),
              kind: OmButtonKind.secondary,
              icon: LucideIcons.copy,
              label: 'Copy review prompt',
              onPressed: _copy,
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error,
              style: OmType.mono(size: 11, color: OmColors.danger, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
