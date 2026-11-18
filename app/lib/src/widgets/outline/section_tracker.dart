import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart';

// The editor side of the Outline's current section (#69, Spec #58 R22-R26,
// R41, TD6), plugged in through `NoteEditor._trackSections`.

/// Wraps the segmented body of [note] and reports its current section to
/// `outlineSectionProvider` while that provider is watched.
class SectionTracker extends ConsumerStatefulWidget {
  const SectionTracker({super.key, required this.note, required this.child});

  final Note note;
  final Widget child;

  /// How many times a tracker computed the current section (a test probe).
  @visibleForTesting
  static int debugPasses = 0;

  @override
  ConsumerState<SectionTracker> createState() => _SectionTrackerState();
}

class _SectionTrackerState extends ConsumerState<SectionTracker> {
  @override
  Widget build(BuildContext context) => widget.child;
}
