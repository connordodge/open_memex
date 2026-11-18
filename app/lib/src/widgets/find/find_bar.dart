// WI #82 (Spec #61 F2; Reqs 12-13, 19-20, 22, 29-34, 40-41; rulings D12,
// D13, D14): the Find bar, design B's floating box over the note body. F6
// mounts it in the note editor's `_bodyOverlays` slot.
//
// Sizes, colours and type come from the design pack
// design/55-find-in-note/packs/82.md (boards B1, B3, B4).
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../editor/find_in_note.dart';
import '../../state/find_in_note_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'find_keys.dart';

/// The box's inset from the body top (the toolbar hairline).
const double _top = 10;

/// The box's inset from the body's right edge.
const double _right = 12;

/// The box's height.
const double _height = 38;

/// The row's inset from the box's outer edge: the 1 px border plus 6 px.
const double _inset = 7;

/// The gap between the row's children.
const double _gap = 4;

/// The field's height.
const double _fieldHeight = 26;

/// The counter slot's margin on each side of its text.
const double _counterMargin = 4;

/// The counter text's minimum width in the full form (`3 of 12`).
const double _fullCounterMin = 64;

/// The counter text's minimum width in the short form (`3/12`).
const double _shortCounterMin = 34;

/// Below this box width the magnifier is dropped (B4.4).
const double _magnifierMinBox = 240;

/// The ghost buttons' side.
const double _buttonSize = 24;

/// The Find bar: a `Positioned` box 10 px below the body top and 12 px from
/// its right edge, `findBoxWidth(bodyWidth)` wide and 38 px tall, shown only
/// while `findInNoteProvider.open` is true. It must be a direct child of the
/// body's `Stack`.
///
/// Stepping (Enter, Shift+Enter, the up and down buttons) calls [onStep]
/// with the new current match; closing (Esc in the field, the close button)
/// calls [onClose] with the current match, or null when there is none. The
/// bar never touches the editor's caret or selection itself (Req 20).
class FindBarOverlay extends ConsumerStatefulWidget {
  const FindBarOverlay({
    super.key,
    required this.bodyWidth,
    required this.onStep,
    required this.onClose,
  });

  /// The note body's width; the box is `findBoxWidth(bodyWidth)` wide.
  final double bodyWidth;

  /// Called with the new current match after each step from the bar.
  final ValueChanged<FindMatch> onStep;

  /// Called with the current match (null when there is none) after the bar
  /// closes from Esc in the field or the close button.
  final ValueChanged<FindMatch?> onClose;

  @override
  ConsumerState<FindBarOverlay> createState() => _FindBarOverlayState();
}

