// WI #438 (Spec #392 req 10, 11, 12, 21): the spelling menu a right click
// on a flagged range opens (and Check Document Now, E6 #439), and what its
// items do.
//
// Frozen for E6 (#439): [showSpellingMenu].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/editor_rows.dart' show SegmentEdit, SegmentSelection;
import '../../editor/spell_issues.dart';
import '../../state/learned_words_seam.dart';
import '../../state/spell_check_controller.dart';
import '../../state/spell_session_state.dart';
import '../../state/spelling_service.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'segment_view.dart';
import 'spell_check_host.dart';
import 'spell_issue_scope.dart';
import 'spelling_learn_error.dart';

/// The most checker guesses a spelling issue's menu lists.
const spellingMenuMaxGuesses = 5;

/// The most corrections a grammar issue's menu lists.
const spellingMenuMaxCorrections = 3;

/// One SpellingMenu item: [label], run by [onSelected]. With no
/// [onSelected] the item is disabled.
class SpellingMenuEntry {
  const SpellingMenuEntry(this.label, [this.onSelected]);

  final String label;
  final VoidCallback? onSelected;

  bool get enabled => onSelected != null;
}

/// The keyboard-navigable spelling menu of one flagged range, at [anchor]
/// (global): [issueEntries], a divider, then [clipboardEntries].
///
/// It takes the focus once it is built. Up and Down move the highlight
/// between enabled items, skipping disabled ones and wrapping at the ends;
/// with nothing highlighted, Down reaches the first enabled item and Up the
/// last. Enter (a key down; a key repeat never) activates the highlighted
/// item, and with nothing highlighted closes the menu as Esc does. The mouse
/// highlights an enabled item while it is over it; a disabled item
/// (`OmColors.fg3`) never highlights.
///
/// [onClose] is called once: with the activated item, or with null when the
/// menu is dismissed (Esc, Enter over nothing: `restoreFocus` true; a click
/// outside it or focus moving elsewhere: false). Two activations in the same
/// frame call it once.
class SpellingMenu extends StatefulWidget {
  const SpellingMenu({
    super.key,
    required this.anchor,
    required this.issueEntries,
    required this.clipboardEntries,
    required this.onClose,
  });

  final Offset anchor;
  final List<SpellingMenuEntry> issueEntries;
  final List<SpellingMenuEntry> clipboardEntries;
  final void Function(SpellingMenuEntry? chosen, {required bool restoreFocus})
  onClose;

  @override
  State<SpellingMenu> createState() => _SpellingMenuState();
}

class _SpellingMenuState extends State<SpellingMenu> {
  final _focus = FocusNode(debugLabel: 'spelling-menu');

  /// The highlighted item (an index into [_entries]), or null.
  int? _highlight;

  /// Set by the first activation or dismissal: nothing runs after it.
  bool _closed = false;

