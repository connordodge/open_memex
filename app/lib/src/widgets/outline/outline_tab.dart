// The right panel's Outline tab (Spec #58, WI #68): design B "Mono tree".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/outline.dart';

/// The `outline` tab body: the editor's note's entries, or a placeholder.
class OutlineTab extends ConsumerWidget {
  const OutlineTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}

/// The Outline's scrolling list of entries (Key `outline-list`), one row per
/// entry (Key `outline-entry-<index>`, the whole row's click target).
///
/// [currentIndex] is the current section's row, [focusedIndex] the row with
/// keyboard focus; [onActivate] runs with a row's entry when it is tapped.
class OutlineList extends StatelessWidget {
  const OutlineList({
    super.key,
    required this.entries,
    this.currentIndex,
    this.focusedIndex,
    this.onActivate,
  });

  final List<OutlineEntry> entries;
  final int? currentIndex;
  final int? focusedIndex;
  final void Function(OutlineEntry entry)? onActivate;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
