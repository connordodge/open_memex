import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db.dart';
import '../editor/fuzzy_score.dart';
import '../memex_cli.dart';
import '../state/topic_actions.dart';
import '../state/vault_access_state.dart';
import '../state/vault_state.dart';
import '../vault_access/errors.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Caret-anchored popover triggered by typing `[[` in a markdown editor.
/// Lists fuzzy-matched note titles plus a "+ Create" tail item; on accept,
/// rewrites the body so the wikilink ends with `]]` and the caret lands
/// just after.
///
/// Usage:
///   1. Mount as a sibling of the body `TextField`.
///   2. Pass `caretLocator` — a function that returns the **global** offset
///      where the bottom-left of the caret currently sits.
///   3. Wire the body field's `FocusNode.onKeyEvent` to call
///      [handleKeyEvent] BEFORE the field gets the key. While the popover
///      is open, that intercepts ↑/↓/Enter/Tab/Esc.
///
/// The widget never requests focus — the body `TextField` keeps focus the
/// whole time so the user can keep typing to narrow the query.
class WikilinkAutocomplete extends ConsumerStatefulWidget {
  const WikilinkAutocomplete({
    super.key,
    required this.controller,
    required this.caretLocator,
    required this.onNoteCreatedSelect,
    this.onInserted,
    this.dailyNoteId,
    this.onTopicLinked,
    this.onCreateError,
  });

  final TextEditingController controller;

  /// Returns the **global** screen offset where the popover should anchor
  /// its top-left. The editor computes this from the field's `RenderBox`
  /// + a `TextPainter` over `controller.text[0..caret]`.
  final Offset Function() caretLocator;

  final void Function(String noteId) onNoteCreatedSelect;

  /// Called after a wikilink is spliced into the editor's text. `start..end`
  /// is the byte range of the just-inserted `[[Title]]` token. Used by the
  /// kind chip to anchor itself.
  final void Function(int start, int end)? onInserted;

  /// The id of the open note when it is a saved daily note, else null. In a
  /// daily note, creating a note makes a `role: topic` note and adds it as a
  /// `person` chip to this note's Topics footer (Req 17); elsewhere the
  /// created note has no role and no chip.
  final String? dailyNoteId;

  /// Called, after the wikilink was inserted, with the daily note's new
  /// version once its footer chip was added: the host makes that version the
  /// editor's base. Only for [dailyNoteId] creates.
  final void Function(int version)? onTopicLinked;

  /// Called with the CLI message when creating the note or its footer chip
  /// failed (the body is left as it was). Only for [dailyNoteId] creates;
  /// the host shows it inline (Req 54).
  final ValueChanged<String>? onCreateError;

  @override
  ConsumerState<WikilinkAutocomplete> createState() =>
      WikilinkAutocompleteState();
}

class WikilinkAutocompleteState extends ConsumerState<WikilinkAutocomplete> {
  OverlayEntry? _entry;
  String _query = '';
  int _triggerOffset = -1; // byte offset of the `[[` that triggered.
  int _selectedIndex = 0;
  List<NoteTitle> _matches = const [];
  bool _busy = false;

