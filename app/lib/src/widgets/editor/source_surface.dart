import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../kind_chip.dart';
import '../wikilink_autocomplete.dart';

/// The plain markdown editing surface (Key `editor-source-surface`): a
/// scrolling page with [header] above one multi-line body `TextField`, plus
/// wikilink autocomplete and the inline kind chip.
///
/// Every change to [bodyCtrl] (typed or spliced in by autocomplete or the
/// kind chip) is reported through [onContentChanged].
class SourceSurface extends StatefulWidget {
  const SourceSurface({
    super.key,
    required this.bodyCtrl,
    required this.onContentChanged,
    this.header,
    this.errorMessage,
    this.bodyFocusNode,
  });
  final TextEditingController bodyCtrl;
  final ValueChanged<String> onContentChanged;

  /// Shown above the body, inside the same scroll view.
  final Widget? header;

  /// Save error shown just above the body.
  final String? errorMessage;

  /// The body field's focus node, when the host moves focus to the body
  /// (e.g. on launch, #22). Owned by the host; one is made here otherwise.
  final FocusNode? bodyFocusNode;

  @override
  State<SourceSurface> createState() => _SourceSurfaceState();
}

class _SourceSurfaceState extends State<SourceSurface> {
  final _bodyKey = GlobalKey();
  final _autocompleteKey = GlobalKey<WikilinkAutocompleteState>();
  late final _bodyFocus =
      widget.bodyFocusNode ?? FocusNode(debugLabel: 'editor-body');
  final _kindChipCtrl = KindChipController();
  String _lastSeenBody = '';

  @override
  void initState() {
    super.initState();
    _lastSeenBody = widget.bodyCtrl.text;
    widget.bodyCtrl.addListener(_onBodyChanged);
    // Intercept ↑/↓/Enter/Tab/Esc when the autocomplete popover is open
    // so the body field doesn't process them.
    _bodyFocus.onKeyEvent = (node, event) {
      final autocomplete = _autocompleteKey.currentState;
      if (autocomplete == null || !autocomplete.isOpen) {
        return KeyEventResult.ignored;
      }
      return autocomplete.handleKeyEvent(event);
    };
  }

  @override
  void dispose() {
    widget.bodyCtrl.removeListener(_onBodyChanged);
    if (widget.bodyFocusNode == null) _bodyFocus.dispose();
    _kindChipCtrl.dispose();
    super.dispose();
  }

  void _onBodyChanged() {
    final text = widget.bodyCtrl.text;
    final caret = widget.bodyCtrl.selection.baseOffset;
    if (text != _lastSeenBody) {
      _lastSeenBody = text;
      // Route to the editor controller's save path. This catches BOTH
      // user typing AND programmatic splices (autocomplete inserts, kind
      // chip rewrites) — onChanged on a TextField only fires for user input.
      widget.onContentChanged(text);
    }
    if (caret >= 0) {
      _kindChipCtrl.onSelectionChanged(caret);
    }
  }

  /// Compute the global screen offset where the popover should anchor.
  /// Uses a TextPainter that mirrors the body field's style + width to
  /// figure out where the caret sits inside the editor's RenderBox.
  Offset _caretGlobal() {
    final ctx = _bodyKey.currentContext;
    if (ctx == null) return Offset.zero;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;

    final text = widget.bodyCtrl.text;
    final caret = widget.bodyCtrl.selection.baseOffset.clamp(0, text.length);
    // TextPainter measures the prefix, then we ask where its end sits.
    final prefix = text.substring(0, caret);
    final style = OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);
    final painter = TextPainter(
      text: TextSpan(
        // Include a single trailing space so the painter has something to
        // measure even when the prefix ends with a newline.
        text: prefix.isEmpty ? ' ' : prefix,
        style: style,
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    painter.layout(maxWidth: box.size.width);
    final localCaret = painter.getOffsetForCaret(
      TextPosition(offset: prefix.length),
      Rect.zero,
    );
    painter.dispose();
    final lineHeight = 13.5 * 1.7;
    final origin = box.localToGlobal(Offset.zero);
    return origin + Offset(localCaret.dx, localCaret.dy + lineHeight);
  }

  @override
  Widget build(BuildContext context) {
    final header = widget.header;
    return Stack(
      key: const Key('editor-source-surface'),
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
                  if (widget.errorMessage != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        widget.errorMessage!,
                        style: OmType.mono(size: 11, color: OmColors.danger),
                      ),
                    ),
                  ],
                  KeyedSubtree(
                    key: const Key('editor-body'),
                    child: TextField(
                      key: _bodyKey,
                      controller: widget.bodyCtrl,
                      focusNode: _bodyFocus,
                      maxLines: null,
                      minLines: 12,
                      cursorColor: OmColors.accent,
                      style: OmType.mono(
                        size: 13.5,
                        color: OmColors.fg0,
                        height: 1.7,
                      ),
                      decoration: InputDecoration(
                        hintText: 'type [[ to link a note · write markdown…',
                        hintStyle: OmType.mono(size: 13.5, color: OmColors.fg3),
                      ),
                      // No onChanged here — the controller listener above
                      // routes both typed AND programmatic splice updates
                      // through the save path.
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Wikilink autocomplete (zero-size widget; uses an Overlay).
        WikilinkAutocomplete(
          key: _autocompleteKey,
          controller: widget.bodyCtrl,
          caretLocator: _caretGlobal,
          onNoteCreatedSelect: (_) {},
          onInserted: (start, end) {
            _kindChipCtrl.show(start: start, end: end);
          },
        ),
        // Floating kind chip near the bottom of the editor pane.
        ListenableBuilder(
          listenable: _kindChipCtrl,
          builder: (context, _) {
            final box =
                _bodyKey.currentContext?.findRenderObject() as RenderBox?;
            // build() runs before layout, so on the first frame the box has no
            // size yet and `localToGlobal` would walk into an unlaid-out
            // ancestor (hasSize assertion). The chip is only shown after a
            // wikilink insert — well past first layout — so falling back to
            // Offset.zero until the box is laid out is safe.
            final origin = (box != null && box.hasSize && box.attached)
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;
            // Anchor relative to the surrounding Stack; the OverlayEntry
            // approach the chip implements would be cleaner, but for v1 we
            // place it just above the bottom of the editor.
            final size = MediaQuery.of(context).size;
            return KindChip(
              controller: _kindChipCtrl,
              editorController: widget.bodyCtrl,
              anchor: Offset(origin.dx + 24, size.height - 110),
            );
          },
        ),
      ],
    );
  }
}
