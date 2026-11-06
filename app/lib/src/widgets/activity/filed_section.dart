import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart';

/// The `Filed from this day` section at the top of a daily note's Activity
/// tab (Spec #233, R6-R10): where the blocks of the day are filed, with
/// `Move to…`, `Remove` and `File in…` fixes.
///
/// Test-author skeleton (#260): renders nothing yet.
class FiledSection extends ConsumerWidget {
  const FiledSection({super.key, required this.note});

  /// The selected note of the Activity tab.
  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}
