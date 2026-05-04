import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db.dart';
import '../memex_cli.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Caret-anchored popover triggered by typing `[[` in a markdown editor.
/// Lists fuzzy-matched note titles plus a "+ Create" tail item; on accept,
/// rewrites the body so the wikilink ends with `]]` and the caret lands
/// just after.
///
/// Usage: pump a [WikilinkAutocomplete] inside a `Stack` over the body
/// `TextField`. The widget owns the keystroke listener, the popover
/// `OverlayEntry`, and the create-on-the-fly call to `MemexCli`.
class WikilinkAutocomplete extends ConsumerStatefulWidget {
  const WikilinkAutocomplete({
    super.key,
    required this.controller,
    required this.editorKey,
    required this.onNoteCreatedSelect,
    this.onInserted,
  });

  /// The body field's text controller. The autocomplete watches its `text`
  /// and `selection` to decide when to open and what to show.
  final TextEditingController controller;

  /// `GlobalKey` on the body `TextField` so we can read its render box and
  /// place the popover at the caret.
  final GlobalKey editorKey;

  /// Called when the user picks the "+ Create new note titled X" item or
  /// selects an existing note. The host can use this to optionally
  /// navigate (we don't navigate by default — keystroke focus stays in
  /// the editor so typing continues smoothly).
  final void Function(String noteId) onNoteCreatedSelect;

  /// Called after a wikilink is spliced into the editor's text. `start..end`
  /// is the byte range of the just-inserted `[[Title]]` token. Used by the
  /// kind chip to anchor itself.
  final void Function(int start, int end)? onInserted;

  @override
  ConsumerState<WikilinkAutocomplete> createState() =>
      _WikilinkAutocompleteState();
}

class _WikilinkAutocompleteState extends ConsumerState<WikilinkAutocomplete> {
  OverlayEntry? _entry;
  final _focusNode = FocusNode(skipTraversal: true);
  String _query = '';
  int _triggerOffset = -1; // byte offset of the `[[` that triggered.
  int _selectedIndex = 0;
  List<NoteTitle> _matches = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _entry?.remove();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChange() {
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset;
    if (caret < 0) return;
    // Look for the last unclosed `[[` before the caret.
    final newTrigger = _findUnclosedTrigger(text, caret);
    if (newTrigger == null) {
      _close();
      return;
    }
    _triggerOffset = newTrigger;
    final newQuery = text.substring(newTrigger + 2, caret);
    if (newQuery.contains('\n') ||
        newQuery.contains(']') ||
        newQuery.contains('[')) {
      _close();
      return;
    }
    _query = newQuery;
    _refreshMatches();
    if (_entry == null) {
      _open();
    } else {
      _entry!.markNeedsBuild();
    }
  }

  static int? _findUnclosedTrigger(String text, int caret) {
    // Search backwards from caret for `[[` with no `]]` between it and caret.
    final scanFrom = (caret - 64).clamp(0, text.length);
    final window = text.substring(scanFrom, caret);
    final lastOpen = window.lastIndexOf('[[');
    if (lastOpen < 0) return null;
    final between = window.substring(lastOpen + 2);
    if (between.contains(']]') || between.contains('\n')) return null;
    return scanFrom + lastOpen;
  }

  void _refreshMatches() {
    final all = ref.read(noteTitlesProvider);
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      _matches = all.take(8).toList();
    } else {
      final scored = <_Scored>[];
      for (final n in all) {
        final score = _fuzzyScore(n.title.toLowerCase(), q);
        if (score > 0) scored.add(_Scored(n, score));
      }
      scored.sort((a, b) => b.score.compareTo(a.score));
      _matches = scored.take(8).map((s) => s.note).toList();
    }
    _selectedIndex = 0;
  }

  static int _fuzzyScore(String hay, String needle) {
    if (needle.isEmpty) return 1;
    if (hay.startsWith(needle)) return 1000 - hay.length;
    if (hay.contains(needle)) return 500 - hay.length;
    // Subsequence match.
    var i = 0;
    var consecutive = 0;
    var bonus = 0;
    for (final c in hay.split('')) {
      if (i < needle.length && c == needle[i]) {
        i++;
        consecutive++;
        bonus += consecutive * 2;
      } else {
        consecutive = 0;
      }
    }
    if (i < needle.length) return 0;
    return 100 + bonus - hay.length;
  }

  void _open() {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: _buildPopover);
    overlay.insert(_entry!);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    _query = '';
    _triggerOffset = -1;
    _matches = const [];
  }

  Offset _caretGlobalOffset() {
    final ctx = widget.editorKey.currentContext;
    if (ctx == null) return Offset.zero;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    // Approximate placement: bottom-left of the editor field, then nudge.
    // The full RenderEditable.getLocalRectForCaret path is fiddlier; for a
    // useful-enough v1 we anchor at the editor's top-left and let the user
    // see the popover always in the same spot.
    final origin = box.localToGlobal(Offset.zero);
    return Offset(origin.dx, origin.dy + 22);
  }

  Widget _buildPopover(BuildContext context) {
    final caret = _caretGlobalOffset();
    final showCreate =
        _query.trim().isNotEmpty &&
        !_matches.any((m) => m.title == _query.trim());
    final itemCount = _matches.length + (showCreate ? 1 : 0);
    return Stack(
      children: [
        // Tap-outside dismiss layer. Keep it click-through for keys.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: caret.dx,
          top: caret.dy,
          child: KeyboardListener(
            focusNode: _focusNode..requestFocus(),
            onKeyEvent: _onKeyEvent,
            child: Material(
              elevation: 12,
              color: OmColors.surface3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: OmColors.line3),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 280,
                  maxWidth: 360,
                  maxHeight: 320,
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
                              label:
                                  'Create new note titled "${_query.trim()}"',
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
        ),
      ],
    );
  }

  void _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    final showCreate =
        _query.trim().isNotEmpty &&
        !_matches.any((m) => m.title == _query.trim());
    final itemCount = _matches.length + (showCreate ? 1 : 0);
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (itemCount == 0) return;
      _selectedIndex = (_selectedIndex + 1) % itemCount;
      _entry?.markNeedsBuild();
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (itemCount == 0) return;
      _selectedIndex = (_selectedIndex - 1 + itemCount) % itemCount;
      _entry?.markNeedsBuild();
      return;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      if (itemCount == 0) return;
      if (_selectedIndex < _matches.length) {
        _acceptExisting(_matches[_selectedIndex]);
      } else if (showCreate) {
        _acceptCreate();
      }
      return;
    }
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
    final cli = ref.read(memexCliProvider);
    final vaultPath = ref.read(currentVaultProvider);
    if (cli == null || vaultPath == null) return;
    setState(() => _busy = true);
    try {
      final id = await cli.addNote(
        vaultPath: vaultPath,
        title: title,
        contentMd: '# $title\n\n',
      );
      ref.read(vaultRevisionProvider.notifier).state++;
      _acceptExisting(NoteTitle(id: id, title: title, updatedAt: 0));
    } on MemexException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create note: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
