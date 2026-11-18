import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/outline.dart';

// The Outline's current section (#69, Spec #58 R22-R26, R41, TD6): the
// entry of the section the editor shows at its top, or none. The editor's
// section tracker (`widgets/outline/section_tracker.dart`) reports it; it
// runs only while something watches this provider.

/// Holds the current Outline entry of the note the editor shows, or null.
class OutlineSectionNotifier extends AutoDisposeNotifier<OutlineEntry?> {
  @override
  OutlineEntry? build() => null;
}

/// The current Outline entry, or null: none above the first heading, in
/// Source mode, or with no note shown.
final outlineSectionProvider =
    NotifierProvider.autoDispose<OutlineSectionNotifier, OutlineEntry?>(
      OutlineSectionNotifier.new,
    );
