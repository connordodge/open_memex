import 'package:flutter/widgets.dart';

/// Clipboard, IME and undo operations over one text segment's editor rows
/// (D8): a pass-through around the segment that C1 creates and C4 fills
/// (Copy, Cut, Paste, Undo, Redo, type-over, IME start, context menu).
class SegmentSelectionOps extends StatelessWidget {
  const SegmentSelectionOps({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
