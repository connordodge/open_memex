import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../db.dart';
import '../../db/daily_reads.dart';
import '../../memex_cli.dart';
import '../../state/daily_state.dart';
import '../../state/tabs_state.dart';
import '../../state/tags_browse_state.dart';
import '../../state/tags_state.dart';
import '../../state/today_state.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/vault_scoped.dart';
import '../inline_error.dart';

/// A note's Note footer (Key `footer-chip-row`, Spec #234, board B3): two
/// aligned rows of plain text. Topics has one item per footer topic of [note]
/// (Key `footer-chip-<topicNoteId>`), each opening its topic note; Tags has one
/// item per `footerTags` entry (Key `footer-tag-<tag>`), each revealing its tag
/// in Tags mode. A row with no items is left out; with neither, nothing renders.
/// Never a text field.
///
/// Rows decide what shows, not the note's footer text: a backfilled note has
/// rows and no marker until its next footer write (L10).
///
/// Key this per note: what it holds (writes in flight, the error, removed tags)
/// belongs to one note.
class FooterChipBar extends ConsumerStatefulWidget {
  const FooterChipBar({
    super.key,
    required this.note,
    required this.onFocusEditor,
  });

  /// The note shown. Its tags stand in only until the editor's own read has
  /// this note: the host's copy doesn't change while the note stays open.
  final Note note;

  /// Gives the editor keyboard focus: a focused × left the row and no other ×
  /// is left to take it.
  final VoidCallback onFocusEditor;

  @override
  ConsumerState<FooterChipBar> createState() => _FooterChipBarState();
}

class _FooterChipBarState extends ConsumerState<FooterChipBar> {
  /// Tags whose remove write is out.
  final _removing = <String>{};

  /// Tags removed by a write that returned, hidden until the next good read of
  /// the note: a read that fails after the write would otherwise leave them on
  /// the row. A tag the vault gets back after that read shows again.
  final _removed = <String>{};

  String? _error;

  /// The focus node of each tag's ×, kept for the bar's life: a removed tag the
  /// vault gets back uses its node again.
  final _xFocus = <String, FocusNode>{};

  /// The tags as last built, in row order.
  List<String> _shownTags = const [];

  FocusNode _xFocusOf(String tag) => _xFocus.putIfAbsent(
    tag,
    () => FocusNode(debugLabel: 'footer-tag-remove'),
  );

