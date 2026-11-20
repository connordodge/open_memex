import 'dart:async' show scheduleMicrotask;
import 'dart:math' show max;
import 'dart:ui' as ui show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/paste_or_attach.dart' show canPasteOrAttach;
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../kind_chip.dart';
import '../tag_autocomplete.dart';
import '../wikilink_autocomplete.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'segment_view.dart' show SegmentViewState;
import 'spelling_menu.dart' show spellingAwareContextMenu;

// Shared editing pieces of the note editor (WI #27): the scrolling editor
// page, one editable markdown field with wikilink autocomplete, and the inline
// kind chip. The Source surface uses one [TextSegmentField] for the whole
// body; the segmented view uses one per text segment.

const double _bodySize = 13.5;
const double _bodyHeight = 1.7;

TextStyle editorBodyStyle() =>
    OmType.mono(size: _bodySize, color: OmColors.fg1, height: _bodyHeight);

/// Hands the [ScrollController] of the [EditorPage] below it to that page,
/// so `NoteEditor` can own the scroll of the segmented body without
/// `SegmentedBody` passing it along. A page with no scope above it (Source
/// mode, a bare pump) scrolls on its own (#270).
class EditorScrollScope extends InheritedWidget {
  const EditorScrollScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final ScrollController controller;

  static ScrollController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<EditorScrollScope>()
      ?.controller;

  @override
  bool updateShouldNotify(EditorScrollScope oldWidget) =>
      controller != oldWidget.controller;
}

/// The editor page: a scroll view holding [header], the save [errorMessage]
/// and [body], centred at reading width, with [overlays] stacked on top.
/// The scroll content is one repaint boundary, so a scroll frame
/// re-composites it and repaints nothing (Spec #122 R17, TD2).
class EditorPage extends StatelessWidget {
  const EditorPage({
    super.key,
    required this.body,
    this.header,
    this.errorMessage,
    this.overlays = const [],
  });

  final Widget body;
  final Widget? header;
  final String? errorMessage;

  /// Children of the page's [Stack] above the scroll view (e.g. the
  /// [KindChipLayer]).
  final List<Widget> overlays;

  @override
  Widget build(BuildContext context) {
    final error = errorMessage;
    return Stack(
      children: [
        SingleChildScrollView(
          controller: EditorScrollScope.maybeOf(context),
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 200),
          child: RepaintBoundary(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?header,
                    const SizedBox(height: 18),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          error,
                          style: OmType.mono(size: 11, color: OmColors.danger),
                        ),
                      ),
                    body,
                  ],
                ),
              ),
            ),
          ),
        ),
        ...overlays,
      ],
    );
  }
}

/// The inline kind chip of one editor page, shared by all of its
/// [TextSegmentField]s: it follows the field a wikilink was last inserted
/// into.
class KindChipHost extends ChangeNotifier {
  /// The chip's own state (visibility, range, kind).
  final KindChipController chip = KindChipController();

  TextEditingController? _target;

  /// The field controller the chip rewrites; null before the first insert.
  TextEditingController? get target => _target;

  /// Show the chip for the wikilink at `start..end` of [controller]'s text.
  void showFor(
    TextEditingController controller, {
    required int start,
    required int end,
  }) {
    _target = controller;
    chip.show(start: start, end: end);
    notifyListeners();
  }

  /// Hide the chip and forget its field (the field is going away).
  void clear() {
    chip.hide();
    _target = null;
    notifyListeners();
  }

  /// The caret of [controller] moved to [caret]: hides the chip when it
  /// leaves the inserted wikilink of the field the chip belongs to.
  void caretMoved(TextEditingController controller, int caret) {
    if (identical(controller, _target)) chip.onSelectionChanged(caret);
  }

  /// The field of [controller] went away (its editor row stopped being the
  /// active row, WI #132): once this frame's tree is settled, hides the
  /// chip and forgets its field when the chip still belongs to that field.
  /// The chip's listeners may not rebuild while the tree is being torn
  /// down, so it waits for a microtask.
  void release(TextEditingController controller) {
    if (!identical(controller, _target)) return;
    scheduleMicrotask(() {
      if (!_disposed && identical(controller, _target)) clear();
    });
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    chip.dispose();
    super.dispose();
  }
}

