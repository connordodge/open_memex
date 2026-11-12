import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../cli/feedback_cli.dart';
import '../../db.dart';
import '../../editor/markdown_preview_text.dart';
import '../../memex_cli.dart';
import '../../state/editor_controller.dart';
import '../../state/feedback_state.dart';
import '../../state/tabs_state.dart';
import '../../state/topic_actions.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
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

/// A block row: (topic note id, block id), with a null topic note id for a
/// Not filed row. A block can sit under several topic notes (`day_filing`
/// lists it under each), so fix state is kept per row, not per block.
typedef _RowId = (String?, String);

class _FiledSectionState extends ConsumerState<FiledSection> {
  /// The rows with a fix dialog open or a fix running: a second press on
  /// them does nothing.
  final Set<_RowId> _busy = {};

  /// The rows whose fix is running, with their in-flight label (`Moving`,
  /// `Removing` or `Filing`).
  final Map<_RowId, String> _inFlight = {};

  /// The inline error of each row whose last fix failed.
  final Map<_RowId, String> _errors = {};

  /// The focus nodes of the fix buttons and topic links, by name (see
  /// [_moveNode], [_removeNode], [_fileNode] and [_linkNode]), so focus can
  /// return to a button and move on after a fix took its row out.
  final Map<String, FocusNode> _nodes = {};

  /// The node names the last build used; the others are disposed after it.
  final Set<String> _used = {};
  bool _pruneScheduled = false;

  /// Each group as last built: its topic note id (null for Not filed) and
  /// its rows' block ids in order.
  List<(String?, List<String>)> _lastGroups = const [];

  FocusNode _node(String name) {
    _used.add(name);
    return _nodes.putIfAbsent(name, () => FocusNode(debugLabel: name));
  }

  FocusNode _moveNode(_RowId id) => _node('move ${id.$1} ${id.$2}');
  FocusNode _removeNode(_RowId id) => _node('remove ${id.$1} ${id.$2}');
  FocusNode _fileNode(String blockId) => _node('file $blockId');
  FocusNode _linkNode(String topicNoteId) => _node('link $topicNoteId');

  /// The first fix button of the row [id].
  FocusNode _firstButton(_RowId id) =>
      id.$1 == null ? _fileNode(id.$2) : _moveNode(id);

  /// Whether a fix button of the row [id] has the focus (without creating a
  /// node for it).
  bool _rowHasFocus(_RowId id) {
    final names = id.$1 == null
        ? ['file ${id.$2}']
        : ['move ${id.$1} ${id.$2}', 'remove ${id.$1} ${id.$2}'];
    return names.any((n) => _nodes[n]?.hasFocus ?? false);
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Disposes, after the frame, the nodes the last build did not use (their
  /// widgets are gone by then).
  void _schedulePrune() {
    if (_pruneScheduled) return;
    _pruneScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pruneScheduled = false;
      if (!mounted) return;
      _nodes.removeWhere((name, node) {
        if (_used.contains(name)) return false;
        node.dispose();
        return true;
      });
    });
  }

