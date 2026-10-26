import 'package:flutter/widgets.dart';

/// Keyboard handling of one text segment's editor rows (D8): a pass-through
/// around the segment that C1 creates and C2 fills (Enter, Shift+Enter,
/// Backspace, Delete, Tab, arrows and the `ExtendSelection*` /
/// `ExpandSelection*` / `Delete*` intents across rows).
class SegmentKeyboard extends StatelessWidget {
  const SegmentKeyboard({super.key, required this.child});

  /// The segment's rows.
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
