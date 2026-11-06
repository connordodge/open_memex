import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db/tags_reads.dart';
import '../editor/fuzzy_score.dart';
import '../editor/tag_grammar.dart';
import '../state/note_state.dart';
import '../state/tags_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'editor/live_preview_controller.dart';
import 'wikilink_autocomplete.dart';

/// Caret-anchored popover triggered by typing `#` in a markdown editor
/// (WI #246). Lists the vault's non-system tags, most used first for a bare
/// `#` and fuzzy-matched for a query, plus a create row while a query names no
/// listed tag; on accept, replaces `#query` with `#name `.
///
/// Mounted like [WikilinkAutocomplete]: a sibling of the body `TextField`,
/// whose `FocusNode.onKeyEvent` calls [handleKeyEvent] first. The widget never
/// requests focus. A create row writes text only: the tag exists once saved.
class TagAutocomplete extends ConsumerStatefulWidget {
  const TagAutocomplete({
    super.key,
    required this.controller,
    required this.caretLocator,
  });

  final TextEditingController controller;

  /// Returns the **global** screen offset where the popover anchors.
  final Offset Function() caretLocator;

  @override
  ConsumerState<TagAutocomplete> createState() => TagAutocompleteState();
}

class TagAutocompleteState extends ConsumerState<TagAutocomplete> {
  static const int _maxRows = 8;

  OverlayEntry? _entry;
  TagQuery? _found;
  List<TagRow> _rows = const [];
  int _selectedIndex = 0;

  /// The controller's value at its last change: a live preview row also
  /// notifies for changes to its other props, which must neither reopen the
  /// popover nor reset its selection.
  late TextEditingValue _seen;

  /// Escape or a click outside closed the popover for the current value.
  bool _dismissed = false;

  bool get isOpen => _entry != null;

  String get _query => _found?.query ?? '';

  bool get _showCreate {
    final query = _query.toLowerCase();
    return query.isNotEmpty && !_rows.any((r) => r.tag == query);
  }

  int get _itemCount => _rows.length + (_showCreate ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _seen = widget.controller.value;
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _entry?.remove();
    super.dispose();
  }

  void _onChange() {
    final value = widget.controller.value;
    if (value == _seen) return;
    _seen = value;
    _dismissed = false;
    _selectedIndex = 0;
    _sync();
  }

  /// A tags read landed. A save bumps the vault revision and so re-reads the
  /// tags: the selected tag stays selected.
  void _onTagsChanged() {
    if (_dismissed) return;
    final index = _selectedIndex;
    final selected = index < _rows.length ? _rows[index].tag : null;
    _sync();
    _selectedIndex = max(0, _rows.indexWhere((r) => r.tag == selected));
  }

  void _sync() {
    final found = _findQuery();
    _found = found;
    _rows = found == null ? const [] : _matches(found.query);
    if (_itemCount == 0) {
      _close();
    } else if (_entry == null) {
      _open();
    } else {
      _entry!.markNeedsBuild();
    }
  }

  /// The `#query` the popover is for, or null when it stays closed: outside
  /// the grammar's rules, in an unclosed `[[` (that popover wins), or for a
  /// bare `#` at column 0, which may yet become a heading. An item row's
  /// column 0 is not a line start: its marker sits outside the field.
  TagQuery? _findQuery() {
    final controller = widget.controller;
    final selection = controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final text = controller.text;
    final found = tagQueryAt(text, selection.baseOffset);
    if (found == null) return null;
    if (_inUnclosedWikilink(text.substring(found.lineStart, found.start))) {
      return null;
    }
    final itemRow = controller is LivePreviewController && controller.itemText;
    final bareLineStart = found.query.isEmpty && found.start == found.lineStart;
    return bareLineStart && !itemRow ? null : found;
  }

  static bool _inUnclosedWikilink(String lineBeforeHash) {
    final open = lineBeforeHash.lastIndexOf('[[');
    return open >= 0 && !lineBeforeHash.contains(']]', open);
  }

