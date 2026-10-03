import 'package:flutter/widgets.dart';

import '../../db.dart';

/// Slot in the note header for the agent review chip. Renders nothing yet.
class ReviewChip extends StatelessWidget {
  const ReviewChip({super.key, required this.note});
  final Note note;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
