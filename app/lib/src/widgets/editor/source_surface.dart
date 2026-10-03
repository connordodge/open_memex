import 'package:flutter/material.dart';

import 'text_segment.dart';

/// The plain markdown editing surface (Key `editor-source-surface`): a
/// scrolling page with [header] above one multi-line body `TextField`
/// (Key `editor-body`), plus wikilink autocomplete and the inline kind chip.
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
  final _kindChips = KindChipHost();

  @override
  void dispose() {
    _kindChips.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EditorPage(
      key: const Key('editor-source-surface'),
      header: widget.header,
      errorMessage: widget.errorMessage,
      body: KeyedSubtree(
        key: const Key('editor-body'),
        child: TextSegmentField(
          controller: widget.bodyCtrl,
          focusNode: widget.bodyFocusNode,
          onChanged: widget.onContentChanged,
          kindChips: _kindChips,
          minLines: 12,
          hintText: 'type [[ to link a note · write markdown…',
        ),
      ),
      overlays: [KindChipLayer(host: _kindChips)],
    );
  }
}