  /// When a row whose fix button has the focus is gone from [groups] (a
  /// keyboard-run fix took it out), moves the focus to the first fix button
  /// of the row that followed it in its group, else to the group's topic
  /// link, else to the section's first focus stop.
  void _moveFocusFromGoneRow(List<(String?, List<String>)> groups) {
    for (final (group, blocks) in _lastGroups) {
      final now = groups.where((g) => g.$1 == group).firstOrNull?.$2;
      for (final (i, block) in blocks.indexed) {
        if (now != null && now.contains(block)) continue;
        if (!_rowHasFocus((group, block))) continue;
        final next = blocks.skip(i + 1).where((b) => now?.contains(b) ?? false);
        final FocusNode? target;
        if (next.isNotEmpty) {
          target = _firstButton((group, next.first));
        } else if (group != null && now != null) {
          target = _linkNode(group);
        } else if (groups.isEmpty) {
          target = null;
        } else {
          final (first, rows) = groups.first;
          target = first != null
              ? _linkNode(first)
              : _firstButton((null, rows.first));
        }
        if (target case final node?) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && node.context != null) node.requestFocus();
          });
        }
        return;
      }
    }
  }

  /// Gives the focus back to the fix button [node] once its dialog closed.
  void _refocus(FocusNode node) {
    if (mounted && node.context != null) node.requestFocus();
  }

  /// What a fix keeps from the moment its row was pressed.
  _Press get _press {
    final container = ProviderScope.containerOf(context);
    return _Press(widget.note, container, container.read(currentVaultProvider));
  }

  Future<List<TopicChoice>> _loadTopics(ProviderContainer container) async {
    final access = container.read(vaultAccessProvider);
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

  /// Opens the dialog of a fix on the row [id] pressed through [button],
  /// then runs [fix] with its result. Does nothing while the row has a
  /// dialog open or a fix running. A dialog closed without a fix gives the
  /// focus back to [button]; so does a confirmed one opened from the
  /// keyboard (the button had the focus), which keeps it there while the fix
  /// runs (a disabled focusable button stays a focus stop).
  Future<void> _open<R>(
    _RowId id,
    FocusNode button,
    Future<R?> Function() dialog,
    Future<void> Function(R picked) fix,
  ) async {
    if (_inFlight.containsKey(id) || !_busy.add(id)) return;
    try {
      final byKeyboard = button.hasPrimaryFocus;
      final picked = await dialog();
      if (picked == null || byKeyboard) _refocus(button);
      if (picked != null) await fix(picked);
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> _moveTo(FilingTopic from, FilingBlock block) {
    final id = (from.topicNoteId, block.id);
    final press = _press;
    return _open(
      id,
      _moveNode(id),
      () => showTopicPickDialog(
        context,
        title: 'Move to…',
        confirmLabel: 'Move',
        loadTopics: () => _loadTopics(press.container),
        blockText: block.text,
        fromTopicTitle: from.title,
        excludeId: from.topicNoteId,
      ),
      (picked) => _run(
        press,
        id,
        'Moving',
        picked,
        (read, target) => read(feedbackActionsProvider).moveBlock(
          fromTopicNoteId: from.topicNoteId,
          toTopicNoteId: target!,
          date: press.daily.title,
          blockId: block.id,
          note: picked.why,
        ),
      ),
    );
  }

  Future<void> _remove(FilingTopic from, FilingBlock block) {
    final id = (from.topicNoteId, block.id);
    final press = _press;
    return _open(
      id,
      _removeNode(id),
      () => showRemoveBlockDialog(
        context,
        topicTitle: from.title,
        blockText: block.text,
      ),
      (picked) => _run(
        press,
        id,
        'Removing',
        null,
        (read, _) => read(feedbackActionsProvider).removeBlock(
          topicNoteId: from.topicNoteId,
          date: press.daily.title,
          blockId: block.id,
          note: picked.why,
        ),
      ),
    );
  }

  Future<void> _fileIn(FilingBlock block) {
    final _RowId id = (null, block.id);
    final press = _press;
    return _open(
      id,
      _fileNode(block.id),
      () => showTopicPickDialog(
        context,
        title: 'File in…',
        confirmLabel: 'File',
        loadTopics: () => _loadTopics(press.container),
        blockText: block.text,
      ),
      (picked) => _run(
        press,
        id,
        'Filing',
        picked,
        (read, target) => read(feedbackActionsProvider).fileBlock(
          topicNoteId: target!,
          date: press.daily.title,
          blockId: block.id,
          note: picked.why,
        ),
      ),
    );
  }

  /// Runs a fix on the row [id] of the day [daily]: the row is in flight
  /// meanwhile, showing [label], a failure becomes the row's inline error, and a fix that worked
  /// on the open daily note rebases the editor on the note's new version (D23).
  /// A rebase that fails is not a failure of the fix, which already went
  /// through: the row comes back and shows no error.
  ///
  /// [press] is taken before the dialog opens: the section can show another
  /// day, or be gone, by the time the person confirms. The person confirmed
  /// the fix, so it still runs, on the pressed day; only the UI updates are
  /// skipped. The exception is a vault that is no longer the pressed one: the
  /// block is not in the vault now open, so nothing is written.
  ///
  /// With a [picked] `Create "<name>"`, the topic note is created first (and
  /// stays when [write] then fails); [write] gets a reader and the target
  /// topic note id (null without [picked]). The write bumps
  /// `vaultRevisionProvider` itself (`FeedbackActions`): nothing here bumps.
  ///
  /// Everything reads through the press's container: the right-panel tab can
  /// change while the fix runs, and the rebase must still happen (the pending
  /// edit would else hit a version conflict on its next save).
  Future<void> _run(
    _Press press,
    _RowId id,
    String label,
    TopicPickResult? picked,
    Future<Object?> Function(
      T Function<T>(ProviderListenable<T> provider) read,
      String? target,
    )
    write,
  ) async {
    final container = press.container;
    if (container.read(currentVaultProvider) != press.vault) return;
    if (_inFlight.containsKey(id)) return;
    _inFlight[id] = label;
    // The next fix on a failed row clears its error as it starts.
    if (mounted) setState(() => _errors.remove(id));
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
    if (worked) {
      try {
        await _rebaseDaily(container, press.daily);
      } on Object {
        // The fix went through and its bump refreshes the section. The editor
        // stays on its base: a later save reports the conflict if there is one.
      }
    }
    _inFlight.remove(id);
    if (mounted) setState(() {});
  }

  /// [guardVaultWrite] while mounted (its snackbar needs the context); a bare
  /// run once the section is gone.
  Future<T?> _guarded<T>(Future<T> Function() write) =>
      mounted ? guardVaultWrite(context, write) : write();

  /// Opens the topic note [topicNoteId] as Connections rows do: in place, or
  /// in a tab with the new-tab modifier held.
  void _follow(String topicNoteId) =>
      ref.read(tabsProvider.notifier).follow(NoteTab(topicNoteId));

  /// The fix buttons of the row [id]: icon-only 24 px ghost buttons that
  /// stay focus stops while disabled.
  OmButton _fixButton({
    required Key key,
    required _RowId id,
    required FocusNode node,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) => OmButton(
    key: key,
    kind: OmButtonKind.ghost,
    size: 24,
    icon: icon,
    iconSize: 13,
    hoverBackground: OmColors.surface4,
    focusable: true,
    focusNode: node,
    tooltip: tooltip,
    onPressed: _inFlight.containsKey(id) ? null : onPressed,
  );

  _BlockRow _row({
    required _RowId id,
    required Key key,
    required FilingBlock block,
    required bool last,
    required List<OmButton> buttons,
  }) => _BlockRow(
    key: ValueKey<_RowId>(id),
    rowKey: key,
    text: block.text,
    last: last,
    inFlight: _inFlight[id],
    error: _errors[id],
    onDismissError: () => setState(() => _errors.remove(id)),
    buttons: buttons,
  );

  @override
  Widget build(BuildContext context) {
    final filing = watchFilingToShow(ref, widget.note);
    _used.clear();
    _schedulePrune();
    if (filing == null) {
      _lastGroups = const [];
      return const SizedBox.shrink();
    }
    final topics = [
      for (final topic in filing.topics)
        if (topic.blocks.isNotEmpty) topic,
    ];
    final groups = <(String?, List<String>)>[
      for (final topic in topics)
        (topic.topicNoteId, [for (final b in topic.blocks) b.id]),
      if (filing.notFiled.isNotEmpty)
        (null, [for (final b in filing.notFiled) b.id]),
    ];
    _moveFocusFromGoneRow(groups);
    _lastGroups = groups;
    final shown =
        topics.fold(0, (n, t) => n + t.blocks.length) + filing.notFiled.length;
    return Column(
      key: const Key('filed-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(blocks: shown),
        for (final topic in topics)
          _Group(
            header: _TopicLink(
              key: Key('filed-topic-link-${topic.topicNoteId}'),
              focusNode: _linkNode(topic.topicNoteId),
              title: topic.title,
              blocks: topic.blocks.length,
              onFollow: () => _follow(topic.topicNoteId),
            ),
            rows: [
              for (final (i, block) in topic.blocks.indexed)
                if ((topic.topicNoteId, block.id) case final id)
                  _row(
                    id: id,
                    key: Key('filed-row-${topic.topicNoteId}-${block.id}'),
                    block: block,
                    last: i == topic.blocks.length - 1,
                    buttons: [
                      _fixButton(
                        key: Key('filed-move-${topic.topicNoteId}-${block.id}'),
                        id: id,
                        node: _moveNode(id),
                        icon: LucideIcons.arrowRightLeft,
                        tooltip: 'Move to…',
                        onPressed: () => _moveTo(topic, block),
                      ),
                      _fixButton(
                        key: Key(
                          'filed-remove-${topic.topicNoteId}-${block.id}',
                        ),
                        id: id,
                        node: _removeNode(id),
                        icon: LucideIcons.x,
                        tooltip: 'Remove from ${topic.title}',
                        onPressed: () => _remove(topic, block),
                      ),
                    ],
                  ),
            ],
          ),
        if (filing.notFiled.isNotEmpty)
          _Group(
            header: _NotFiledHeader(blocks: filing.notFiled.length),
            rows: [
              for (final (i, block) in filing.notFiled.indexed)
                _row(
                  id: (null, block.id),
                  key: Key('not-filed-row-${block.id}'),
                  block: block,
                  last: i == filing.notFiled.length - 1,
                  buttons: [
                    _fixButton(
                      key: Key('file-in-${block.id}'),
                      id: (null, block.id),
                      node: _fileNode(block.id),
                      icon: LucideIcons.folderInput,
                      tooltip: 'File in…',
                      onPressed: () => _fileIn(block),
                    ),
                  ],
                ),
            ],
          ),
        // The last group ends on its 8 px bottom padding: the closing
        // hairline follows it directly.
        const OmHairline(),
      ],
    );
  }
}

/// See [_FiledSectionState._press].
class _Press {
  const _Press(this.daily, this.container, this.vault);

  /// The note whose row was pressed.
  final Note daily;

  /// Stays usable when the section is gone.
  final ProviderContainer container;

  /// The vault open at the press.
  final VaultRef? vault;
}

/// `<n> block` or `<n> blocks`.
String _blocks(int n) => n == 1 ? '$n block' : '$n blocks';

/// The section's eyebrow and `· <n> BLOCKS` on one line, then the explainer.
/// The count wraps under the eyebrow when both do not fit (the shared
/// `PanelHeader` is a one-line row).
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.blocks});

  /// The block rows the section shows.
  final int blocks;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Filed from this day'.toUpperCase(), style: OmType.eyebrow()),
            Text(
              '· ${_blocks(blocks)}'.toUpperCase(),
              style: OmType.mono(
                size: 10.5,
                color: OmColors.fg2,
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(
          'Where the agent filed this day’s blocks. Move or remove one and '
          'the agent learns from your fix on its next review.',
          style: OmType.sans(size: 12, color: OmColors.fg2),
        ),
      ),
    ],
  );
}