  bool get isOpen => _entry != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _entry?.remove();
    super.dispose();
  }

  void _onChange() {
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset;
    if (caret < 0) {
      _close();
      return;
    }
    final newTrigger = _findUnclosedTrigger(text, caret);
    if (newTrigger == null) {
      _close();
      return;
    }
    final newQuery = text.substring(newTrigger + 2, caret);
    if (newQuery.contains('\n') ||
        newQuery.contains(']') ||
        newQuery.contains('[')) {
      _close();
      return;
    }
    _triggerOffset = newTrigger;
    _query = newQuery;
    _refreshMatches();
    if (_entry == null) {
      _open();
    } else {
      _entry!.markNeedsBuild();
    }
  }

  static int? _findUnclosedTrigger(String text, int caret) {
    final scanFrom = (caret - 64).clamp(0, text.length);
    final window = text.substring(scanFrom, caret);
    final lastOpen = window.lastIndexOf('[[');
    if (lastOpen < 0) return null;
    final between = window.substring(lastOpen + 2);
    if (between.contains(']]') || between.contains('\n')) return null;
    return scanFrom + lastOpen;
  }

  void _refreshMatches() {
    final all = readVaultValue(
      ref,
      noteTitlesAsyncProvider,
      const <NoteTitle>[],
    );
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      _matches = all.take(8).toList();
    } else {
      final scored = <_Scored>[];
      for (final n in all) {
        final score = fuzzyScore(n.title.toLowerCase(), q);
        if (score > 0) scored.add(_Scored(n, score));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      _matches = scored.take(8).map((s) => s.note).toList();
    }
    _selectedIndex = 0;
  }

  void _open() {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: _buildPopover);
    overlay.insert(_entry!);
  }

  void _close() {
    if (_entry == null && _query.isEmpty && _triggerOffset == -1) return;
    _entry?.remove();
    _entry = null;
    _query = '';
    _triggerOffset = -1;
    _matches = const [];
  }

  /// Called by the host's `FocusNode.onKeyEvent`. While the popover is
  /// open, ↑/↓ move selection, Enter/Tab accept, Esc dismisses — and the
  /// host returns `KeyEventResult.handled` for those so the `TextField`
  /// doesn't process them.
  KeyEventResult handleKeyEvent(KeyEvent event) {
    if (!isOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      // Swallow the key-up paired with a handled key-down.
      return KeyEventResult.handled;
    }

    final showCreate =
        _query.trim().isNotEmpty &&
        !_matches.any((m) => m.title == _query.trim());
    final itemCount = _matches.length + (showCreate ? 1 : 0);

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (itemCount > 0) {
        _selectedIndex = (_selectedIndex + 1) % itemCount;
        _entry?.markNeedsBuild();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (itemCount > 0) {
        _selectedIndex = (_selectedIndex - 1 + itemCount) % itemCount;
        _entry?.markNeedsBuild();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      if (itemCount == 0) {
        // Nothing to accept. Treat Enter normally if there's no list at all.
        if (event.logicalKey == LogicalKeyboardKey.tab) {
          // Still consume Tab so the field doesn't insert one.
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (_selectedIndex < _matches.length) {
        _acceptExisting(_matches[_selectedIndex]);
      } else if (showCreate) {
        _acceptCreate();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildPopover(BuildContext context) {
    final caret = widget.caretLocator();
    final showCreate =
        _query.trim().isNotEmpty &&
        !_matches.any((m) => m.title == _query.trim());
    final itemCount = _matches.length + (showCreate ? 1 : 0);

    final mediaSize = MediaQuery.of(context).size;
    const popoverWidth = 320.0;
    const popoverMaxHeight = 280.0;
    // Place below the caret line by default. If the popover would clip the
    // bottom, flip above.
    var top = caret.dy + 6;
    if (top + popoverMaxHeight > mediaSize.height - 24) {
      top = caret.dy - popoverMaxHeight - 24;
      if (top < 8) top = 8;
    }
    var left = caret.dx;
    if (left + popoverWidth > mediaSize.width - 12) {
      left = mediaSize.width - popoverWidth - 12;
    }
    if (left < 8) left = 8;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            elevation: 12,
            color: OmColors.surface3,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: BorderSide(color: OmColors.line3),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: popoverWidth,
                maxWidth: popoverWidth,
                maxHeight: popoverMaxHeight,
              ),
              child: Column(
                key: const Key('wikilink-popover'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (itemCount == 0)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _query.isEmpty ? 'type to search…' : 'no matches',
                        style: OmType.mono(size: 11, color: OmColors.fg3),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        shrinkWrap: true,
                        itemCount: itemCount,
                        itemBuilder: (_, i) {
                          if (i < _matches.length) {
                            final n = _matches[i];
                            return _Item(
                              key: Key('wikilink-popover-item-${n.title}'),
                              icon: LucideIcons.fileText,
                              label: n.title,
                              selected: i == _selectedIndex,
                              onTap: () => _acceptExisting(n),
                            );
                          }
                          return _Item(
                            key: const Key('wikilink-popover-create'),
                            icon: LucideIcons.plus,
                            label: 'Create new note titled "${_query.trim()}"',
                            accent: true,
                            selected: i == _selectedIndex,
                            onTap: _busy ? null : _acceptCreate,
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Replace the unclosed `[[<query>` with `[[<title>]]` and place caret
  /// just after `]]`.
  void _acceptExisting(NoteTitle target) {
    if (_triggerOffset < 0) return;
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset;
    if (caret < 0) return;
    final start = _triggerOffset;
    final before = text.substring(0, start);
    final after = text.substring(caret);
    final inserted = '[[${target.title}]]';
    final newText = '$before$inserted$after';
    final end = start + inserted.length;
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: end),
    );
    _close();
    widget.onNoteCreatedSelect(target.id);
    widget.onInserted?.call(start, end);
  }

  Future<void> _acceptCreate() async {
    if (_busy) return;
    final title = _query.trim();
    if (title.isEmpty) return;
    final access = ref.read(vaultAccessProvider);
    final cli = ref.read(memexCliProvider);
    final vaultPath = ref.read(currentVaultProvider).localPath;
    if (access == null || !access.canWrite) return;
    final revision = ref.read(vaultRevisionProvider.notifier);
    final dailyId = widget.dailyNoteId;
    setState(() => _busy = true);
    try {
      if (dailyId == null) {
        // An unreachable vault server shows the guard's snackbar and changes
        // nothing (L17); other failures keep today's error snackbar.
        final id = await guardVaultWrite(
          context,
          () => access.notes.addNote(
            title: title,
            contentMd: topicNoteBody(title),
          ),
        );
        if (id == null) return;
        revision.state++;
        _acceptExisting(NoteTitle(id: id, title: title, updatedAt: 0));
      } else {
        if (cli == null || vaultPath == null) return;
        final created = await createLinkedTopic(
          ref.read(vaultAccessProvider)!,
          title: title,
          contentMd: topicNoteBody(title),
          dailyNoteId: dailyId,
          linkTarget: 'this daily note',
        );
        revision.state++;
        if (!mounted) return;
        _acceptExisting(
          NoteTitle(id: created.topicId, title: title, updatedAt: 0),
        );
        widget.onTopicLinked?.call(created.footer.version);
      }
    } on TopicNotLinkedException catch (e) {
      // The topic note exists: refresh the vault views. The body stays as it
      // was; the new topic is now an existing match for the person to pick.
      revision.state++;
      if (mounted) _reportError(e.message, daily: true);
    } on MemexException catch (e) {
      if (mounted) _reportError(e.message, daily: dailyId != null);
    } catch (e) {
      if (dailyId == null) rethrow;
      if (mounted) _reportError(e.toString(), daily: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reportError(String message, {required bool daily}) {
    final report = widget.onCreateError;
    if (daily && report != null) {
      // The popover's full-screen barrier would swallow the tap on the
      // error's dismiss button; the body stays as it was.
      _close();
      report(message);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Could not create note: $message')));
  }

  @override
  Widget build(BuildContext context) {
    // Loads the titles with the editor (D14a: async) and refreshes an open
    // popover's matches when a read lands.
    ref.listen(noteTitlesAsyncProvider, (_, _) {
      final entry = _entry;
      if (entry == null) return;
      _refreshMatches();
      entry.markNeedsBuild();
    });
    return const SizedBox.shrink();
  }
}

class _Scored {
  _Scored(this.note, this.score);
  final NoteTitle note;
  final int score;
}

class _Item extends StatelessWidget {
  const _Item({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent = false,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final bool accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          color: selected ? OmColors.surface4 : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(
                icon,
                size: 12,
                color: accent ? OmColors.accent : OmColors.fg2,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(
                    size: 13,
                    color: accent ? OmColors.accent : OmColors.fg0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