  @override
  void dispose() {
    for (final node in _xFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Keeps keyboard focus when the focused × leaves the row: it moves to the
  /// next ×, else the previous one, else the editor, instead of falling to the
  /// enclosing scope. Rows decide, so this holds however the tag left. A mouse
  /// click doesn't focus a ×, so it moves nothing.
  void _keepFocusOnRow(List<String> tags) {
    final was = _shownTags;
    _shownTags = tags;
    final at = was.indexWhere((tag) => _xFocusOf(tag).hasFocus);
    if (at < 0 || tags.contains(was[at])) return;
    final target =
        was.skip(at + 1).where(tags.contains).firstOrNull ??
        was.take(at).where(tags.contains).lastOrNull;
    // After this frame: the editor's fallback changes a text selection, which
    // can't happen during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (target != null) {
        _xFocusOf(target).requestFocus();
      } else {
        widget.onFocusEditor();
      }
    });
  }

  /// The tag leaves the row only after the write returned. A failure keeps it
  /// and shows the inline error; an unreachable server does too, so this
  /// doesn't go through `guardVaultWrite` and its snackbar. A vault with no CLI
  /// (`canWrite` false) never tries the write and says so in the app's own
  /// copy. Any other failure that isn't a [MemexException] says the vault
  /// server didn't answer, so its original error goes to the log.
  Future<void> _remove(Note note, String tag) async {
    if (_removing.contains(tag)) return;
    if (ref.read(vaultAccessProvider)?.canWrite == false) {
      setState(() => _error = 'The memex CLI is not available.');
      return;
    }
    setState(() {
      _removing.add(tag);
      _error = null;
    });
    try {
      await removeTagFromNote(ref, note: note, tag: tag);
    } catch (e, stack) {
      if (e is! MemexException) debugPrint('Removing #$tag failed: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _removing.remove(tag);
        _error = _failureMessage(tag, e);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _removing.remove(tag);
      _removed.add(tag);
    });
  }

  static String _failureMessage(String tag, Object error) => switch (error) {
    MemexException(:final message) => message,
    _ => "Couldn't remove #$tag. The vault server didn't answer.",
  };

  @override
  Widget build(BuildContext context) {
    final id = widget.note.id;
    ref.listen<AsyncValue<VaultScoped<Note?>>>(editorNoteAsyncProvider, (
      _,
      next,
    ) {
      // No setState: this bar watches the same provider, and this can run
      // during another widget's build.
      if (next is AsyncData<VaultScoped<Note?>> && next.value.value?.id == id) {
        _removed.clear();
      }
    });
    final loaded = watchVaultValue<Note?>(ref, editorNoteAsyncProvider, null);
    final note = loaded != null && loaded.id == id ? loaded : widget.note;
    final chips = watchVaultValue(
      ref,
      footerChipsAsyncProvider(id),
      const <FooterChipRow>[],
    );
    final tags = [
      for (final tag in note.footerTags)
        if (!_removed.contains(tag)) tag,
    ];
    _keepFocusOnRow(tags);
    if (chips.isEmpty && tags.isEmpty) return const SizedBox.shrink();
    final error = _error;
    return Container(
      key: const Key('footer-chip-row'),
      margin: const EdgeInsets.only(top: 22),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null)
            InlineError(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          if (chips.isNotEmpty)
            _FooterRow(
              label: 'TOPICS',
              items: [
                for (final chip in chips)
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      key: Key('footer-chip-${chip.topicNoteId}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => ref
                          .read(tabsProvider.notifier)
                          .follow(NoteTab(chip.topicNoteId)),
                      child: Text(
                        chip.topicTitle,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: OmType.mono(size: 12, color: OmColors.fg1),
                      ),
                    ),
                  ),
              ],
            ),
          if (chips.isNotEmpty && tags.isNotEmpty) const SizedBox(height: 6),
          if (tags.isNotEmpty)
            _FooterRow(
              label: 'TAGS',
              items: [
                for (final tag in tags)
                  _FooterTagItem(
                    key: Key('footer-tag-$tag'),
                    tag: tag,
                    removing: _removing.contains(tag),
                    focusNode: _xFocusOf(tag),
                    onReveal: () => revealTag(ref, tag),
                    onRemove: () => _remove(note, tag),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// One footer row: its eyebrow in the 64 px label column, its [items] wrapping
/// in the column to the right.
class _FooterRow extends StatelessWidget {
  const _FooterRow({required this.label, required this.items});

  final String label;
  final List<Widget> items;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 64,
        child: Padding(
          padding: const EdgeInsets.only(top: 1),
          // Not `Eyebrow`: its Row overflows this column at a large text scale.
          child: Text(
            label,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: OmType.eyebrow(color: OmColors.fg2),
          ),
        ),
      ),
      Expanded(child: Wrap(spacing: 14, runSpacing: 6, children: items)),
    ],
  );
}

/// One tag on the Tags row: its name, clickable, and the permanently reserved
/// slot (Key `footer-tag-remove-<tag>`, 16 x 18) of its ×, so showing the ×
/// shifts nothing. The × shows while the item is hovered or the slot has
/// keyboard focus. While [removing], the slot holds a spinner instead.
class _FooterTagItem extends StatefulWidget {
  const _FooterTagItem({
    super.key,
    required this.tag,
    required this.removing,
    required this.focusNode,
    required this.onReveal,
    required this.onRemove,
  });

  final String tag;
  final bool removing;

  /// The ×'s focus node, owned by the bar.
  final FocusNode focusNode;
  final VoidCallback onReveal;
  final VoidCallback onRemove;

  @override
  State<_FooterTagItem> createState() => _FooterTagItemState();
}

class _FooterTagItemState extends State<_FooterTagItem> {
  bool _hovered = false;
  bool _focused = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) widget.onRemove();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final active = !widget.removing && (_hovered || _focused);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onReveal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '#${widget.tag}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style:
                    OmType.mono(
                      size: 12,
                      color: active ? OmColors.accentSoft : OmColors.fg2,
                    ).copyWith(
                      decoration: active ? TextDecoration.underline : null,
                    ),
              ),
            ),
            SizedBox(
              key: Key('footer-tag-remove-${widget.tag}'),
              width: 16,
              height: 18,
              child: Semantics(
                container: true,
                button: true,
                label: 'Remove tag ${widget.tag}',
                onTap: widget.onRemove,
                child: Focus(
                  focusNode: widget.focusNode,
                  onKeyEvent: _onKey,
                  onFocusChange: (focused) =>
                      setState(() => _focused = focused),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    onTap: widget.onRemove,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: widget.removing
                          ? const _RemoveSpinner()
                          : active
                          ? const Icon(
                              LucideIcons.x,
                              size: 12,
                              color: OmColors.fg2,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The spinner of a remove in progress: Lucide `loader2`, 12 px, fg2.
class _RemoveSpinner extends StatefulWidget {
  const _RemoveSpinner();

  @override
  State<_RemoveSpinner> createState() => _RemoveSpinnerState();
}

class _RemoveSpinnerState extends State<_RemoveSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: RotationTransition(
      turns: _spin,
      child: const Icon(LucideIcons.loader2, size: 12, color: OmColors.fg2),
    ),
  );
}
