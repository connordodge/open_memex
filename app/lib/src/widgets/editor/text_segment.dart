import 'dart:math' show max;
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../kind_chip.dart';
import '../wikilink_autocomplete.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';

// Shared editing pieces of the note editor (WI #27): the scrolling editor
// page, one editable markdown field with wikilink autocomplete, and the inline
// kind chip. The Source surface uses one [TextSegmentField] for the whole
// body; the segmented view uses one per text segment.

const double _bodySize = 13.5;
const double _bodyHeight = 1.7;

TextStyle _bodyStyle() =>
    OmType.mono(size: _bodySize, color: OmColors.fg0, height: _bodyHeight);

/// The editor page: a scroll view holding [header], the save [errorMessage]
/// and [body], centred at reading width, with [overlays] stacked on top.
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
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 200),
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

  @override
  void dispose() {
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
/// autocomplete on `[[` and the inline kind chip through [kindChips].
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

  /// How tall the field paints its selection boxes; null keeps the
  /// platform default.
  final ui.BoxHeightStyle? selectionHeightStyle;

  @override
  State<TextSegmentField> createState() => _TextSegmentFieldState();
}

class _TextSegmentFieldState extends State<TextSegmentField> {
  final _fieldKey = GlobalKey();
  final _autocompleteKey = GlobalKey<WikilinkAutocompleteState>();
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
  StrutStyle? _emptySafe(LivePreviewController live) {
    final strut = live.strutStyle;
    if (!_empty || live.codeRow || strut == null) return strut;
    return strut.merge(const StrutStyle(forceStrutHeight: true));
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // The editor's selection fill (D13).
        DefaultSelectionStyle.merge(
          selectionColor: OmColors.selection,
          child: TextField(
            key: _fieldKey,
            controller: widget.controller,
            focusNode: _focus,
            maxLines: null,
            minLines: widget.minLines,
            cursorColor: OmColors.accent,
            selectionHeightStyle: widget.selectionHeightStyle,
            style: _bodyStyle(),
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
            // No onChanged: the controller listener reports typed AND
            // spliced changes.
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
      ],
    );
  }
}