/// How far above the editor page's bottom edge the kind chip sits.
const double _chipInset = 110;

/// Places [host]'s [KindChip] near the bottom left of the editor's text
/// column. A child of the editor page's [Stack] (see [EditorPage.overlays]).
class KindChipLayer extends StatelessWidget {
  const KindChipLayer({super.key, required this.host});
  final KindChipHost host;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) => ListenableBuilder(
          listenable: Listenable.merge([host, host.chip]),
          builder: (context, _) {
            final target = host.target;
            // The text column: 28 px page padding, centred at most 760 wide.
            final left = 28 + max(0.0, (box.maxWidth - 56 - 760) / 2);
            return Stack(
              children: [
                if (target != null)
                  KindChip(
                    controller: host.chip,
                    editorController: target,
                    anchor: Offset(left + 24, box.maxHeight - _chipInset),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One editable markdown field: a multi-line [TextField] with wikilink
/// autocomplete on `[[`, tag autocomplete on `#` and the inline kind chip
/// through [kindChips].
///
/// Every change to [controller]'s text (typed, or spliced in by autocomplete
/// or the kind chip) is reported through [onChanged] when given. Down with the caret at
/// the end asks [onMoveDown], and Up with the caret at 0 asks [onMoveUp],
/// for the focus node to move to; when one is returned it takes focus and
/// the key is handled.
///
/// [controller] and [focusNode] must not change for the life of the field:
/// key the field by its controller.
class TextSegmentField extends StatefulWidget {
  const TextSegmentField({
    super.key,
    required this.controller,
    required this.kindChips,
    this.onChanged,
    this.focusNode,
    this.minLines = 1,
    this.hintText,
    this.onMoveUp,
    this.onMoveDown,
    this.dailyNoteId,
    this.onTopicLinked,
    this.onCreateError,
    this.selectionHeightStyle,
    this.paintsSelection = true,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final KindChipHost kindChips;

  /// Owned by the caller; one is made here when null.
  final FocusNode? focusNode;
  final int minLines;
  final String? hintText;
  final FocusNode? Function()? onMoveUp;
  final FocusNode? Function()? onMoveDown;

  /// The saved daily note the field belongs to, else null: see
  /// [WikilinkAutocomplete.dailyNoteId], [WikilinkAutocomplete.onTopicLinked]
  /// and [WikilinkAutocomplete.onCreateError].
  final String? dailyNoteId;
  final void Function(int version)? onTopicLinked;
  final ValueChanged<String>? onCreateError;

  /// How tall a field that paints its own selection ([paintsSelection])
  /// paints its selection boxes; null keeps the platform default. A field
  /// that paints none (an editor row's) always measures max-height,
  /// tight-width boxes: its line boxes are read straight from them
  /// (`RenderEditableLineBoxes`, WI #126).
  final ui.BoxHeightStyle? selectionHeightStyle;

  /// Whether the field paints its own selection fill. False in an editor
  /// row, which paints the segment selection as one block behind the field
  /// (`EditorRow`).
  final bool paintsSelection;

  @override
  State<TextSegmentField> createState() => _TextSegmentFieldState();
}

class _TextSegmentFieldState extends State<TextSegmentField> {
  final _fieldKey = GlobalKey();
  final _autocompleteKey = GlobalKey<WikilinkAutocompleteState>();
  final _tagAutocompleteKey = GlobalKey<TagAutocompleteState>();
  late final FocusNode _focus =
      widget.focusNode ?? FocusNode(debugLabel: 'text-segment');
  late String _lastSeen;
  late bool _empty;

  @override
  void initState() {
    super.initState();
    _lastSeen = widget.controller.text;
    _empty = _lastSeen.isEmpty;
    widget.controller.addListener(_onChanged);
    _focus.onKeyEvent = _onKey;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    // The kind chip belongs to this field only (WI #132): an editor row
    // that goes idle takes its chip with it.
    widget.kindChips.release(widget.controller);
    if (widget.focusNode == null) {
      _focus.dispose();
    } else if (_focus.onKeyEvent == _onKey) {
      // Leave the handler alone when another field took the node over.
      _focus.onKeyEvent = null;
    }
    super.dispose();
  }

  void _onChanged() {
    final text = widget.controller.text;
    if (text != _lastSeen) {
      _lastSeen = text;
      // The strut below depends on whether the field is empty.
      if (text.isEmpty != _empty) setState(() => _empty = text.isEmpty);
      widget.onChanged?.call(text);
    }
    final caret = widget.controller.selection.baseOffset;
    if (caret >= 0) widget.kindChips.caretMoved(widget.controller, caret);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // While the autocomplete popover is open it takes ↑/↓/Enter/Tab/Esc.
    final autocomplete = _autocompleteKey.currentState;
    if (autocomplete != null && autocomplete.isOpen) {
      return autocomplete.handleKeyEvent(event);
    }
    final tags = _tagAutocompleteKey.currentState;
    if (tags != null && tags.isOpen) return tags.handleKeyEvent(event);
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final selection = widget.controller.selection;
    if (!selection.isCollapsed) return KeyEventResult.ignored;
    final atEnd = selection.baseOffset == widget.controller.text.length;
    final target = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown when atEnd => widget.onMoveDown?.call(),
      LogicalKeyboardKey.arrowUp when selection.baseOffset == 0 =>
        widget.onMoveUp?.call(),
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    target.requestFocus();
    return KeyEventResult.handled;
  }

  /// The global point at the caret's x and the bottom of the caret's real
  /// line box (R32), where the autocomplete popover anchors. Called only
  /// while the popover is open, after the field was laid out (the caret is
  /// clamped to the text the field last laid out).
  Offset _caretGlobal() {
    final editable = findRenderEditable(
      _fieldKey.currentContext!.findRenderObject(),
    )!;
    final caret = RenderEditableLineBoxes(
      editable,
    ).caretRect(widget.controller.selection.baseOffset);
    return editable.localToGlobal(caret.bottomLeft);
  }

  /// [live]'s strut. An empty field lays out taller than its strut when the
  /// strut spreads its leading evenly (the theme's text style does, and the
  /// field's strut inherits it): 32 px instead of one 22.95 px prose line. So
  /// while empty, a prose row's strut is forced to its own height; an empty
  /// line has no glyphs for that to clip. Code rows keep their own strut.
  StrutStyle? _emptySafe(LivePreviewController live) =>
      _rowStrut(live, empty: _empty);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // The editor's selection fill (D13); an editor row paints its own.
        DefaultSelectionStyle.merge(
          selectionColor: widget.paintsSelection
              ? OmColors.selection
              : const Color(0x00000000),
          // The per-line cache of the field's line boxes (WI #126).
          child: LineBoxEpoch(
            child: TextField(
              key: _fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              maxLines: null,
              minLines: widget.minLines,
              cursorColor: OmColors.accent,
              selectionHeightStyle: widget.paintsSelection
                  ? widget.selectionHeightStyle
                  : ui.BoxHeightStyle.max,
              selectionWidthStyle: widget.paintsSelection
                  ? null
                  : ui.BoxWidthStyle.tight,
              style: editorBodyStyle(),
              // A live preview controller may lay its text out with its own
              // strut (B1); null keeps the field's default.
              strutStyle: switch (widget.controller) {
                final LivePreviewController live => _emptySafe(live),
                _ => null,
              },
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: OmType.mono(size: _bodySize, color: OmColors.fg3),
              ),
              // A right click on a flagged range opens SpellingMenu (WI #438).
              contextMenuBuilder: spellingAwareContextMenu,
              // No onChanged: the controller listener reports typed AND
              // spliced changes.
            ),
          ),
        ),
        // Zero-size; the popover lives in the root Overlay.
        WikilinkAutocomplete(
          key: _autocompleteKey,
          controller: widget.controller,
          caretLocator: _caretGlobal,
          onNoteCreatedSelect: (_) {},
          dailyNoteId: widget.dailyNoteId,
          onTopicLinked: widget.onTopicLinked,
          onCreateError: widget.onCreateError,
          onInserted: (start, end) => widget.kindChips.showFor(
            widget.controller,
            start: start,
            end: end,
          ),
        ),
        TagAutocomplete(
          key: _tagAutocompleteKey,
          controller: widget.controller,
          caretLocator: _caretGlobal,
          focusNode: _focus,
        ),
      ],
    );
  }
}

/// The strut a [TextSegmentField] editing [live] hands its `TextField`
/// ([_TextSegmentFieldState._emptySafe]): the controller's own, forced to
/// its height while the field is [empty] (a prose row's), so an empty row
/// lays out one line tall.
StrutStyle? _rowStrut(LivePreviewController live, {required bool empty}) {
  final strut = live.strutStyle;
  if (!empty || live.codeRow || strut == null) return strut;
  return strut.merge(const StrutStyle(forceStrutHeight: true));
}

// ------------------------------------------------------------ idle rows

/// A `TextField`'s caret margin: its `RenderEditable` lays its text out
/// this much narrower than its box (the 1 px caret gap plus the default
/// 2 px cursor width).
const double _fieldCaretMargin = 1 + 2;

/// An idle editor row's text (WI #132, Spec #122 Req 28, 29, 34, TD5): a
/// `RichText` of the span [controller] builds for its selection and reveal
/// state, laid out exactly as a [TextSegmentField] of [controller] lays
/// its text out, so a row changing between idle and active moves no line,
/// glyph or row.
///
/// - The style is the field's merged one: the theme's `bodyLarge` with the
///   `TextField`'s state colour, then [editorBodyStyle] (and bold while
///   the platform asks for bold text).
/// - The strut is the field's ([TextSegmentField]'s, forced while the row
///   is empty) resolved as `EditableText` resolves it, with the platform's
///   line height override; the text scaler, height behaviour and locale
///   are the field's defaults.
/// - The text lays out at the field's width less its caret margin
///   ([_fieldCaretMargin]), and at least one line tall
///   (`RenderEditable.preferredLineHeight`, which only a code row's 8 px
///   hidden fence lines can undercut).
/// - It is under a [LineBoxEpoch], as the field's text is (WI #126).
///
/// It rebuilds when [controller] notifies, and on a reveal gate change
/// while the controller holds a selection (the gate reveals only through
/// it). [focusNode], the row's own focus node, stays attached here while
/// the row is idle, so a row that goes idle while it holds focus keeps it
/// until the next row takes it (the segment never loses focus, Req 33).
/// Assistive tech reads it as one read-only text node holding the row's
/// text ([excludeSemantics] over the paragraph), whose tap action is
/// [onActivate] (Req 34).
class IdleRowText extends StatefulWidget {
  const IdleRowText({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onActivate,
  });

  /// The row's controller: it holds only the row's text.
  final LivePreviewController controller;

  /// The row's focus node.
  final FocusNode focusNode;

  /// Makes the row the active row, caret at its end; null: no action.
  final VoidCallback? onActivate;

  @override
  State<IdleRowText> createState() => _IdleRowTextState();
}

class _IdleRowTextState extends State<IdleRowText> {
  /// The reveal gate listened to: the controller's, which its host may
  /// swap.
  ValueListenable<bool>? _gate;

  /// Whether this listens to system font changes (a code row's minimum
  /// line height is measured, and a font load moves it).
  bool _fonts = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _syncGate();
  }

  @override
  void didUpdateWidget(IdleRowText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _syncGate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _gate?.removeListener(_gateChanged);
    if (_fonts) PaintingBinding.instance.systemFonts.removeListener(_rebuild);
    super.dispose();
  }

  void _syncGate() {
    final gate = widget.controller.revealGate;
    if (identical(gate, _gate)) return;
    _gate?.removeListener(_gateChanged);
    _gate = gate..addListener(_gateChanged);
  }

  void _changed() {
    _syncGate();
    _rebuild();
  }

  void _gateChanged() {
    if (widget.controller.selection.isValid) _rebuild();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _listenToFonts(bool listen) {
    if (listen == _fonts) return;
    _fonts = listen;
    final fonts = PaintingBinding.instance.systemFonts;
    if (listen) {
      fonts.addListener(_rebuild);
    } else {
      fonts.removeListener(_rebuild);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final input = idleRowFieldStyle(context);
    final style = MediaQuery.boldTextOf(context)
        ? input.merge(const TextStyle(fontWeight: FontWeight.bold))
        : input;
    final own = _rowStrut(controller, empty: controller.text.isEmpty);
    final strut =
        (own == null
                ? StrutStyle.fromTextStyle(input, forceStrutHeight: true)
                : own.inheritFromTextStyle(input))
            .merge(
              StrutStyle(
                height: MediaQuery.maybeLineHeightScaleFactorOverrideOf(
                  context,
                ),
              ),
            );
    final scaler = MediaQuery.textScalerOf(context);
    final heightBehavior = DefaultTextHeightBehavior.maybeOf(context);
    final direction = Directionality.of(context);
    final span = controller.buildTextSpan(
      context: context,
      style: style,
      withComposing: false,
    );
    // Only a code row's strut lets a line lay out shorter than the field's
    // one-line minimum (its hidden fences are 8 px tall).
    _listenToFonts(controller.codeRow);
    final minHeight = controller.codeRow
        ? _preferredLineHeight(
            span.style,
            strut: strut,
            scaler: scaler,
            heightBehavior: heightBehavior,
            direction: direction,
          )
        : 0.0;
    return Focus(
      focusNode: widget.focusNode,
      includeSemantics: false,
      child: Semantics(
        container: true,
        readOnly: true,
        label: controller.text,
        textDirection: direction,
        onTap: widget.onActivate,
        // One leaf node for the row: the paragraph's own node is the
        // label's text again.
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.only(right: _fieldCaretMargin),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: LineBoxEpoch(
              child: RichText(
                text: span,
                strutStyle: strut,
                textScaler: scaler,
                textHeightBehavior: heightBehavior,
                textDirection: direction,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `TextPainter.preferredLineHeight` of a field whose text's root style
  /// is [style]: the height it gives its text at the least
  /// (`RenderEditable`'s `minLines` of 1).
  static double _preferredLineHeight(
    TextStyle? style, {
    required StrutStyle strut,
    required TextScaler scaler,
    required TextHeightBehavior? heightBehavior,
    required TextDirection direction,
  }) {
    final painter = TextPainter(
      text: TextSpan(style: style),
      strutStyle: strut,
      textScaler: scaler,
      textHeightBehavior: heightBehavior,
      textDirection: direction,
    );
    final height = painter.preferredLineHeight;
    painter.dispose();
    return height;
  }
}

/// The style a [TextSegmentField]'s `TextField` lays its text out with
/// before the platform's bold text: the theme's `bodyLarge` with the
/// field's enabled state colour (Material 3's input style), then
/// [editorBodyStyle].
TextStyle idleRowFieldStyle(BuildContext context) {
  final base = Theme.of(context).textTheme.bodyLarge ?? const TextStyle();
  return base.merge(TextStyle(color: base.color)).merge(editorBodyStyle());
}

// ------------------------------------------------ rows without a field

/// The text context menu [showRowTextMenu] shows.
final _rowMenu = ContextMenuController(onRemove: () => _rowMenuShown?.call());

/// Stops listening for what closes the shown row menu; null while none
/// shows.
VoidCallback? _rowMenuShown;

/// Bumped by every [showRowTextMenu]: an older call still waiting for the
/// clipboard then shows nothing.
int _rowMenuOpens = 0;

/// Closes the menu [showRowTextMenu] showed, if it still shows.
void hideRowTextMenu() => _rowMenu.remove();

/// Opens the text context menu of row [row] of [view] at global [anchor]
/// (WI #128, Spec #122 Req 30) without needing the row's field: the items a
/// [TextSegmentField]'s own menu shows on this platform for the row's
/// selection, in its order (`EditableText.getEditableButtonItems`): Cut and
/// Copy over a selection, Paste while the clipboard holds text, and Select
/// All where the platform's field offers it (never on macOS). Each item
/// invokes its intent (`CopySelectionTextIntent`, `PasteTextIntent`,
/// `SelectAllTextIntent`) from the row's focus node, as SpellingMenu's
/// items do, so Paste goes through the segment's `PasteTextIntent`
/// override (ruling D11). It replaces any other context menu, and closes
/// on an item, a tap outside the editor's fields, a press of the segment's
/// pointer layer ([hideRowTextMenu]) or a change of the segment's text or
/// selection.
Future<void> showRowTextMenu(
  SegmentViewState view,
  int row, {
  required Offset anchor,
}) async {
  final open = ++_rowMenuOpens;
  final ctrl = view.rowController(row);
  final focusNode = view.rowFocusNode(row);
  if (ctrl == null || focusNode == null) return;
  // A menu shown without Paste because the clipboard answered late is
  // shown again with Paste once it does, while it still shows (#147 r5).
  final pasteable = await canPasteOrAttach(
    view.context,
    onLateOffer: () {
      if (open == _rowMenuOpens && _rowMenu.isShown && view.mounted) {
        showRowTextMenu(view, row, anchor: anchor).ignore();
      }
    },
  );
  if (open != _rowMenuOpens || !view.mounted) return;
  final value = ctrl.value;
  final collapsed = !value.selection.isValid || value.selection.isCollapsed;
  void invoke(Intent intent) {
    _rowMenu.remove();
    final context = focusNode.context;
    if (context != null && context.mounted) {
      Actions.maybeInvoke(context, intent);
    }
  }

  const cause = SelectionChangedCause.toolbar;
  final items = EditableText.getEditableButtonItems(
    clipboardStatus: pasteable
        ? ClipboardStatus.pasteable
        : ClipboardStatus.notPasteable,
    onCopy: collapsed ? null : () => invoke(CopySelectionTextIntent.copy),
    onCut: collapsed
        ? null
        : () => invoke(const CopySelectionTextIntent.cut(cause)),
    onPaste: pasteable ? () => invoke(const PasteTextIntent(cause)) : null,
    onSelectAll: _selectAllOffered(value)
        ? () => invoke(const SelectAllTextIntent(cause))
        : null,
    onLookUp: null,
    onSearchWeb: null,
    onShare: null,
    onLiveTextInput: null,
  );
  if (items.isEmpty) return;
  final segment = view.widget.controller;
  final seen = segment.value;
  void onSegment() {
    if (segment.value != seen) _rowMenu.remove();
  }

  // A fresh overlay entry in [view]'s overlay (`show` rebuilds an entry
  // still marked shown in place).
  _rowMenu.remove();
  _rowMenu.show(
    context: view.context,
    contextMenuBuilder: (_) => TextFieldTapRegion(
      onTapOutside: (_) => _rowMenu.remove(),
      child: AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
        buttonItems: items,
      ),
    ),
  );
  segment.addListener(onSegment);
  _rowMenuShown = () {
    segment.removeListener(onSegment);
    _rowMenuShown = null;
  };
}

/// Whether a field's text context menu offers Select All over [value] on
/// this platform (`EditableTextState.selectAllEnabled` with the platform's
/// selection controls).
bool _selectAllOffered(TextEditingValue value) =>
    switch (defaultTargetPlatform) {
      TargetPlatform.macOS => false,
      TargetPlatform.iOS =>
        value.text.isNotEmpty && value.selection.isCollapsed,
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.windows =>
        value.text.isNotEmpty &&
            !(value.selection.start == 0 &&
                value.selection.end == value.text.length),
    };