  List<SpellingMenuEntry> get _entries => [
    ...widget.issueEntries,
    ...widget.clipboardEntries,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _close(SpellingMenuEntry? chosen, {required bool restoreFocus}) {
    if (_closed) return;
    _closed = true;
    widget.onClose(chosen, restoreFocus: restoreFocus);
  }

  void _activate(int index) {
    final entry = _entries[index];
    if (entry.enabled) _close(entry, restoreFocus: true);
  }

  /// The next enabled item from [_highlight] in direction [step] (1 or -1),
  /// wrapping; null when no item is enabled.
  int? _next(int step) {
    final entries = _entries;
    final n = entries.length;
    var i = _highlight ?? (step > 0 ? -1 : n);
    for (var tried = 0; tried < n; tried++) {
      i = (i + step) % n;
      if (i < 0) i += n;
      if (entries[i].enabled) return i;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final isEnter =
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    final ours =
        isEnter ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.escape;
    if (!ours) return KeyEventResult.ignored;
    if (event is KeyUpEvent || _closed) return KeyEventResult.handled;
    if (isEnter) {
      // A held Enter (from before the menu opened, or after an activation)
      // never activates.
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      final highlight = _highlight;
      if (highlight == null) {
        _close(null, restoreFocus: true);
      } else {
        _activate(highlight);
      }
    } else if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _close(null, restoreFocus: true);
    } else {
      final next = _next(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
      if (next != null) setState(() => _highlight = next);
    }
    return KeyEventResult.handled;
  }

  void _hover(int index, {required bool inside}) {
    if (_closed) return;
    if (inside) {
      final next = _entries[index].enabled ? index : null;
      if (next != _highlight) setState(() => _highlight = next);
    } else if (_highlight == index) {
      setState(() => _highlight = null);
    }
  }

  Widget _item(int index, SpellingMenuEntry entry) {
    final enabled = entry.enabled;
    final highlighted = enabled && _highlight == index;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: entry.label,
      onTap: enabled ? () => _activate(index) : null,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => _hover(index, inside: true),
        onExit: (_) => _hover(index, inside: false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => _activate(index) : null,
          // At least 24px tall, growing with the text scale.
          child: Container(
            constraints: const BoxConstraints(minHeight: 24),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            alignment: Alignment.centerLeft,
            decoration: highlighted
                ? BoxDecoration(
                    color: OmColors.surface5,
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            child: Text(
              entry.label,
              // A disabled item (a grammar description) wraps to three
              // lines; an enabled one stays on one.
              maxLines: enabled ? 1 : 3,
              overflow: TextOverflow.ellipsis,
              style: OmType.sans(
                size: 13,
                color: enabled ? OmColors.fg0 : OmColors.fg3,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final issues = widget.issueEntries;
    final clipboard = widget.clipboardEntries;
    final menu = Material(
      color: OmColors.surface3,
      elevation: 12,
      shadowColor: OmColors.menuShadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: OmColors.line3),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
        child: IntrinsicWidth(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, e) in issues.indexed) _item(i, e),
                if (issues.isNotEmpty && clipboard.isNotEmpty)
                  Divider(
                    key: const Key('spelling-menu-divider'),
                    height: 9,
                    thickness: 1,
                    color: OmColors.line2,
                  ),
                for (final (i, e) in clipboard.indexed)
                  _item(issues.length + i, e),
              ],
            ),
          ),
        ),
      ),
    );
    return TapRegion(
      onTapOutside: (_) => _close(null, restoreFocus: false),
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (focused) {
          if (!focused) _close(null, restoreFocus: false);
        },
        child: CustomSingleChildLayout(
          delegate: DesktopTextSelectionToolbarLayoutDelegate(
            anchor: widget.anchor + const Offset(1, 1),
          ),
          child: menu,
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- opening

/// The issue a context menu over [field]'s selection opens SpellingMenu
/// for (Spec #392 req 10), or null for the field's default menu.
///
/// An issue of the field (`SpellIssueRegistry.issuesFor`) qualifies when
/// the selection is a caret in it (its ends included) or equals its range;
/// a grammar issue also when the selection lies wholly inside its range
/// (ruling D55: its actions still act on the whole range). A spelling issue
/// wins over a grammar issue. Inside a live preview row, none does while
/// the segment selection spans past the row.
SpellIssue? spellingIssueAtSelection(EditableTextState field) {
  if (!field.mounted) return null;
  final context = field.context;
  final registry = context
      .getInheritedWidgetOfExactType<SpellIssueScope>()
      ?.registry;
  if (registry == null) return null;
  final ctrl = field.widget.controller;
  final selection = ctrl.selection;
  if (!selection.isValid) return null;
  final view = context.findAncestorStateOfType<SegmentViewState>();
  if (view != null) {
    final base = view.rowTextStartOf(ctrl);
    if (base == null) return null;
    final segment = view.selection;
    if (segment.isValid &&
        !segment.isCollapsed &&
        (segment.start < base || segment.end > base + ctrl.text.length)) {
      return null;
    }
  }
  SpellIssue? found;
  for (final issue in registry.issuesFor(ctrl).value) {
    final end = issue.start + issue.length;
    final hit = selection.isCollapsed
        ? issue.start <= selection.baseOffset && selection.baseOffset <= end
        : (selection.start == issue.start && selection.end == end) ||
              (issue.kind == SpellIssueKind.grammar &&
                  issue.start <= selection.start &&
                  selection.end <= end);
    if (!hit) continue;
    if (issue.kind == SpellIssueKind.spelling) return issue;
    found ??= issue;
  }
  return found;
}

/// [TextSegmentField]'s context menu: SpellingMenu (opened just after this
/// frame, the field's own menu left empty) when [spellingIssueAtSelection]
/// finds an issue, else the field's default menu.
Widget spellingAwareContextMenu(
  BuildContext context,
  EditableTextState editable,
) {
  final issue = spellingIssueAtSelection(editable);
  if (issue == null) {
    if (SystemContextMenu.isSupportedByField(editable)) {
      return SystemContextMenu.editableText(editableTextState: editable);
    }
    return AdaptiveTextSelectionToolbar.editableText(
      editableTextState: editable,
    );
  }
  final anchor = editable.contextMenuAnchors.primaryAnchor;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (editable.mounted) {
      unawaited(showSpellingMenu(editable, issue: issue, anchor: anchor));
    }
  });
  return const SizedBox.shrink();
}

/// Bumped by every [showSpellingMenu]: an older call still waiting for its
/// guesses then shows nothing.
int _opens = 0;

/// The menu shown, or null.
_MenuSession? _shown;

final _menus = ContextMenuController(onRemove: () => _shown?.removed());

/// Opens SpellingMenu for [issue], an issue the editor published for
/// [field] (field-local offsets), at global [anchor], in place of any other
/// context menu. A spelling issue lists the checker's guesses
/// (`SpellingService.guesses` on the field's text and the note's document
/// tag); a grammar issue its description and corrections. Copy and Cut are
/// offered while the field's selection is non-collapsed.
///
/// Completes with true once the menu shows; false when it doesn't: [field]
/// has no SpellCheckScope, [issue] is out of its text, or the field was
/// disposed, its text changed or another call started while the guesses
/// were asked for.
///
/// Closing it returns the focus to [field] (Esc, or an item's action)
/// with its selection as it was.
Future<bool> showSpellingMenu(
  EditableTextState field, {
  required SpellIssue issue,
  required Offset anchor,
}) async {
  final open = ++_opens;
  if (!field.mounted) return false;
  final context = field.context;
  final checker = context
      .getInheritedWidgetOfExactType<SpellCheckScope>()
      ?.controller;
  final ctrl = field.widget.controller;
  final text = ctrl.text;
  final end = issue.start + issue.length;
  if (checker == null ||
      issue.start < 0 ||
      issue.length <= 0 ||
      end > text.length) {
    return false;
  }
  final container = ProviderScope.containerOf(context, listen: false);
  final noteId = checker.noteId;
  var guesses = const <String>[];
  if (issue.kind == SpellIssueKind.spelling) {
    final tag = await container.read(spellSessionProvider).documentTag(noteId);
    if (tag != null) {
      guesses = await container
          .read(spellingServiceProvider)
          .guesses(
            text: text,
            start: issue.start,
            length: issue.length,
            documentTag: tag,
          );
    }
  }
  if (open != _opens || !field.mounted || ctrl.text != text) return false;
  final session = _MenuSession(
    checker: checker,
    container: container,
    field: field,
    ctrl: ctrl,
    focusNode: field.widget.focusNode,
    view: field.context.findAncestorStateOfType<SegmentViewState>(),
    issue: issue,
    flagged: text.substring(issue.start, end),
    noteId: noteId,
  );
  final entries = session.issueEntries(guesses);
  final clipboard = session.clipboardEntries(
    collapsed: !ctrl.selection.isValid || ctrl.selection.isCollapsed,
  );
  _shown?.removed();
  _menus.show(
    context: field.context,
    contextMenuBuilder: (_) => SpellingMenu(
      // A fresh state (highlight, focus) for every menu, also when it
      // replaces one still shown.
      key: ObjectKey(session),
      anchor: anchor,
      issueEntries: entries,
      clipboardEntries: clipboard,
      onClose: session.close,
    ),
  );
  _shown = session;
  return true;
}

/// What one shown SpellingMenu acts on.
class _MenuSession {
  _MenuSession({
    required this.checker,
    required this.container,
    required this.field,
    required this.ctrl,
    required this.focusNode,
    required this.view,
    required this.issue,
    required this.flagged,
    required this.noteId,
  });

  final SpellCheckController checker;
  final ProviderContainer container;
  final EditableTextState field;
  final TextEditingController ctrl;
  final FocusNode focusNode;

  /// The live preview segment holding the field, or null (Source mode).
  final SegmentViewState? view;
  final SpellIssue issue;

  /// The flagged text when the menu opened.
  final String flagged;
  final String noteId;

  bool _closed = false;

  /// Another context menu replaced this one.
  void removed() {
    _closed = true;
    if (identical(_shown, this)) _shown = null;
  }

  void close(SpellingMenuEntry? chosen, {required bool restoreFocus}) {
    if (_closed) return;
    if (restoreFocus) _restoreFocus();
    _menus.remove();
    removed();
    chosen?.onSelected?.call();
  }

  /// Gives the focus back to [field] with its selection as it was, and
  /// with the selection overlay its next context menu needs: the field
  /// dropped that overlay when the menu took the focus, and a right click
  /// on the unchanged selection would not rebuild it. Done as Flutter does
  /// for a right click on an unfocused field whose selection is already
  /// there (`userUpdateTextEditingValue` with the unchanged value).
  void _restoreFocus() {
    final field = this.field;
    if (field.mounted && !field.widget.focusNode.hasFocus) {
      field.userUpdateTextEditingValue(
        field.textEditingValue,
        SelectionChangedCause.toolbar,
      );
    } else {
      focusNode.requestFocus();
    }
  }

  List<SpellingMenuEntry> issueEntries(List<String> guesses) =>
      switch (issue.kind) {
        SpellIssueKind.spelling => [
          if (guesses.isEmpty) const SpellingMenuEntry('No Guesses Found'),
          for (final g in guesses.take(spellingMenuMaxGuesses))
            SpellingMenuEntry(g, () => _replace(g)),
          SpellingMenuEntry('Learn Spelling', _learn),
          SpellingMenuEntry('Ignore Spelling', () {
            if (_stillFlagged) unawaited(checker.ignoreSpelling(issue, ctrl));
          }),
        ],
        SpellIssueKind.grammar => [
          if (issue.description case final description?)
            SpellingMenuEntry(description),
          for (final c in issue.corrections.take(spellingMenuMaxCorrections))
            SpellingMenuEntry(c, () => _replace(c)),
          SpellingMenuEntry('Ignore Grammar', () {
            if (_stillFlagged) checker.ignoreGrammar(issue, ctrl);
          }),
        ],
      };

  /// The field's text at the issue range is still [flagged]: Ignore and a
  /// replacement act on nothing once the text under the menu has changed.
  bool get _stillFlagged {
    final end = issue.start + issue.length;
    final text = ctrl.text;
    return end <= text.length && text.substring(issue.start, end) == flagged;
  }

  List<SpellingMenuEntry> clipboardEntries({required bool collapsed}) => [
    if (!collapsed) ...[
      SpellingMenuEntry('Copy', () => _invoke(CopySelectionTextIntent.copy)),
      SpellingMenuEntry(
        'Cut',
        () => _invoke(
          const CopySelectionTextIntent.cut(SelectionChangedCause.toolbar),
        ),
      ),
    ],
    SpellingMenuEntry(
      'Paste',
      () => _invoke(const PasteTextIntent(SelectionChangedCause.toolbar)),
    ),
    SpellingMenuEntry(
      'Select All',
      () => _invoke(const SelectAllTextIntent(SelectionChangedCause.toolbar)),
    ),
  ];

  /// Runs [intent] as the field's own context menu item does.
  void _invoke(Intent intent) {
    final context = focusNode.context;
    if (context != null && context.mounted) {
      Actions.maybeInvoke(context, intent);
    }
  }

  /// Replaces the flagged range with [replacement] as one undoable edit
  /// through the editor's edit path (req 11): the segment's
  /// `SegmentViewState.applyEdit` in a live preview row, else the field's
  /// value (one step of its undo history). The caret goes after it. Nothing
  /// happens once the flagged text has changed.
  void _replace(String replacement) {
    final start = issue.start;
    final end = start + issue.length;
    final text = ctrl.text;
    if (!_stillFlagged) return;
    final view = this.view;
    if (view != null) {
      if (!view.mounted) return;
      final base = view.rowTextStartOf(ctrl);
      if (base == null) return;
      final at = base + start;
      final segment = view.text;
      if (at + issue.length > segment.length ||
          segment.substring(at, at + issue.length) != flagged) {
        return;
      }
      view.applyEdit(
        SegmentEdit(
          start: at,
          end: at + issue.length,
          replacement: replacement,
          selection: SegmentSelection.collapsed(at + replacement.length),
        ),
      );
      return;
    }
    ctrl.value = TextEditingValue(
      text: text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  /// Learn Spelling (req 12): `learnedWordsActionsProvider.learn`. A false
  /// answer shows `Could not learn "<word>".` above the editor body; a true
  /// one clears that error for the note.
  Future<void> _learn() async {
    final word = flagged;
    final learned = await container
        .read(learnedWordsActionsProvider)
        .learn(word);
    final error = container.read(spellingLearnErrorProvider.notifier);
    if (!learned) {
      error.state = (noteId: noteId, word: word);
    } else if (error.state?.noteId == noteId) {
      error.state = null;
    }
  }
}
