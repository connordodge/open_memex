import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../kind_chip.dart';
import '../wikilink_autocomplete.dart';

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
/// or the kind chip) is reported through [onChanged]. Down with the caret at
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
    required this.onChanged,
    required this.kindChips,
    this.focusNode,
    this.minLines = 1,
    this.hintText,
    this.onMoveUp,
    this.onMoveDown,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final KindChipHost kindChips;

  /// Owned by the caller; one is made here when null.
  final FocusNode? focusNode;
  final int minLines;
  final String? hintText;
  final FocusNode? Function()? onMoveUp;
  final FocusNode? Function()? onMoveDown;

  @override
  State<TextSegmentField> createState() => _TextSegmentFieldState();
}

class _TextSegmentFieldState extends State<TextSegmentField> {
  final _fieldKey = GlobalKey();
  final _autocompleteKey = GlobalKey<WikilinkAutocompleteState>();
  late final FocusNode _focus =
      widget.focusNode ?? FocusNode(debugLabel: 'text-segment');
  late String _lastSeen;

  @override
  void initState() {
    super.initState();
    _lastSeen = widget.controller.text;
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
      widget.onChanged(text);
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

  /// The global offset just below the caret, where the autocomplete popover
  /// anchors: a [TextPainter] with the field's style and width measures the
  /// text before the caret. Called only while the popover is open, after the
  /// field was laid out.
  Offset _caretGlobal() {
    final box = _fieldKey.currentContext!.findRenderObject()! as RenderBox;
    final text = widget.controller.text;
    final caret = widget.controller.selection.baseOffset.clamp(0, text.length);
    final prefix = text.substring(0, caret);
    final painter = TextPainter(
      // A single space gives the painter something to measure when the
      // prefix is empty.
      text: TextSpan(text: prefix.isEmpty ? ' ' : prefix, style: _bodyStyle()),
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: box.size.width);
    final local = painter.getOffsetForCaret(
      TextPosition(offset: prefix.length),
      Rect.zero,
    );
    painter.dispose();
    final origin = box.localToGlobal(Offset.zero);
    return origin + Offset(local.dx, local.dy + _bodySize * _bodyHeight);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        TextField(
          key: _fieldKey,
          controller: widget.controller,
          focusNode: _focus,
          maxLines: null,
          minLines: widget.minLines,
          cursorColor: OmColors.accent,
          style: _bodyStyle(),
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: OmType.mono(size: _bodySize, color: OmColors.fg3),
          ),
          // No onChanged: the controller listener reports typed AND spliced
          // changes.
        ),
        // Zero-size; the popover lives in the root Overlay.
        WikilinkAutocomplete(
          key: _autocompleteKey,
          controller: widget.controller,
          caretLocator: _caretGlobal,
          onNoteCreatedSelect: (_) {},
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
