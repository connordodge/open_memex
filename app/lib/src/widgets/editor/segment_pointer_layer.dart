import 'package:flutter/widgets.dart';

/// Pointer selection over one text segment's editor rows (D8): a
/// pass-through around the segment that C1 creates and C3 fills (drag,
/// Shift+click and `SelectAll` across rows).
class SegmentPointerLayer extends StatelessWidget {
  const SegmentPointerLayer({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