/// One group: a line1 hairline, then its [header] and [rows] with 4 px top
/// and 8 px bottom padding.
class _Group extends StatelessWidget {
  const _Group({required this.header, required this.rows});

  final Widget header;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const OmHairline(),
      Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, ...rows],
        ),
      ),
    ],
  );
}

/// The title style of a group header row, underlined in its own [color]
/// when [underline].
TextStyle _titleStyle(Color color, {bool underline = false}) =>
    OmType.sans(
      size: 13,
      weight: FontWeight.w500,
      color: color,
      height: 1.4,
    ).copyWith(
      decoration: underline ? TextDecoration.underline : TextDecoration.none,
      decorationColor: color,
    );

/// A group header row: [icon], the [title] on one line, its digits-only
/// [blocks] count 8 px after the title, and [trailing] at the right edge.
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.icon,
    required this.title,
    required this.blocks,
    this.trailing,
  });

  final IconData icon;
  final Text title;
  final int blocks;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 7, 12, 7),
    child: Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Icon(icon, size: 12, color: OmColors.fg2),
              const SizedBox(width: 8),
              Flexible(child: title),
              const SizedBox(width: 8),
              Text(
                '$blocks',
                style: OmType.mono(
                  size: 10.5,
                  color: OmColors.fg2,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

/// A topic group's header: a link to the topic note, drawn like a wikilink
/// (Spec #393 requirements 3-5). A focus stop; a click, a semantics tap,
/// and Enter or Space call [onFollow]. A held key calls it once, and
/// Cmd+Enter is not bound.
class _TopicLink extends StatefulWidget {
  const _TopicLink({
    super.key,
    required this.focusNode,
    required this.title,
    required this.blocks,
    required this.onFollow,
  });

  /// Owned by the section, which moves focus here after a fix took the
  /// group's last focused row out.
  final FocusNode focusNode;
  final String title;
  final int blocks;
  final VoidCallback onFollow;

  @override
  State<_TopicLink> createState() => _TopicLinkState();
}

class _TopicLinkState extends State<_TopicLink> {
  bool _hover = false;
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isMetaPressed) return KeyEventResult.ignored;
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // A repeat is swallowed: a held key follows once.
    if (event is KeyDownEvent) widget.onFollow();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    link: true,
    focusable: true,
    focused: _focused,
    label: '${widget.title}, ${_blocks(widget.blocks)}',
    onTap: widget.onFollow,
    excludeSemantics: true,
    child: Focus(
      focusNode: widget.focusNode,
      onFocusChange: (focused) => setState(() => _focused = focused),
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onFollow,
          child: CustomPaint(
            foregroundPainter: _focused ? const _FocusRingPainter() : null,
            child: ColoredBox(
              color: _hover ? OmColors.surface3 : Colors.transparent,
              child: _HeaderRow(
                icon: LucideIcons.fileText,
                title: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _titleStyle(OmColors.accent, underline: _hover),
                ),
                blocks: widget.blocks,
                // The arrow's space is kept at rest, so hovering never
                // narrows the title.
                trailing: _hover
                    ? const Icon(
                        LucideIcons.arrowUpRight,
                        size: 12,
                        color: OmColors.fg2,
                      )
                    : const SizedBox(width: 12, height: 12),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A 2 px accent ring inset by 2 px.
class _FocusRingPainter extends CustomPainter {
  const _FocusRingPainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(
    (Offset.zero & size).deflate(3),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = OmColors.accent,
  );

  @override
  bool shouldRepaint(_FocusRingPainter oldDelegate) => false;
}

/// The Not filed group's header: the topic link's geometry, but a plain
/// header (no hover, no arrow, no focus stop, no link semantics).
class _NotFiledHeader extends StatelessWidget {
  const _NotFiledHeader({required this.blocks});

  final int blocks;

  @override
  Widget build(BuildContext context) => _HeaderRow(
    icon: LucideIcons.inbox,
    title: Text(
      'Not filed',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _titleStyle(OmColors.fg1),
    ),
    blocks: blocks,
  );
}

/// The preview's style: 12.5 px, line height 1.45.
const double _previewSize = 12.5;
const double _previewHeight = 1.45;

/// The vertical padding of the preview inside the row's 3 px padding
/// (board: one-line rows 31 px tall at 1x).
const double _previewPad = 3;

/// The gap between the preview and the fix buttons' column.
const double _columnGap = 6;

/// One block on its group's tree rail: the plain-text preview of its
/// markdown on up to two lines (the full plain text in a tooltip), then the
/// column of its fix [buttons], right-aligned and centred on the preview's
/// first line at every text scale. The buttons are hidden at rest, keeping
/// their space, and blocked to the pointer, but stay focus stops and
/// semantics buttons; they show, over a surface2 row, while the pointer is
/// over the row, a control in it has the focus, its fix runs ([inFlight],
/// with a spinner and the label left of the column over the end of the
/// preview's first line, which does not reflow) or its last fix failed
/// ([error], shown under the row, outside it, indented 36 px).
class _BlockRow extends StatefulWidget {
  const _BlockRow({
    super.key,
    required this.rowKey,
    required this.text,
    required this.last,
    required this.buttons,
    required this.inFlight,
    required this.error,
    required this.onDismissError,
  });

  /// The key of the row box (the error under it is not part of it).
  final Key rowKey;

  /// The block's markdown.
  final String text;

  /// The group's last row: its rail stops at its tick.
  final bool last;
  final List<Widget> buttons;

  /// The label of the fix running on the row, or null.
  final String? inFlight;
  final String? error;
  final VoidCallback onDismissError;

  @override
  State<_BlockRow> createState() => _BlockRowState();
}

class _BlockRowState extends State<_BlockRow> {
  bool _hover = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final preview = markdownPreviewText(widget.text);
    final revealed =
        _hover || _focused || widget.inFlight != null || widget.error != null;
    final line =
        MediaQuery.textScalerOf(context).scale(_previewSize) * _previewHeight;
    // The buttons' top, centring them on the preview's first line.
    final top = max(0.0, _previewPad + line / 2 - 12);
    final column =
        24.0 * widget.buttons.length + 2 * (widget.buttons.length - 1);
    final inFlight = widget.inFlight;
    final row = Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: ColoredBox(
          key: widget.rowKey,
          color: revealed ? OmColors.surface2 : Colors.transparent,
          child: CustomPaint(
            painter: _RailPainter(last: widget.last),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 30),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(36, 3, 10, 3),
                child: Stack(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: _previewPad,
                            ),
                            child: Tooltip(
                              message: preview,
                              child: Text(
                                preview,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: OmType.sans(
                                  size: _previewSize,
                                  height: _previewHeight,
                                  color: OmColors.fg1,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: _columnGap),
                        // 25 px at least: a one-line row is 31 px at 1x.
                        SizedBox(
                          height: max(25.0, top + 24),
                          child: Padding(
                            padding: EdgeInsets.only(top: top),
                            child: Opacity(
                              opacity: revealed ? 1 : 0,
                              alwaysIncludeSemantics: true,
                              child: _PointerBlock(
                                blocking: !revealed,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final (i, b)
                                        in widget.buttons.indexed) ...[
                                      if (i > 0) const SizedBox(width: 2),
                                      b,
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (inFlight != null)
                      Positioned(
                        top: top,
                        right: column,
                        height: 24,
                        child: _InFlight(label: inFlight),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final error = widget.error;
    // One root shape with or without the error: swapping the root would
    // rebuild the row, and its focused fix button would lose its ring.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 2, 10, 0),
            child: InlineError(
              message: error,
              onDismiss: widget.onDismissError,
            ),
          ),
      ],
    );
  }
}

/// A running fix: a 14 px accent spinner, a 6 px gap and [label] (mono
/// 10.5, fg2, also the semantics label) on a surface2 backing that covers
/// the preview under it.
class _InFlight extends StatelessWidget {
  const _InFlight({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: label,
    excludeSemantics: true,
    child: ColoredBox(
      color: OmColors.surface2,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Spinner(
            child: Icon(
              LucideIcons.loaderCircle,
              size: 14,
              color: OmColors.accent,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: OmType.mono(size: 10.5, color: OmColors.fg2),
          ),
        ],
      ),
    ),
  );
}

/// Turns [child] once a second, in paint only: its layout box, and so its
/// geometry, does not rotate.
class _Spinner extends StatefulWidget {
  const _Spinner({required this.child});

  final Widget child;

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _turns,
    builder: (_, child) => _PaintRotation(turns: _turns.value, child: child),
    child: widget.child,
  );
}

/// Paints [child] turned by [turns] about its centre, without changing its
/// layout or hit-test geometry.
class _PaintRotation extends SingleChildRenderObjectWidget {
  const _PaintRotation({required this.turns, super.child});

  final double turns;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintRotation(turns);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaintRotation renderObject,
  ) => renderObject.turns = turns;
}

class _RenderPaintRotation extends RenderProxyBox {
  _RenderPaintRotation(this._turns);

  double _turns;
  set turns(double value) {
    if (value == _turns) return;
    _turns = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    final c = size.center(Offset.zero);
    final transform = Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(Matrix4.rotationZ(_turns * 2 * pi))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
    context.pushTransform(needsCompositing, offset, transform, super.paint);
  }
}

/// Lets no pointer event reach [child] while [blocking]; its semantics (and
/// semantics taps) are untouched, unlike an [IgnorePointer].
class _PointerBlock extends SingleChildRenderObjectWidget {
  const _PointerBlock({required this.blocking, super.child});

  final bool blocking;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPointerBlock(blocking);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPointerBlock renderObject,
  ) => renderObject.blocking = blocking;
}

class _RenderPointerBlock extends RenderProxyBox {
  _RenderPointerBlock(this.blocking);

  bool blocking;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      !blocking && super.hitTest(result, position: position);
}

/// A block row's piece of the tree rail: 1 px line3 at x 21 down the row
/// (only down to the tick on the [last] row) and a 9 px tick at y 14. Fixed
/// pixels: they do not follow the text scale.
class _RailPainter extends CustomPainter {
  const _RailPainter({required this.last});

  final bool last;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = OmColors.line3;
    canvas
      ..drawRect(Rect.fromLTRB(21, 0, 22, last ? 15 : size.height), paint)
      ..drawRect(const Rect.fromLTRB(22, 14, 30, 15), paint);
  }

  @override
  bool shouldRepaint(_RailPainter oldDelegate) => oldDelegate.last != last;
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
