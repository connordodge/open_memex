import 'package:flutter/widgets.dart';

import '../../db.dart';

/// Slot in the note header for a daily note's fixed date header. Renders
/// nothing yet.
class DailyDateHeader extends StatelessWidget {
  const DailyDateHeader({super.key, required this.note});
  final Note note;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