  List<TagRow> _matches(String query) {
    final tags = readVaultValue(ref, tagsAsyncProvider, const <TagRow>[]);
    final visible = tags.where((t) => !isSystemTag(t.tag)).toList();
    if (query.isEmpty) {
      visible.sort((a, b) {
        final byCount = b.noteCount.compareTo(a.noteCount);
        return byCount != 0 ? byCount : a.tag.compareTo(b.tag);
      });
      return visible.take(_maxRows).toList();
    }
    final needle = query.toLowerCase();
    final scored = [
      for (final (i, tag) in visible.indexed)
        (tag: tag, index: i, score: fuzzyScore(tag.tag, needle)),
    ].where((s) => s.score > 0).toList();
    // `List.sort` isn't stable: equal scores keep the provider's order by hand.
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
    return scored.take(_maxRows).map((s) => s.tag).toList();
  }

  void _open() {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(builder: _buildPopover);
    overlay.insert(_entry!);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
  }

  void _dismiss() {
    _dismissed = true;
    _close();
  }

  /// Called by the host's `FocusNode.onKeyEvent`. While the popover is open,
  /// ↑/↓ move the selection, Enter/Tab accept and Esc dismisses; the host
  /// returns the result, so a handled key never reaches the `TextField`.
  KeyEventResult handleKeyEvent(KeyEvent event) {
    if (!isOpen) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      // Swallow the key-up paired with a handled key-down.
      return KeyEventResult.handled;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _dismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _select(_selectedIndex + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _select(_selectedIndex - 1 + _itemCount);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      if (_selectedIndex < _rows.length) {
        _accept(_rows[_selectedIndex].tag);
      } else {
        _accept(_found!.name);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(int index) {
    _selectedIndex = index % _itemCount;
    _entry!.markNeedsBuild();
  }

  /// Replaces `#query` with `#name ` and places the caret after the space. The
  /// new text closes the popover through [_onChange].
  void _accept(String name) {
    final controller = widget.controller;
    final text = controller.text;
    final inserted = '#$name ';
    final start = _found!.start;
    controller.value = TextEditingValue(
      text:
          '${text.substring(0, start)}$inserted'
          '${text.substring(controller.selection.baseOffset)}',
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
  }

  Widget _buildPopover(BuildContext context) {
    return AutocompletePopover(
      boxKey: const Key('tag-autocomplete'),
      caret: widget.caretLocator(),
      onDismiss: _dismiss,
      children: [
        Flexible(
          // On desktop a click outside the field's tap region unfocuses it;
          // clicking a row keeps the caret in the field, after the new tag.
          child: TextFieldTapRegion(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              shrinkWrap: true,
              itemCount: _itemCount,
              itemBuilder: (_, i) {
                if (i < _rows.length) {
                  final row = _rows[i];
                  return AutocompleteRow(
                    key: Key('tag-autocomplete-item-${row.tag}'),
                    icon: LucideIcons.hash,
                    label: row.tag,
                    labelHeight: 18 / 13,
                    selected: i == _selectedIndex,
                    onTap: () => _accept(row.tag),
                    trailing: Text(
                      '${row.noteCount}',
                      style: OmType.mono(
                        size: 11,
                        color: OmColors.fg2,
                        height: 18 / 11,
                      ),
                    ),
                  );
                }
                return AutocompleteRow(
                  key: const Key('tag-autocomplete-create'),
                  icon: LucideIcons.plus,
                  label: 'Create new tag #$_query',
                  labelHeight: 18 / 13,
                  accent: true,
                  selected: i == _selectedIndex,
                  onTap: () => _accept(_found!.name),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Loads the tags with the editor (D14a: async); a read that lands refreshes
    // an open popover and may open one a bare `#` had no rows for.
    ref.listen(tagsAsyncProvider, (_, _) => _onTagsChanged());
    return const SizedBox.shrink();
  }
}