class _FindBarOverlayState extends ConsumerState<FindBarOverlay> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode(debugLabel: 'find-bar-field');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(findInNoteProvider).query,
    );
    _focus.addListener(_onFocusChange);
    // The field follows the query, whoever sets it. Typing sets the same
    // text, so the caret where the user typed is kept.
    ref.listenManual<String>(findInNoteProvider.select((s) => s.query), (
      _,
      query,
    ) {
      if (_controller.text == query) return;
      _controller.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    });
    // Reqs 12-13: each request focuses the field and selects all of it,
    // also when it already has focus. The field may only mount in the
    // frame this builds (show on a closed bar), so it runs after it.
    ref.listenManual<int>(findInNoteProvider.select((s) => s.focusRequest), (
      previous,
      next,
    ) {
      if (previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusAndSelectAll());
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocusChange)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
  }

  void _focusAndSelectAll() {
    if (!mounted || !ref.read(findInNoteProvider).open) return;
    _focus.requestFocus();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  FindInNoteNotifier get _notifier => ref.read(findInNoteProvider.notifier);

  void _next() {
    final match = _notifier.next();
    if (match != null) widget.onStep(match);
  }

  void _previous() {
    final match = _notifier.previous();
    if (match != null) widget.onStep(match);
  }

  void _close() => widget.onClose(_notifier.close());

  /// Pastes the clipboard's plain text over the selection with its line
  /// breaks as spaces. The single-line field would drop them (its newline
  /// formatter runs before any of ours), joining `two\nlines` into
  /// `twolines`.
  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    final pasted = text.replaceAll(RegExp(r'\r\n|\r|\n'), ' ');
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final query = value.text.replaceRange(
      selection.start,
      selection.end,
      pasted,
    );
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(
        offset: selection.start + pasted.length,
      ),
    );
    _notifier.setQuery(query);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(findInNoteProvider);
    if (!s.open) return const SizedBox.shrink();

    final boxWidth = findBoxWidth(widget.bodyWidth);
    final total = s.matches.length;
    final error = s.query.isNotEmpty && total == 0;
    final counterStyle = OmType.mono(
      size: 11,
      height: 14 / 11,
      color: error ? OmColors.danger : OmColors.fg2,
    );
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String? text) {
      if (text == null) return 0;
      final painter = TextPainter(
        text: TextSpan(text: text, style: counterStyle),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final form = findCounterForm(
      boxWidth: boxWidth,
      shortTextWidth: measure(
        findCounterText(
          current: s.current,
          total: total,
          query: s.query,
          form: FindCounterForm.short,
        ),
      ),
    );
    final counterText = findCounterText(
      current: s.current,
      total: total,
      query: s.query,
      form: form,
    );
    final counterWidth = max(
      form == FindCounterForm.full ? _fullCounterMin : _shortCounterMin,
      measure(counterText),
    );
    final stepping = total > 0;

    return Positioned(
      top: _top,
      right: _right,
      width: boxWidth,
      height: _height,
      // Clicks on the bar count as inside the text fields (the find field's
      // and the editor's), so none of them loses focus to a button click.
      child: TextFieldTapRegion(
        // D14: the box takes every press inside its rect, rounded corners
        // included, so nothing under it ever sees one.
        child: Listener(
          key: findBarKey,
          behavior: HitTestBehavior.opaque,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: OmColors.surface3,
              border: Border.all(color: OmColors.line2),
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                  color: OmColors.menuShadow,
                  offset: Offset(0, 8),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _inset),
              child: Row(
                children: [
                  Expanded(
                    child: _field(
                      s,
                      error: error,
                      magnifier: boxWidth >= _magnifierMinBox,
                    ),
                  ),
                  const SizedBox(width: _gap),
                  if (form != FindCounterForm.hidden) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _counterMargin,
                      ),
                      child: SizedBox(
                        width: counterWidth,
                        child: counterText == null
                            ? null
                            : SizedBox(
                                key: findBarCounterKey,
                                width: counterWidth,
                                height: 14,
                                child: Text(
                                  counterText,
                                  maxLines: 1,
                                  softWrap: false,
                                  textAlign: TextAlign.right,
                                  style: counterStyle,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(width: _gap),
                  ],
                  _FindBarButton(
                    key: findBarPreviousKey,
                    icon: LucideIcons.chevronUp,
                    label: 'Previous match',
                    tip: 'Previous match',
                    shortcut: '⇧⌘G',
                    onPressed: stepping ? _previous : null,
                  ),
                  const SizedBox(width: _gap),
                  _FindBarButton(
                    key: findBarNextKey,
                    icon: LucideIcons.chevronDown,
                    label: 'Next match',
                    tip: 'Next match',
                    shortcut: '⌘G',
                    onPressed: stepping ? _next : null,
                  ),
                  const SizedBox(width: _gap),
                  _FindBarButton(
                    key: findBarCloseKey,
                    icon: LucideIcons.x,
                    label: 'Close find',
                    tip: 'Close',
                    shortcut: 'Esc',
                    onPressed: _close,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The query field box: border, magnifier and the single-line query.
  Widget _field(
    FindInNoteState s, {
    required bool error,
    required bool magnifier,
  }) {
    final Color border;
    if (error) {
      border = OmColors.danger;
    } else if (_focused) {
      border = OmColors.accentSoft;
    } else {
      border = OmColors.line3;
    }
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: 1,
      style: OmType.mono(
        size: 12,
        height: 15 / 12,
        color: _focused ? OmColors.fg0 : OmColors.fg1,
      ),
      cursorColor: OmColors.accent,
      cursorWidth: 2,
      cursorHeight: 14,
      decoration: InputDecoration.collapsed(
        hintText: 'Find in note',
        hintStyle: OmType.mono(size: 12, height: 15 / 12, color: OmColors.fg2),
      ),
      onChanged: _notifier.setQuery,
    );
    // Keys scoped to the field only: Enter, Shift+Enter and Esc, key
    // repeats included (Req 22). Cmd+F, Cmd+G, Shift+Cmd+G and Cmd+E are
    // left unhandled for the native menu (D12); Esc outside the field is
    // not handled here (Req 41).
    final keyed = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _next,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): _previous,
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: Actions(
        actions: {
          PasteTextIntent: CallbackAction<PasteTextIntent>(
            onInvoke: (_) => _paste(),
          ),
        },
        child: TextSelectionTheme(
          data: TextSelectionThemeData(
            cursorColor: OmColors.accent,
            selectionColor: OmColors.selection,
          ),
          child: field,
        ),
      ),
    );
    // Req 34: one text field node labelled `Find in note`, its value always
    // the full counter form whatever the counter shows.
    return MergeSemantics(
      child: Semantics(
        label: 'Find in note',
        value: findSemanticsValue(
          current: s.current,
          total: s.matches.length,
          query: s.query,
        ),
        child: Container(
          key: findBarFieldKey,
          height: _fieldHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: OmColors.surface0,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (magnifier) ...[
                const Icon(LucideIcons.search, size: 12, color: OmColors.fg3),
                const SizedBox(width: 6),
              ],
              Expanded(child: keyed),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 24 px ghost button with a 14 px icon: fg1 at rest, surface4 under the
/// mouse, fg3 with no hover fill and no action while disabled (null
/// [onPressed]). Announced as one button labelled [label]; the tooltip
/// reads [tip] and its [shortcut].
class _FindBarButton extends StatefulWidget {
  const _FindBarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.tip,
    required this.shortcut,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final String tip;
  final String shortcut;
  final VoidCallback? onPressed;

  @override
  State<_FindBarButton> createState() => _FindBarButtonState();
}

class _FindBarButtonState extends State<_FindBarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: Tooltip(
        richMessage: TextSpan(
          children: [
            TextSpan(
              text: widget.tip,
              style: OmType.sans(
                size: 11.5,
                height: 14 / 11.5,
                color: OmColors.fg0,
              ),
            ),
            TextSpan(
              text: ' ${widget.shortcut}',
              style: OmType.mono(
                size: 11,
                height: 14 / 11,
                color: OmColors.fg2,
              ),
            ),
          ],
        ),
        decoration: BoxDecoration(
          color: OmColors.surface4,
          border: Border.all(color: OmColors.line2),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        constraints: const BoxConstraints(minHeight: 22),
        // 6 px below the box: the button's centre is 19 px from the box
        // top and the box is 38 px tall.
        verticalOffset: 25,
        preferBelow: true,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: SizedBox(
              width: _buttonSize,
              height: _buttonSize,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: enabled && _hover ? OmColors.surface4 : null,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Center(
                  child: Icon(
                    widget.icon,
                    size: 14,
                    color: enabled ? OmColors.fg1 : OmColors.fg3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
